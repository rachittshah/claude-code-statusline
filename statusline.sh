#!/bin/bash
# ============================================================================
# Claude Code Enhanced Status Line v2
# ============================================================================
# Uses native JSON fields from Claude Code (Feb 2026+)
# Shows: Dir | Model | Vim | Agent | Context | Git | Lines | Cost | Duration | Usage | Reset
# ============================================================================

set -uo pipefail

# Graceful fallback on any error
trap 'echo "Claude"; exit 0' ERR

# Read JSON from stdin
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
    local percent=$1 width=${2:-10}
    [[ "$percent" -gt 100 ]] && percent=100
    [[ "$percent" -lt 0 ]] && percent=0
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

format_duration() {
    local ms=$1
    local secs=$((ms / 1000))
    if [[ "$secs" -lt 60 ]]; then echo "${secs}s"
    elif [[ "$secs" -lt 3600 ]]; then echo "$((secs / 60))m$((secs % 60))s"
    else echo "$((secs / 3600))h$((secs % 3600 / 60))m"
    fi
}

# === PARSE JSON (single jq call) ===
eval "$(echo "$input" | jq -r '[
  "model_name=" + (.model.display_name // "Claude" | @sh),
  "current_dir=" + (.workspace.current_dir // "" | @sh),
  "context_percent=" + (.context_window.used_percentage // 0 | floor | tostring | @sh),
  "context_size=" + (.context_window.context_window_size // 200000 | tostring | @sh),
  "input_tokens=" + ((.context_window.current_usage.input_tokens // 0) | tostring | @sh),
  "cache_creation=" + ((.context_window.current_usage.cache_creation_input_tokens // 0) | tostring | @sh),
  "cache_read=" + ((.context_window.current_usage.cache_read_input_tokens // 0) | tostring | @sh),
  "total_cost=" + (.cost.total_cost_usd // 0 | tostring | @sh),
  "total_duration_ms=" + (.cost.total_duration_ms // 0 | floor | tostring | @sh),
  "lines_added=" + (.cost.total_lines_added // 0 | tostring | @sh),
  "lines_removed=" + (.cost.total_lines_removed // 0 | tostring | @sh),
  "exceeds_200k=" + (.exceeds_200k_tokens // false | tostring | @sh),
  "vim_mode=" + (.vim.mode // "" | @sh),
  "agent_name=" + (.agent.name // "" | @sh)
] | join("\n")')"

# === BACKWARD COMPAT: Context % fallback ===
token_sum=$((input_tokens + cache_creation + cache_read))
if [[ "$context_percent" -eq 0 ]] && [[ "$token_sum" -gt 0 ]]; then
    context_percent=$((token_sum * 100 / context_size))
fi

# === BUILD OUTPUT ===
SEP=" ${GRAY}│${NC} "

# 1. Directory
dir_name=$(basename "${current_dir:-~}" 2>/dev/null || echo "~")
output="${BLUE}${dir_name}${NC}"

# 2. Model
output+="${SEP}${CYAN}${model_name}${NC}"

# 3. Vim mode (only if present)
if [[ -n "$vim_mode" ]]; then
    case "$vim_mode" in
        NORMAL)  vm="N" ;;
        INSERT)  vm="I" ;;
        VISUAL)  vm="V" ;;
        REPLACE) vm="R" ;;
        *)       vm="${vim_mode:0:1}" ;;
    esac
    output+="${SEP}${YELLOW}${vm}${NC}"
fi

# 4. Agent name (only if present)
[[ -n "$agent_name" ]] && output+="${SEP}${GRAY}${agent_name}${NC}"

# 5. Context window bar + overflow warning
context_bar=$(build_bar "$context_percent" 10)
context_color=$(get_color "$context_percent")
overflow=""
[[ "$exceeds_200k" == "true" ]] && overflow=" ${RED}!${NC}"
output+="${SEP}${context_color}${context_bar}${NC} ${context_percent}%${overflow}"

# 6. Git status (using git -C for safety)
if [[ -n "$current_dir" ]] && git -C "$current_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$current_dir" branch --show-current 2>/dev/null || echo "HEAD")
    dirty=$(git -C "$current_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dirty" -gt 0 ]]; then
        output+="${SEP}${YELLOW}${branch}${NC}${GRAY}*${dirty}${NC}"
    else
        output+="${SEP}${YELLOW}${branch}${NC}"
    fi
fi

# 7. Lines added/removed (only if any)
if [[ "$lines_added" -gt 0 ]] || [[ "$lines_removed" -gt 0 ]]; then
    output+="${SEP}${GREEN}+${lines_added}${NC}${RED}-${lines_removed}${NC}"
fi

# 8. Session cost
cost_fmt=$(printf "%.2f" "$total_cost" 2>/dev/null || echo "0.00")
output+="${SEP}${CYAN}\$${cost_fmt}${NC}"

# 9. Duration (only if > 0)
if [[ "$total_duration_ms" -gt 0 ]]; then
    output+="${SEP}${GRAY}$(format_duration "$total_duration_ms")${NC}"
fi

# 10-11. Usage bar + reset time (from usage-detector)
detector_output=$("$HOME/.claude/statusline/usage-detector.sh" json 2>/dev/null || true)

if [[ -n "$detector_output" ]] && echo "$detector_output" | jq -e '.plan' >/dev/null 2>&1; then
    eval "$(echo "$detector_output" | jq -r '[
      "best_percent=" + (.usage.best_percent | tostring | @sh),
      "remaining_mins=" + (.time.remaining_mins | tostring | @sh),
      "plan=" + (.plan | @sh)
    ] | join("\n")')"

    usage_bar=$(build_bar "$best_percent" 8)
    usage_color=$(get_color "$best_percent")

    case "$plan" in
        max20)      plan_badge="20x" ;;
        max5)       plan_badge="5x" ;;
        pro)        plan_badge="Pro" ;;
        enterprise) plan_badge="Ent" ;;
        *)          plan_badge="" ;;
    esac

    output+="${SEP}${usage_color}${usage_bar}${NC} ${best_percent}%"
    [[ -n "$plan_badge" ]] && output+=" ${GRAY}${plan_badge}${NC}"

    if [[ "$remaining_mins" -gt 0 ]] 2>/dev/null; then
        if [[ "$remaining_mins" -lt 60 ]]; then
            output+="${SEP}${GRAY}r:${remaining_mins}m${NC}"
        else
            output+="${SEP}${GRAY}r:$((remaining_mins / 60))h$((remaining_mins % 60))m${NC}"
        fi
    fi
fi

echo -e "$output"
