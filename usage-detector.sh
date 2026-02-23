#!/bin/bash
# ============================================================================
# Claude Code Usage Detector - Auto-detect plan and accurate usage tracking
# ============================================================================
# Combines 3 methods:
#   A. Count user prompts from history files (most accurate)
#   B. Try Anthropic API (future-proof, currently blocked by scope)
#   C. Cost correlation estimation (fallback via ccusage)
#
# Cross-platform: macOS (Keychain) + Linux (~/.claude/.credentials.json)
# ============================================================================

set -uo pipefail

# === PLAN LIMITS ===
get_plan_limits() {
    local plan=$1 type=$2
    case "$plan" in
        pro)
            case "$type" in
                min) echo 10 ;; max) echo 40 ;; cost) echo 10 ;;
            esac ;;
        max5)
            case "$type" in
                min) echo 50 ;; max) echo 200 ;; cost) echo 50 ;;
            esac ;;
        max20|enterprise)
            case "$type" in
                min) echo 200 ;; max) echo 800 ;; cost) echo 200 ;;
            esac ;;
        api|*)
            echo 999999 ;;
    esac
}

# === CROSS-PLATFORM: Find bun ===
find_bun() {
    local candidate
    for candidate in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
        [[ -x "$candidate" ]] && echo "$candidate" && return
    done
    command -v bun 2>/dev/null || true
}

# === CROSS-PLATFORM: Get OAuth token ===
get_oauth_token() {
    local token=""
    case "$(uname -s)" in
        Darwin)
            token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null) ;;
        Linux)
            local cred_file="$HOME/.claude/.credentials.json"
            [[ -f "$cred_file" ]] && \
                token=$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null) ;;
    esac
    echo "${token:-}"
}

# === CROSS-PLATFORM: Get credential metadata field ===
get_credential_metadata() {
    local field=$1
    case "$(uname -s)" in
        Darwin)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
                | jq -r ".claudeAiOauth.${field} // empty" 2>/dev/null ;;
        Linux)
            local cred_file="$HOME/.claude/.credentials.json"
            [[ -f "$cred_file" ]] && \
                jq -r ".claudeAiOauth.${field} // empty" "$cred_file" 2>/dev/null ;;
    esac
}

# === CACHE ===
CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

# === METHOD B: Try Anthropic API ===
try_api_usage() {
    local token
    token=$(get_oauth_token)

    if [[ -z "$token" ]]; then
        echo '{"success":false,"reason":"no_token"}'
        return
    fi

    local response
    response=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1" 2>/dev/null) || true

    if echo "$response" | jq -e '.five_hour.utilization' >/dev/null 2>&1; then
        local five_hour seven_day five_reset
        five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
        seven_day=$(echo "$response" | jq -r '.seven_day.utilization // 0')
        five_reset=$(echo "$response" | jq -r '.five_hour.resets_at // empty')
        echo "{\"success\":true,\"method\":\"api\",\"five_hour\":$five_hour,\"seven_day\":$seven_day,\"resets_at\":\"$five_reset\"}"
    else
        echo '{"success":false,"reason":"api_error"}'
    fi
}

# === METHOD A: Count user prompts from history ===
count_user_prompts() {
    local prompt_count=0
    local projects_dir="$HOME/.claude/projects"

    if [[ -d "$projects_dir" ]]; then
        while IFS= read -r conv_file; do
            [[ -f "$conv_file" ]] || continue
            local user_msgs
            user_msgs=$(grep -cE '"type":"user"|"role":"user"' "$conv_file" 2>/dev/null) || user_msgs=0
            prompt_count=$((prompt_count + user_msgs))
        done < <(find "$projects_dir" -name "*.jsonl" -mmin -300 2>/dev/null)
    fi

    echo "${prompt_count:-0}"
}

# === METHOD C: Estimate from cost (via ccusage + bun) ===
estimate_from_cost() {
    local bun_path
    bun_path=$(find_bun)

    if [[ -z "$bun_path" ]]; then
        echo '{"cost":0,"entries":0,"estimated_prompts":0,"remaining_mins":0,"burn_rate":0}'
        return
    fi

    local block_json
    block_json=$("$bun_path" x ccusage@latest blocks --active --json 2>/dev/null) || true

    if ! echo "$block_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        echo '{"cost":0,"entries":0,"estimated_prompts":0,"remaining_mins":0,"burn_rate":0}'
        return
    fi

    local cost entries remaining_mins burn_rate estimated_prompts
    cost=$(echo "$block_json" | jq -r '.blocks[0].costUSD // 0')
    entries=$(echo "$block_json" | jq -r '.blocks[0].entries // 0')
    remaining_mins=$(echo "$block_json" | jq -r '.blocks[0].projection.remainingMinutes // 0')
    burn_rate=$(echo "$block_json" | jq -r '.blocks[0].burnRate.costPerHour // 0')
    estimated_prompts=$((entries / 5))

    echo "{\"cost\":$cost,\"entries\":$entries,\"estimated_prompts\":$estimated_prompts,\"remaining_mins\":$remaining_mins,\"burn_rate\":$burn_rate}"
}

# === AUTO-DETECT PLAN TYPE ===
detect_plan() {
    # Manual override
    [[ -n "${CLAUDE_PLAN:-}" ]] && echo "$CLAUDE_PLAN" && return

    # API key user (not subscription)
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "api" && return

    # Check credential metadata first (most reliable)
    local sub_type rate_tier
    sub_type=$(get_credential_metadata "subscriptionType" 2>/dev/null) || sub_type=""
    rate_tier=$(get_credential_metadata "rateLimitTier" 2>/dev/null) || rate_tier=""

    # Enterprise detection
    if [[ "$sub_type" == "enterprise" ]] || [[ "$rate_tier" == *"enterprise"* ]]; then
        echo "max20"
        return
    fi

    # Rate tier based detection
    if [[ -n "$rate_tier" ]]; then
        case "$rate_tier" in
            *20*) echo "max20"; return ;;
            *5*)  echo "max5"; return ;;
            *pro*|*free*) echo "pro"; return ;;
        esac
    fi

    # Subscription type detection
    if [[ -n "$sub_type" ]]; then
        case "$sub_type" in
            *max*20*|*enterprise*) echo "max20"; return ;;
            *max*5*|*max*) echo "max5"; return ;;
            *pro*) echo "pro"; return ;;
        esac
    fi

    # No OAuth token = API user
    local token
    token=$(get_oauth_token)
    [[ -z "$token" ]] && echo "api" && return

    # Fallback: historical cost inference via ccusage
    local bun_path
    bun_path=$(find_bun)

    if [[ -n "$bun_path" ]]; then
        local weekly_json
        weekly_json=$("$bun_path" x ccusage@latest blocks --recent --json 2>/dev/null) || true

        if echo "$weekly_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
            local max_cost max_cost_int
            max_cost=$(echo "$weekly_json" | jq '[.blocks[].costUSD] | max // 0')
            max_cost_int=$(printf "%.0f" "$max_cost" 2>/dev/null) || max_cost_int=0

            if [[ "$max_cost_int" -gt 50 ]]; then
                echo "max20"
            elif [[ "$max_cost_int" -gt 10 ]]; then
                echo "max5"
            else
                echo "pro"
            fi
            return
        fi
    fi

    # Default for subscription users
    echo "max5"
}

# === MAIN ===
main() {
    local output_format="${1:-text}"

    # Detect plan
    local plan
    plan=$(detect_plan)
    local plan_min plan_max cost_limit
    plan_min=$(get_plan_limits "$plan" "min")
    plan_max=$(get_plan_limits "$plan" "max")
    cost_limit=$(get_plan_limits "$plan" "cost")

    # Method B: API
    local api_result api_success
    api_result=$(try_api_usage)
    api_success=$(echo "$api_result" | jq -r '.success')

    # Method C: Cost
    local cost_data cost entries estimated_prompts remaining_mins burn_rate
    cost_data=$(estimate_from_cost)
    cost=$(echo "$cost_data" | jq -r '.cost')
    entries=$(echo "$cost_data" | jq -r '.entries')
    estimated_prompts=$(echo "$cost_data" | jq -r '.estimated_prompts')
    remaining_mins=$(echo "$cost_data" | jq -r '.remaining_mins')
    burn_rate=$(echo "$cost_data" | jq -r '.burn_rate')

    # Method A: Prompt counting
    local actual_prompts
    actual_prompts=$(count_user_prompts)

    # Use estimated prompts as primary, fall back to file-based count
    local prompt_count=$estimated_prompts
    [[ "$prompt_count" -eq 0 ]] 2>/dev/null && prompt_count=$actual_prompts

    # Calculate percentages
    local prompt_percent=0 cost_percent=0 api_percent=0

    if [[ "$plan_max" -gt 0 ]] && [[ "$prompt_count" -gt 0 ]]; then
        prompt_percent=$((prompt_count * 100 / plan_max))
    fi

    if [[ "$cost_limit" -gt 0 ]]; then
        local cost_int
        cost_int=$(printf "%.0f" "$cost" 2>/dev/null) || cost_int=0
        [[ -n "$cost_int" ]] && [[ "$cost_int" -gt 0 ]] && cost_percent=$((cost_int * 100 / cost_limit))
    fi

    if [[ "$api_success" == "true" ]]; then
        api_percent=$(echo "$api_result" | jq -r '.five_hour' | cut -d. -f1)
    fi

    # Determine best usage percentage
    local best_percent=$prompt_percent
    local best_method="prompts"

    if [[ "$api_success" == "true" ]]; then
        best_percent=$api_percent
        best_method="api"
    elif [[ "$prompt_percent" -eq 0 ]] 2>/dev/null && [[ "$cost_percent" -gt 0 ]] 2>/dev/null; then
        best_percent=$cost_percent
        best_method="cost"
    fi

    [[ "$best_percent" -gt 100 ]] 2>/dev/null && best_percent=100

    if [[ "$output_format" == "json" ]]; then
        cat <<EOF
{
  "plan": "$plan",
  "usage": {
    "best_percent": $best_percent,
    "best_method": "$best_method",
    "prompt_percent": $prompt_percent,
    "cost_percent": $cost_percent,
    "api_percent": $api_percent,
    "api_available": $api_success
  },
  "prompts": {
    "counted": $actual_prompts,
    "estimated": $estimated_prompts,
    "limit_min": $plan_min,
    "limit_max": $plan_max
  },
  "cost": {
    "current": $cost,
    "limit": $cost_limit,
    "burn_rate": $burn_rate
  },
  "time": {
    "remaining_mins": $remaining_mins
  },
  "entries": $entries
}
EOF
    else
        # Text output: percent|method|plan|cost|remaining_mins|burn_rate|prompts|limit
        echo "$best_percent|$best_method|$plan|$cost|$remaining_mins|$burn_rate|$prompt_count|$plan_max"
    fi
}

main "$@"
