#!/bin/bash

# Claude Code Usage Bar - Shows 5-hour block usage with visual bars
# Uses ccusage for local file analysis (no API scope issues)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Max plan limits (approximate - adjust based on your plan)
# Max 5x: ~$35/5hr block, Max 20x: ~$140/5hr block
MAX_COST_PER_BLOCK=${CLAUDE_BLOCK_LIMIT:-35}

# Build progress bar
build_bar() {
    local percent=$1
    local width=${2:-10}
    [ "$percent" -gt 100 ] && percent=100
    local filled=$((percent * width / 100))
    local empty=$((width - filled))

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

# Get color based on percentage
get_color() {
    local percent=$1
    if [ "$percent" -ge 80 ]; then
        echo "$RED"
    elif [ "$percent" -ge 50 ]; then
        echo "$YELLOW"
    else
        echo "$GREEN"
    fi
}

# Format time remaining
format_time() {
    local minutes=$1
    if [ "$minutes" -le 0 ]; then
        echo "now"
    elif [ "$minutes" -lt 60 ]; then
        echo "${minutes}m"
    else
        local hours=$((minutes / 60))
        local mins=$((minutes % 60))
        echo "${hours}h${mins}m"
    fi
}

main() {
    # Get active block data from ccusage
    local block_json=$(~/.bun/bin/bun x ccusage@latest blocks --active --json 2>/dev/null)

    if [ -z "$block_json" ] || ! echo "$block_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        echo -e "${GRAY}No active session${NC}"
        exit 0
    fi

    # Parse block data
    local cost=$(echo "$block_json" | jq -r '.blocks[0].costUSD // 0')
    local remaining_mins=$(echo "$block_json" | jq -r '.blocks[0].projection.remainingMinutes // 0')
    local burn_rate=$(echo "$block_json" | jq -r '.blocks[0].burnRate.costPerHour // 0')
    local projected_cost=$(echo "$block_json" | jq -r '.blocks[0].projection.totalCost // 0')

    # Calculate percentage based on estimated limit
    local cost_int=$(printf "%.0f" "$cost")
    local percent=$((cost_int * 100 / MAX_COST_PER_BLOCK))
    [ "$percent" -gt 100 ] && percent=100

    # Build visual elements
    local bar=$(build_bar $percent 12)
    local color=$(get_color $percent)
    local time_left=$(format_time $remaining_mins)

    # Format cost display
    local cost_fmt=$(printf "%.2f" "$cost")
    local burn_fmt=$(printf "%.2f" "$burn_rate")
    local proj_fmt=$(printf "%.2f" "$projected_cost")

    # Output: 5h: [████████░░░░] 67% $23.50 | ⏱ 48m | 🔥 $1.58/hr → $28
    echo -e "${GRAY}5h:${NC} ${color}${bar}${NC} ${percent}% ${CYAN}\$${cost_fmt}${NC} ${GRAY}|${NC} ${GRAY}⏱${NC} ${time_left} ${GRAY}|${NC} ${GRAY}🔥${NC} \$${burn_fmt}/hr ${GRAY}→${NC} \$${proj_fmt}"
}

main "$@"
