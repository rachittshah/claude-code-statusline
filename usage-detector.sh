#!/bin/bash
# ============================================================================
# Claude Code Usage Detector - Auto-detect plan and accurate usage tracking
# ============================================================================
# Combines 3 methods:
#   A. Count user prompts from history files (most accurate)
#   B. Try Anthropic API (future-proof, currently blocked by scope)
#   C. Cost correlation estimation (fallback)
# ============================================================================

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# === PLAN LIMITS FUNCTION ===
get_plan_limits() {
    local plan=$1
    local type=$2  # min, max, cost
    case "$plan" in
        pro)
            case "$type" in
                min) echo 10 ;;
                max) echo 40 ;;
                cost) echo 10 ;;
            esac
            ;;
        max5)
            case "$type" in
                min) echo 50 ;;
                max) echo 200 ;;
                cost) echo 35 ;;
            esac
            ;;
        max20)
            case "$type" in
                min) echo 200 ;;
                max) echo 800 ;;
                cost) echo 140 ;;
            esac
            ;;
        api|*)
            echo 999999
            ;;
    esac
}

# === CACHE ===
CACHE_DIR="$HOME/.claude/cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

# === METHOD B: Try Anthropic API ===
try_api_usage() {
    local token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)

    if [ -z "$token" ]; then
        echo '{"success":false,"reason":"no_token"}'
        return
    fi

    local response=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.0.32" 2>/dev/null)

    if echo "$response" | jq -e '.five_hour.utilization' >/dev/null 2>&1; then
        local five_hour=$(echo "$response" | jq -r '.five_hour.utilization // 0')
        local seven_day=$(echo "$response" | jq -r '.seven_day.utilization // 0')
        local five_reset=$(echo "$response" | jq -r '.five_hour.resets_at // empty')
        echo "{\"success\":true,\"method\":\"api\",\"five_hour\":$five_hour,\"seven_day\":$seven_day,\"resets_at\":\"$five_reset\"}"
    else
        echo '{"success":false,"reason":"api_error"}'
    fi
}

# === METHOD A: Count user prompts from history ===
count_user_prompts() {
    local prompt_count=0
    local projects_dir="$HOME/.claude/projects"

    if [ -d "$projects_dir" ]; then
        # Find conversation files modified in last 5 hours and count user messages
        for conv_file in $(find "$projects_dir" -name "*.jsonl" -mmin -300 2>/dev/null); do
            if [ -f "$conv_file" ]; then
                local user_msgs=$(grep -cE '"type":"user"|"role":"user"' "$conv_file" 2>/dev/null)
                user_msgs=${user_msgs:-0}
                prompt_count=$((prompt_count + user_msgs))
            fi
        done
    fi

    # Ensure we return a number
    [ -z "$prompt_count" ] && prompt_count=0
    echo "$prompt_count"
}

# === METHOD C: Estimate from cost ===
estimate_from_cost() {
    local block_json=$("$HOME/.bun/bin/bun" x ccusage@latest blocks --active --json 2>/dev/null)

    if ! echo "$block_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        echo '{"cost":0,"entries":0,"estimated_prompts":0,"remaining_mins":0,"burn_rate":0}'
        return
    fi

    local cost=$(echo "$block_json" | jq -r '.blocks[0].costUSD // 0')
    local entries=$(echo "$block_json" | jq -r '.blocks[0].entries // 0')
    local remaining_mins=$(echo "$block_json" | jq -r '.blocks[0].projection.remainingMinutes // 0')
    local burn_rate=$(echo "$block_json" | jq -r '.blocks[0].burnRate.costPerHour // 0')

    # Estimate prompts: 1 user prompt ≈ 5 API entries on average
    # (includes tool calls, sub-agents, retries, etc.)
    local estimated_prompts=$((entries / 5))

    echo "{\"cost\":$cost,\"entries\":$entries,\"estimated_prompts\":$estimated_prompts,\"remaining_mins\":$remaining_mins,\"burn_rate\":$burn_rate}"
}

# === AUTO-DETECT PLAN TYPE ===
detect_plan() {
    # Check for manual override
    if [ -n "$CLAUDE_PLAN" ]; then
        echo "$CLAUDE_PLAN"
        return
    fi

    # Check if using API key (not subscription)
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        echo "api"
        return
    fi

    # Check OAuth token exists (subscription user)
    local has_oauth=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -z "$has_oauth" ]; then
        echo "api"
        return
    fi

    # Use historical peak to detect plan (P90 method)
    local weekly_json=$("$HOME/.bun/bin/bun" x ccusage@latest blocks --recent --json 2>/dev/null)
    if echo "$weekly_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        local max_cost=$(echo "$weekly_json" | jq '[.blocks[].costUSD] | max // 0')
        local max_cost_int=$(printf "%.0f" "$max_cost" 2>/dev/null || echo 0)

        # Infer plan from max usage patterns
        if [ "$max_cost_int" -gt 50 ] 2>/dev/null; then
            echo "max20"
        elif [ "$max_cost_int" -gt 10 ] 2>/dev/null; then
            echo "max5"
        else
            echo "pro"
        fi
    else
        # Default to max5 for subscription users
        echo "max5"
    fi
}

# === MAIN: Combine all methods ===
main() {
    local output_format="${1:-text}"

    # Detect plan
    local plan=$(detect_plan)
    local plan_min=$(get_plan_limits "$plan" "min")
    local plan_max=$(get_plan_limits "$plan" "max")
    local cost_limit=$(get_plan_limits "$plan" "cost")

    # Try API first (Method B)
    local api_result=$(try_api_usage)
    local api_success=$(echo "$api_result" | jq -r '.success')

    # Get cost data (Method C)
    local cost_data=$(estimate_from_cost)
    local cost=$(echo "$cost_data" | jq -r '.cost')
    local entries=$(echo "$cost_data" | jq -r '.entries')
    local estimated_prompts=$(echo "$cost_data" | jq -r '.estimated_prompts')
    local remaining_mins=$(echo "$cost_data" | jq -r '.remaining_mins')
    local burn_rate=$(echo "$cost_data" | jq -r '.burn_rate')

    # Count actual prompts (Method A) - less reliable for current block
    local actual_prompts=$(count_user_prompts)

    # Use estimated prompts (from entries) as primary - more accurate for current block
    # Entry-based estimation correlates better with Anthropic's counting
    local prompt_count=$estimated_prompts

    # Only use file-based count if estimation failed
    [ "$prompt_count" -eq 0 ] 2>/dev/null && prompt_count=$actual_prompts

    # Calculate percentages
    local prompt_percent=0
    local cost_percent=0
    local api_percent=0

    if [ "$plan_max" -gt 0 ] && [ "$prompt_count" -gt 0 ]; then
        prompt_percent=$((prompt_count * 100 / plan_max))
    fi

    if [ "$cost_limit" -gt 0 ]; then
        local cost_int=$(printf "%.0f" "$cost" 2>/dev/null || echo 0)
        [ -n "$cost_int" ] && [ "$cost_int" -gt 0 ] && cost_percent=$((cost_int * 100 / cost_limit))
    fi

    if [ "$api_success" = "true" ]; then
        api_percent=$(echo "$api_result" | jq -r '.five_hour' | cut -d. -f1)
    fi

    # Determine best usage percentage
    local best_percent=$prompt_percent
    local best_method="prompts"

    if [ "$api_success" = "true" ]; then
        best_percent=$api_percent
        best_method="api"
    elif [ "$prompt_percent" -eq 0 ] 2>/dev/null && [ "$cost_percent" -gt 0 ] 2>/dev/null; then
        best_percent=$cost_percent
        best_method="cost"
    fi

    [ "$best_percent" -gt 100 ] 2>/dev/null && best_percent=100

    if [ "$output_format" = "json" ]; then
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
