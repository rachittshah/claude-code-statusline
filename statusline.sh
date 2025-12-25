#!/bin/bash
# ============================================================================
# Claude Code Enhanced Status Line with Auto-Detection
# ============================================================================
# Shows: Directory | Model | Context Bar | Git | Usage Bar (auto-detected plan)
# ============================================================================

# Read JSON input from Claude Code
input=$(cat)

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# === HELPERS ===
build_bar() {
    local percent=$1
    local width=${2:-10}
    [ "$percent" -gt 100 ] && percent=100
    [ "$percent" -lt 0 ] && percent=0
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

get_color() {
    local percent=$1
    if [ "$percent" -ge 80 ]; then echo "$RED"
    elif [ "$percent" -ge 50 ]; then echo "$YELLOW"
    else echo "$GREEN"
    fi
}

# === PARSE CLAUDE CODE JSON ===
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
current_usage=$(echo "$input" | jq '.context_window.current_usage')

# Context percentage
if [ "$current_usage" != "null" ]; then
    current_tokens=$(echo "$current_usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    context_percent=$((current_tokens * 100 / context_size))
else
    context_percent=0
fi

context_bar=$(build_bar $context_percent 10)
context_color=$(get_color $context_percent)
dir_name=$(basename "$current_dir" 2>/dev/null || echo "~")

# === GIT STATUS ===
git_info=""
if [ -n "$current_dir" ]; then
    cd "$current_dir" 2>/dev/null || cd /
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        branch=$(git branch --show-current 2>/dev/null || echo "HEAD")
        status_output=$(git status --porcelain 2>/dev/null)
        if [ -n "$status_output" ]; then
            total_files=$(echo "$status_output" | wc -l | xargs)
            git_info="${YELLOW}${branch}${NC}${GRAY}*${total_files}${NC}"
        else
            git_info="${YELLOW}${branch}${NC}"
        fi
    fi
fi

# === USAGE DETECTION (auto-detect plan, use all 3 methods) ===
usage_info=""
detector_output=$("$HOME/.claude/usage-detector.sh" json 2>/dev/null)

if echo "$detector_output" | jq -e '.plan' >/dev/null 2>&1; then
    plan=$(echo "$detector_output" | jq -r '.plan')
    best_percent=$(echo "$detector_output" | jq -r '.usage.best_percent')
    best_method=$(echo "$detector_output" | jq -r '.usage.best_method')
    cost=$(echo "$detector_output" | jq -r '.cost.current')
    remaining_mins=$(echo "$detector_output" | jq -r '.time.remaining_mins')
    burn_rate=$(echo "$detector_output" | jq -r '.cost.burn_rate')
    prompt_count=$(echo "$detector_output" | jq -r '.prompts.estimated')
    prompt_limit=$(echo "$detector_output" | jq -r '.prompts.limit_max')

    # Build usage bar
    usage_bar=$(build_bar $best_percent 8)
    usage_color=$(get_color $best_percent)
    cost_fmt=$(printf "%.1f" "$cost" 2>/dev/null || echo "$cost")

    # Format time
    if [ "$remaining_mins" -le 0 ] 2>/dev/null; then
        time_left="reset"
    elif [ "$remaining_mins" -lt 60 ] 2>/dev/null; then
        time_left="${remaining_mins}m"
    else
        time_left="$((remaining_mins / 60))h$((remaining_mins % 60))m"
    fi

    # Plan badge
    case "$plan" in
        max20) plan_badge="20x" ;;
        max5)  plan_badge="5x" ;;
        pro)   plan_badge="Pro" ;;
        *)     plan_badge="" ;;
    esac

    # Usage info: [████████░░] 87% 5x | $12 ⏱3h
    usage_info="${usage_color}${usage_bar}${NC} ${best_percent}%"
    [ -n "$plan_badge" ] && usage_info+=" ${GRAY}${plan_badge}${NC}"
    usage_info+=" ${GRAY}|${NC} ${CYAN}\$${cost_fmt}${NC} ${GRAY}⏱${time_left}${NC}"
fi

# === BUILD OUTPUT ===
output="${BLUE}${dir_name}${NC}"
output+=" ${GRAY}|${NC} ${CYAN}${model_name}${NC}"
output+=" ${GRAY}|${NC} ${context_color}${context_bar}${NC} ${context_percent}%"
[ -n "$git_info" ] && output+=" ${GRAY}|${NC} ${git_info}"
[ -n "$usage_info" ] && output+=" ${GRAY}|${NC} ${usage_info}"

echo -e "$output"
