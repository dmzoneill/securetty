#!/bin/bash
# Securetty statusline for Claude Code — shows session info in status bar
# Called by Claude Code via settings.json statusLine command
set -uo pipefail

# Read JSON input from stdin
input=$(cat)

# Container name (from hostname — strips securetty- prefix)
container=$(hostname 2>/dev/null | sed 's/securetty-//' || echo "?")

# Session cost (if available)
cost_info=""
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
if [ -n "$cost" ]; then
    cost_info=$(printf " | \$%.4f" "$cost")
fi

# Mode
mode="personal"
[ -n "${CLAUDE_CODE_USE_VERTEX:-}" ] && mode="vertex"
[ -n "${SECURETTY_MODE:-}" ] && mode="$SECURETTY_MODE"

# Context window percentage with color-coded bar
ctx_info=""
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
if [ -n "$used" ]; then
    context_pct=$(printf "%.0f" "$used")
    bar_width=10
    filled=$(( (context_pct * bar_width + 50) / 100 ))
    empty=$(( bar_width - filled ))
    bar=""
    [ "$filled" -gt 0 ] && bar=$(printf '%0.s#' $(seq 1 $filled))
    [ "$empty" -gt 0 ] && bar="${bar}$(printf '%0.s-' $(seq 1 $empty))"
    if [ "$context_pct" -ge 90 ]; then
        ctx_color="\033[1;91m"
    elif [ "$context_pct" -ge 70 ]; then
        ctx_color="\033[31m"
    elif [ "$context_pct" -ge 50 ]; then
        ctx_color="\033[33m"
    else
        ctx_color="\033[32m"
    fi
    ctx_info=" | ${ctx_color}${bar} ${context_pct}%\033[0m"
fi

# Model name
model_info=""
model_name=$(echo "$input" | jq -r '.model.display_name // empty' 2>/dev/null)
[ -n "$model_name" ] && model_info=" | $model_name"

# Today's session count
today_count=0
today_file="$HOME/.securetty/cost/$(date +%Y-%m-%d).jsonl"
[ -f "$today_file" ] && today_count=$(wc -l < "$today_file")

# Build status line
printf "securetty | %s | %s%s%b%s | #%s today" \
    "$container" "$mode" "$cost_info" "$ctx_info" "$model_info" "$today_count"
