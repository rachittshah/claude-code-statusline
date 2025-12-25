#!/bin/bash
# ============================================================================
# Claude Code Enhanced Status Line with Usage Tracking
# ============================================================================
#
# Shows: Directory | Model | Context Bar | Git Status | 5hr Usage + Cost
#
# INSTALLATION:
#   1. Save this file to ~/.claude/statusline.sh
#   2. chmod +x ~/.claude/statusline.sh
#   3. Add to ~/.claude/settings.json:
#      {
#        "statusLine": {
#          "type": "command",
#          "command": "~/.claude/statusline.sh"
#        }
#      }
#
# REQUIREMENTS:
#   - jq (brew install jq)
#   - bun (curl -fsSL https://bun.sh/install | bash) - for ccusage
#   - ccusage runs via: bunx ccusage@latest (auto-installed on first run)
#
# CONFIGURATION:
#   Set your Max plan limit (cost per 5hr block):
#   - Max 5x:  export CLAUDE_BLOCK_LIMIT=35
#   - Max 20x: export CLAUDE_BLOCK_LIMIT=140
#   - Pro:     export CLAUDE_BLOCK_LIMIT=10
#
# OUTPUT EXAMPLE:
#   myproject | Claude Opus 4.5 | ctx:████░░░░░░░░ 35% | main 3f +45 -12 | ██████░░ 67% $23.50 (2h15m @$1.58/h)
#
# GIST: https://gist.github.com/your-username/your-gist-id
# ============================================================================

# Read JSON input from Claude Code (piped via stdin)
input=$(cat)

# === COLORS ===
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# === CONFIG ===
# Max plan cost limit per 5hr block - adjust based on your plan
MAX_COST_PER_BLOCK=${CLAUDE_BLOCK_LIMIT:-35}

# === HELPER FUNCTIONS ===

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

# === PARSE CLAUDE CODE JSON INPUT ===

model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
current_usage=$(echo "$input" | jq '.context_window.current_usage')

# Calculate context window percentage
if [ "$current_usage" != "null" ]; then
    current_tokens=$(echo "$current_usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    context_percent=$((current_tokens * 100 / context_size))
else
    context_percent=0
fi

# Build context bar
context_bar=$(build_bar $context_percent 12)
context_color=$(get_color $context_percent)

# Get directory name
dir_name=$(basename "$current_dir" 2>/dev/null || echo "~")

# === GIT STATUS ===

git_info=""
if [ -n "$current_dir" ]; then
    cd "$current_dir" 2>/dev/null || cd /
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        branch=$(git branch --show-current 2>/dev/null || echo "detached")
        status_output=$(git status --porcelain 2>/dev/null)

        if [ -n "$status_output" ]; then
            total_files=$(echo "$status_output" | wc -l | xargs)
            line_stats=$(git diff --numstat HEAD 2>/dev/null | awk '{added+=$1; removed+=$2} END {print added+0, removed+0}')
            added=$(echo $line_stats | cut -d' ' -f1)
            removed=$(echo $line_stats | cut -d' ' -f2)

            git_info="${YELLOW}${branch}${NC} ${GRAY}${total_files}f${NC}"
            [ "$added" -gt 0 ] && git_info+=" ${GREEN}+${added}${NC}"
            [ "$removed" -gt 0 ] && git_info+=" ${RED}-${removed}${NC}"
        else
            git_info="${YELLOW}${branch}${NC}"
        fi
    fi
fi

# === 5-HOUR BLOCK USAGE (via ccusage) ===
# ccusage analyzes local ~/.claude/projects/ files to calculate usage
# It tracks tokens/cost within the 5-hour billing windows

usage_info=""

# Try bun first, fall back to npx
if command -v bun &>/dev/null; then
    CCUSAGE_CMD="bun x ccusage@latest"
elif [ -x "$HOME/.bun/bin/bun" ]; then
    CCUSAGE_CMD="$HOME/.bun/bin/bun x ccusage@latest"
elif command -v npx &>/dev/null; then
    CCUSAGE_CMD="npx ccusage@latest"
else
    CCUSAGE_CMD=""
fi

if [ -n "$CCUSAGE_CMD" ]; then
    block_json=$($CCUSAGE_CMD blocks --active --json 2>/dev/null)

    if echo "$block_json" | jq -e '.blocks[0]' >/dev/null 2>&1; then
        cost=$(echo "$block_json" | jq -r '.blocks[0].costUSD // 0')
        remaining_mins=$(echo "$block_json" | jq -r '.blocks[0].projection.remainingMinutes // 0')
        burn_rate=$(echo "$block_json" | jq -r '.blocks[0].burnRate.costPerHour // 0')

        # Calculate usage percentage based on cost limit
        cost_int=$(printf "%.0f" "$cost")
        usage_percent=$((cost_int * 100 / MAX_COST_PER_BLOCK))
        [ "$usage_percent" -gt 100 ] && usage_percent=100

        # Build visual elements
        usage_bar=$(build_bar $usage_percent 8)
        usage_color=$(get_color $usage_percent)
        cost_fmt=$(printf "%.2f" "$cost")
        burn_fmt=$(printf "%.1f" "$burn_rate")

        # Format time remaining
        if [ "$remaining_mins" -le 0 ]; then
            time_left="now"
        elif [ "$remaining_mins" -lt 60 ]; then
            time_left="${remaining_mins}m"
        else
            time_left="$((remaining_mins / 60))h$((remaining_mins % 60))m"
        fi

        usage_info="${usage_color}${usage_bar}${NC} ${usage_percent}% ${CYAN}\$${cost_fmt}${NC} ${GRAY}(${time_left} @\$${burn_fmt}/h)${NC}"
    fi
fi

# === BUILD FINAL OUTPUT ===

output="${BLUE}${dir_name}${NC}"
output+=" ${GRAY}|${NC} ${CYAN}${model_name}${NC}"
output+=" ${GRAY}|${NC} ${GRAY}ctx:${NC}${context_color}${context_bar}${NC} ${context_percent}%"

[ -n "$git_info" ] && output+=" ${GRAY}|${NC} ${git_info}"
[ -n "$usage_info" ] && output+=" ${GRAY}|${NC} ${usage_info}"

echo -e "$output"
