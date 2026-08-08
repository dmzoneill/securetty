#!/bin/bash
# Log agent session outcomes to JSONL for later analysis.
# Called at session end with: agent exit_code duration_seconds workdir
# Writes one JSON line per session to ~/.securetty/outcomes/YYYY-MM-DD.jsonl
# Silent on success — never pollutes stdout/stderr of the calling process.
set -euo pipefail

main() {
    local agent="${1:?usage: securetty-session-logger.sh <agent> <exit_code> <duration_seconds> <workdir>}"
    local exit_code="${2:?missing exit_code}"
    local duration_seconds="${3:?missing duration_seconds}"
    local workdir="${4:?missing workdir}"

    local outcomes_dir="$HOME/.securetty/outcomes"
    mkdir -p "$outcomes_dir"

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
        >> "$logfile"
}

main "$@" 2>/dev/null || true
