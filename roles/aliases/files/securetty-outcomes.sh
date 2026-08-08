#!/bin/bash
# Session outcome logging helpers — sourced by securetty CLI.
# Provides _log_session_outcome() for recording agent session results.

# Log a completed agent session to the outcomes JSONL ledger.
# Usage: _log_session_outcome <agent> <exit_code> <duration_seconds> <workdir>
# Writes to ~/.securetty/outcomes/YYYY-MM-DD.jsonl (one JSON line per session).
# Silent on success — never pollutes stdout/stderr.
_log_session_outcome() {
    local agent="${1:-unknown}"
    local exit_code="${2:-0}"
    local duration_seconds="${3:-0}"
    local workdir="${4:-$(pwd)}"

    local outcomes_dir="$HOME/.securetty/outcomes"
    mkdir -p "$outcomes_dir" 2>/dev/null || return 0

    local today
    today=$(date +%Y-%m-%d)
    local logfile="$outcomes_dir/${today}.jsonl"

    local timestamp
    timestamp=$(date -u +%FT%TZ)

    local session_id="${PPID:-$RANDOM}"

    printf '{"timestamp":"%s","agent":"%s","exit_code":%d,"duration_seconds":%d,"workdir":"%s","session_id":"%s"}\n' \
        "$timestamp" \
        "$agent" \
        "$exit_code" \
        "$duration_seconds" \
        "$workdir" \
        "$session_id" \
        >> "$logfile" 2>/dev/null || true
}
