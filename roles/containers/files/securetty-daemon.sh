#!/bin/bash
# securetty-daemon — host-side background agent that polls the dispatcher
# for pending jobs and executes them via the securetty CLI.
# Reads optional bot account config from ~/.securetty/bot.yaml for
# autonomous commits with a separate git identity.
set -euo pipefail

SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_DIR="$HOME/.securetty"
PID_FILE="$DAEMON_DIR/daemon.pid"
LOG_FILE="$DAEMON_DIR/daemon.log"
BOT_CONFIG="$DAEMON_DIR/bot.yaml"
POLL_INTERVAL="${SECURETTY_DAEMON_POLL:-10}"
MAX_SESSIONS="${SECURETTY_DAEMON_MAX_SESSIONS:-3}"
DISPATCHER_URL="${SECURETTY_DISPATCHER_URL:-https://securetty-dispatcher:8900}"

# Track child PIDs for graceful shutdown
declare -A _active_jobs=()
_shutting_down=0

# =============================================================================
# Logging
# =============================================================================

_log() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts $*" >> "$LOG_FILE"
}

_log_stdout() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts $*" | tee -a "$LOG_FILE"
}

# =============================================================================
# Dispatcher communication
# =============================================================================

_cert_args() {
    local args=""
    [ -f "$SECURETTY_DIR/certs/client.crt" ] && \
        args="--cert $SECURETTY_DIR/certs/client.crt --key $SECURETTY_DIR/certs/client.key --cacert $SECURETTY_DIR/certs/ca.crt"
    echo "$args"
}

_dispatcher_get() {
    local path="$1"
    local cert_args
    cert_args=$(_cert_args)
    # shellcheck disable=SC2086
    curl $cert_args -sf "${DISPATCHER_URL}${path}" 2>/dev/null || echo ""
}

_dispatcher_post() {
    local path="$1"
    local body="${2:-}"
    local cert_args
    cert_args=$(_cert_args)
    if [ -n "$body" ]; then
        # shellcheck disable=SC2086
        curl $cert_args -sf -X POST "${DISPATCHER_URL}${path}" \
            -H "Content-Type: application/json" -d "$body" 2>/dev/null || echo ""
    else
        # shellcheck disable=SC2086
        curl $cert_args -sf -X POST "${DISPATCHER_URL}${path}" 2>/dev/null || echo ""
    fi
}

# =============================================================================
# Bot account config
# =============================================================================

_load_bot_config() {
    BOT_GIT_NAME=""
    BOT_GIT_EMAIL=""
    [ -f "$BOT_CONFIG" ] || return 0

    # Simple YAML parsing — bot.yaml is a flat file:
    #   git:
    #     user.name: securetty-bot
    #     user.email: securetty-bot@example.com
    BOT_GIT_NAME=$(grep -E '^\s+user\.name:' "$BOT_CONFIG" 2>/dev/null | sed 's/.*user\.name:\s*//' | xargs || true)
    BOT_GIT_EMAIL=$(grep -E '^\s+user\.email:' "$BOT_CONFIG" 2>/dev/null | sed 's/.*user\.email:\s*//' | xargs || true)

    if [ -n "$BOT_GIT_NAME" ]; then
        _log "bot config loaded: name=$BOT_GIT_NAME email=$BOT_GIT_EMAIL"
    fi
}

# =============================================================================
# Job execution
# =============================================================================

_active_count() {
    local count=0
    for pid in "${!_active_jobs[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            count=$((count + 1))
        else
            # Process finished — clean up
            local job_id="${_active_jobs[$pid]}"
            wait "$pid" 2>/dev/null || true
            unset "_active_jobs[$pid]"
            _log "job $job_id finished (pid $pid)"
        fi
    done
    echo "$count"
}

_execute_job() {
    local job_id="$1"
    local work_item="$2"
    local agent="${3:-claude}"
    local skill="${4:-}"

    (
        _log "executing job $job_id: agent=$agent work_item=$work_item"

        # Build the agent command
        local prompt="$work_item"
        [ -n "$skill" ] && prompt="/$skill $work_item"

        # Use securetty CLI to launch the agent in a container
        local exit_code=0
        if [ -n "${BOT_GIT_NAME:-}" ]; then
            # Pass bot identity via environment
            SECURETTY_BOT_GIT_NAME="$BOT_GIT_NAME" \
            SECURETTY_BOT_GIT_EMAIL="$BOT_GIT_EMAIL" \
            DISPATCH_JOB_ID="$job_id" \
                "$SECURETTY_DIR/securetty" run "$agent" --print --prompt "$prompt" \
                >> "$LOG_FILE" 2>&1 || exit_code=$?
        else
            DISPATCH_JOB_ID="$job_id" \
                "$SECURETTY_DIR/securetty" run "$agent" --print --prompt "$prompt" \
                >> "$LOG_FILE" 2>&1 || exit_code=$?
        fi

        _log "job $job_id completed: exit_code=$exit_code"
    ) &

    local child_pid=$!
    _active_jobs[$child_pid]="$job_id"
    _log "job $job_id started (pid $child_pid)"
}

# =============================================================================
# Main loop
# =============================================================================

_poll_and_dispatch() {
    local active
    active=$(_active_count)

    if [ "$active" -ge "$MAX_SESSIONS" ]; then
        return 0
    fi

    local available=$((MAX_SESSIONS - active))

    # Fetch pending jobs from dispatcher
    local response
    response=$(_dispatcher_get "/jobs?status=pending&limit=$available")
    [ -z "$response" ] && return 0

    # Parse job IDs and work items using python3 (always available)
    local jobs_json
    jobs_json=$(echo "$response" | python3 -c "
import json, sys
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        jid = j.get('id', '')
        work = j.get('work_item', '')
        agent = j.get('agent', 'claude')
        skill = j.get('skill', '') or ''
        print(f'{jid}\t{work}\t{agent}\t{skill}')
except:
    pass
" 2>/dev/null || true)

    [ -z "$jobs_json" ] && return 0

    while IFS=$'\t' read -r job_id work_item agent skill; do
        [ -z "$job_id" ] && continue

        # Skip jobs already being handled
        local already_running=0
        for pid in "${!_active_jobs[@]}"; do
            if [ "${_active_jobs[$pid]}" = "$job_id" ]; then
                already_running=1
                break
            fi
        done
        [ "$already_running" -eq 1 ] && continue

        active=$(_active_count)
        [ "$active" -ge "$MAX_SESSIONS" ] && break

        _log_stdout "picking up job $job_id: $work_item (agent=$agent)"
        _execute_job "$job_id" "$work_item" "$agent" "$skill"
    done <<< "$jobs_json"
}

_main_loop() {
    _log_stdout "daemon started (pid $$, poll=${POLL_INTERVAL}s, max_sessions=$MAX_SESSIONS)"
    _load_bot_config

    # Check dispatcher connectivity
    local health
    health=$(_dispatcher_get "/health")
    if [ -z "$health" ]; then
        _log_stdout "WARNING: dispatcher unreachable at $DISPATCHER_URL"
    else
        _log_stdout "dispatcher connected: $health"
    fi

    while [ "$_shutting_down" -eq 0 ]; do
        _poll_and_dispatch
        sleep "$POLL_INTERVAL" &
        wait $! 2>/dev/null || true
    done
}

# =============================================================================
# Signal handling
# =============================================================================

_shutdown() {
    _shutting_down=1
    _log_stdout "shutting down (received signal)"

    # Terminate active jobs
    for pid in "${!_active_jobs[@]}"; do
        local job_id="${_active_jobs[$pid]}"
        if kill -0 "$pid" 2>/dev/null; then
            _log "sending SIGTERM to job $job_id (pid $pid)"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # Wait briefly for children to exit
    local deadline=$((SECONDS + 10))
    while [ ${#_active_jobs[@]} -gt 0 ] && [ $SECONDS -lt $deadline ]; do
        _active_count > /dev/null
        sleep 0.5 2>/dev/null || true
    done

    # Force-kill any stragglers
    for pid in "${!_active_jobs[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            _log "sending SIGKILL to pid $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done

    rm -f "$PID_FILE"
    _log_stdout "daemon stopped"
    exit 0
}

trap _shutdown SIGTERM SIGINT SIGHUP

# =============================================================================
# Subcommands
# =============================================================================

cmd_start() {
    mkdir -p "$DAEMON_DIR"

    # Check if already running
    if [ -f "$PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            echo "daemon already running (pid $existing_pid)"
            return 1
        fi
        rm -f "$PID_FILE"
    fi

    local foreground=0
    for arg in "$@"; do
        [ "$arg" = "--foreground" ] && foreground=1
    done

    if [ "$foreground" -eq 1 ]; then
        # Run in foreground (for systemd)
        echo $$ > "$PID_FILE"
        _main_loop
    else
        # Daemonize
        _main_loop &
        local daemon_pid=$!
        echo "$daemon_pid" > "$PID_FILE"
        echo "daemon started (pid $daemon_pid)"
        echo "log: $LOG_FILE"
        disown "$daemon_pid"
    fi
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "daemon not running (no PID file)"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -z "$pid" ]; then
        echo "daemon not running (empty PID file)"
        rm -f "$PID_FILE"
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "daemon not running (stale PID $pid)"
        rm -f "$PID_FILE"
        return 1
    fi

    echo "stopping daemon (pid $pid)..."
    kill -TERM "$pid"

    # Wait for clean exit
    local deadline=$((SECONDS + 15))
    while kill -0 "$pid" 2>/dev/null && [ $SECONDS -lt $deadline ]; do
        sleep 0.5
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "force-killing pid $pid"
        kill -KILL "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    echo "daemon stopped"
}

cmd_status() {
    if [ ! -f "$PID_FILE" ]; then
        echo "daemon: not running"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "daemon: not running (stale PID file)"
        rm -f "$PID_FILE"
        return 1
    fi

    echo "daemon: running (pid $pid)"
    echo "  poll interval: ${POLL_INTERVAL}s"
    echo "  max sessions:  $MAX_SESSIONS"
    echo "  dispatcher:    $DISPATCHER_URL"
    echo "  log:           $LOG_FILE"
    echo "  pid file:      $PID_FILE"

    if [ -f "$BOT_CONFIG" ]; then
        echo "  bot config:    $BOT_CONFIG"
    else
        echo "  bot config:    (none)"
    fi

    # Show recent log activity
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Recent activity:"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    fi
}

cmd_help() {
    cat <<'HELP'
Usage: securetty-daemon <start|stop|status> [options]

Commands:
  start [--foreground]    Start the daemon (--foreground for systemd)
  stop                    Stop the daemon gracefully
  status                  Check if daemon is running

Environment:
  SECURETTY_DAEMON_POLL          Poll interval in seconds (default: 10)
  SECURETTY_DAEMON_MAX_SESSIONS  Max concurrent agent sessions (default: 3)
  SECURETTY_DISPATCHER_URL       Dispatcher URL (default: https://securetty-dispatcher:8900)

Bot account:
  Place a bot.yaml in ~/.securetty/ to use a separate git identity:

    git:
      user.name: securetty-bot
      user.email: securetty-bot@example.com
HELP
}

# =============================================================================
# Main dispatch
# =============================================================================

case "${1:-help}" in
    start)   shift; cmd_start "$@" ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    help|--help|-h) cmd_help ;;
    *)       echo "Unknown command: $1. Run 'securetty-daemon help' for usage." >&2; exit 1 ;;
esac
