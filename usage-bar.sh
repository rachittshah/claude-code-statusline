#!/bin/bash
# ============================================================================
# Claude Code Usage Bar - Standalone 5-hour block usage with visual bars
# ============================================================================
# Uses ccusage (via bun) for local file analysis
# Cross-platform: macOS + Linux
# ============================================================================

set -uo pipefail

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Max plan limits (approximate - adjust based on your plan)
# Max 5x: ~$50/5hr block, Max 20x: ~$200/5hr block
MAX_COST_PER_BLOCK=${CLAUDE_BLOCK_LIMIT:-50}

# === CROSS-PLATFORM: Find bun ===
find_bun() {
    local candidate
    for candidate in "$HOME/.bun/bin/bun" "/usr/local/bin/bun" "/opt/homebrew/bin/bun"; do
        [[ -x "$candidate" ]] && echo "$candidate" && return
    done
    command -v bun 2>/dev/null || true
}

# === HELPERS ===
build_bar() {
    local percent=$1 width=${2:-10}
    [[ "$percent" -gt 100 ]] && percent=100
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

get_color() {
    local percent=$1
    if [[ "$percent" -ge 80 ]]; then echo "$RED"
    elif [[ "$percent" -ge 50 ]]; then echo "$YELLOW"
    else echo "$GREEN"
    fi
}

format_time() {
    local minutes=$1
    if [[ "$minutes" -le 0 ]]; then echo "now"
    elif [[ "$minutes" -lt 60 ]]; then echo "${minutes}m"
    else echo "$((minutes / 60))h$((minutes % 60))m"
    fi
}

main() {
    # Find bun
    local bun_path
    bun_path=$(find_bun)

    if [[ -z "$bun_path" ]]; then
        echo -e "${GRAY}bun not found — install: curl -fsSL https://bun.sh/install | bash${NC}"
        exit 0
    fi

    # Get active block data from ccusage
    local block_json
    block_json=$("$bun_path" x ccusage@latest blocks --active --json 2>/dev/null) || true

    if [[ -z "$block_json" ]] || ! echo "$block_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        echo -e "${GRAY}No active session${NC}"
        exit 0
    fi

    # Parse block data
    local cost remaining_mins burn_rate projected_cost
    cost=$(echo "$block_json" | jq -r '.blocks[0].costUSD // 0')
    remaining_mins=$(echo "$block_json" | jq -r '.blocks[0].projection.remainingMinutes // 0')
    burn_rate=$(echo "$block_json" | jq -r '.blocks[0].burnRate.costPerHour // 0')
    projected_cost=$(echo "$block_json" | jq -r '.blocks[0].projection.totalCost // 0')

    # Calculate percentage
    local cost_int percent
    cost_int=$(printf "%.0f" "$cost")
    percent=$((cost_int * 100 / MAX_COST_PER_BLOCK))
    [[ "$percent" -gt 100 ]] && percent=100

    # Build visual elements
    local bar color time_left
    bar=$(build_bar "$percent" 12)
    color=$(get_color "$percent")
    time_left=$(format_time "$remaining_mins")

    # Format cost display
    local cost_fmt burn_fmt proj_fmt
    cost_fmt=$(printf "%.2f" "$cost")
    burn_fmt=$(printf "%.2f" "$burn_rate")
    proj_fmt=$(printf "%.2f" "$projected_cost")

    # Output: 5h: [████████░░░░] 67% $23.50 | ⏱ 48m | 🔥 $1.58/hr → $28
    echo -e "${GRAY}5h:${NC} ${color}${bar}${NC} ${percent}% ${CYAN}\$${cost_fmt}${NC} ${GRAY}|${NC} ${GRAY}⏱${NC} ${time_left} ${GRAY}|${NC} ${GRAY}🔥${NC} \$${burn_fmt}/hr ${GRAY}→${NC} \$${proj_fmt}"
}

main "$@"
