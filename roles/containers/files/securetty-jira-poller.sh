#!/bin/bash
# securetty-jira-poller — polling daemon that discovers untriaged Jira issues
# and feeds them into securetty-jira-triage.sh.  Runs as a background process
# with start/stop/status subcommands (same pattern as securetty-daemon.sh).
set -euo pipefail

SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_DIR="$HOME/.securetty"
PID_FILE="$DAEMON_DIR/jira-poller.pid"
LOG_FILE="$DAEMON_DIR/jira-triage.log"

POLL_INTERVAL="${SECURETTY_JIRA_POLL_INTERVAL:-300}"
JIRA_URL="${SECURETTY_JIRA_URL:-}"
JIRA_USER="${SECURETTY_JIRA_USER:-}"
JIRA_TOKEN="${JIRA_API_TOKEN:-}"
JIRA_PROJECTS="${SECURETTY_JIRA_PROJECTS:-AAP}"

# Try creds proxy if no token is set directly
if [ -z "$JIRA_TOKEN" ]; then
    JIRA_TOKEN=$(curl -sf http://localhost:9401/creds/jira_api_token 2>/dev/null || true)
fi

_shutting_down=0

# =============================================================================
# Logging
# =============================================================================

_log() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts [poller] $*" >> "$LOG_FILE"
}

_log_stdout() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts [poller] $*" | tee -a "$LOG_FILE"
}

# =============================================================================
# Jira query
# =============================================================================

_jira_auth_header() {
    if [ -n "$JIRA_USER" ] && [ -n "$JIRA_TOKEN" ]; then
        echo "-u ${JIRA_USER}:${JIRA_TOKEN}"
    elif [ -n "$JIRA_TOKEN" ]; then
        echo "-H Authorization: Bearer ${JIRA_TOKEN}"
    else
        echo ""
    fi
}

_build_project_clause() {
    # Convert comma-separated project list into JQL IN clause
    local projects="$1"
    local clause=""
    IFS=',' read -ra proj_arr <<< "$projects"
    for i in "${!proj_arr[@]}"; do
        local p
        p=$(echo "${proj_arr[$i]}" | xargs)  # trim whitespace
        if [ "$i" -eq 0 ]; then
            clause="$p"
        else
            clause="$clause, $p"
        fi
    done
    echo "$clause"
}

_poll_jira() {
    local project_clause
    project_clause=$(_build_project_clause "$JIRA_PROJECTS")

    # Labels that indicate the issue has already been processed
    local exclude_labels="agent:triaged, agent:in-progress, agent:completed, agent:skipped, agent:blocked, agent:needs-info"

    local jql="project IN (${project_clause}) AND assignee = currentUser() AND labels NOT IN (${exclude_labels}) AND status NOT IN (Done, Closed, Resolved) ORDER BY priority DESC, updated DESC"

    local encoded_jql
    encoded_jql=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$jql''', safe=''))" 2>/dev/null)

    local auth
    auth=$(_jira_auth_header)

    local response
    # shellcheck disable=SC2086
    response=$(curl $auth -sf -H "Content-Type: application/json" \
        "${JIRA_URL}/rest/api/2/search?jql=${encoded_jql}&maxResults=20&fields=key" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        _log "WARNING: Jira query returned empty response"
        return
    fi

    # Extract issue keys
    local keys
    keys=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    issues = data.get('issues', [])
    for issue in issues:
        print(issue['key'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
" 2>/dev/null)

    if [ -z "$keys" ]; then
        _log "no untriaged issues found"
        return
    fi

    local count=0
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        _log_stdout "triaging: ${key}"
        "${SECURETTY_DIR}/securetty-jira-triage.sh" "$key" || \
            _log "WARNING: triage failed for ${key}"
        count=$((count + 1))
    done <<< "$keys"

    _log "poll complete: triaged ${count} issue(s)"
}

# =============================================================================
# Main loop
# =============================================================================

_main_loop() {
    _log_stdout "poller started (pid $$, interval=${POLL_INTERVAL}s, projects=${JIRA_PROJECTS})"

    if [ -z "$JIRA_URL" ]; then
        _log_stdout "ERROR: SECURETTY_JIRA_URL is not set"
        exit 1
    fi

    while [ "$_shutting_down" -eq 0 ]; do
        _poll_jira
        # Interruptible sleep
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
    rm -f "$PID_FILE"
    _log_stdout "poller stopped"
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
            echo "jira-poller already running (pid $existing_pid)"
            return 1
        fi
        rm -f "$PID_FILE"
    fi

    local foreground=0
    for arg in "$@"; do
        [ "$arg" = "--foreground" ] && foreground=1
    done

    if [ "$foreground" -eq 1 ]; then
        echo $$ > "$PID_FILE"
        _main_loop
    else
        _main_loop &
        local poller_pid=$!
        echo "$poller_pid" > "$PID_FILE"
        echo "jira-poller started (pid $poller_pid)"
        echo "  poll interval: ${POLL_INTERVAL}s"
        echo "  projects:      ${JIRA_PROJECTS}"
        echo "  log:           ${LOG_FILE}"
        disown "$poller_pid"
    fi
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "jira-poller not running (no PID file)"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -z "$pid" ]; then
        echo "jira-poller not running (empty PID file)"
        rm -f "$PID_FILE"
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "jira-poller not running (stale PID $pid)"
        rm -f "$PID_FILE"
        return 1
    fi

    echo "stopping jira-poller (pid $pid)..."
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
    echo "jira-poller stopped"
}

cmd_status() {
    if [ ! -f "$PID_FILE" ]; then
        echo "jira-poller: not running"
        return 1
    fi

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        echo "jira-poller: not running (stale PID file)"
        rm -f "$PID_FILE"
        return 1
    fi

    echo "jira-poller: running (pid $pid)"
    echo "  poll interval: ${POLL_INTERVAL}s"
    echo "  projects:      ${JIRA_PROJECTS}"
    echo "  jira url:      ${JIRA_URL:-<not set>}"
    echo "  log:           ${LOG_FILE}"
    echo "  pid file:      ${PID_FILE}"

    # Show recent log activity
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "Recent activity:"
        tail -5 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
    fi
}

cmd_help() {
    cat <<'HELP'
Usage: securetty-jira-poller <start|stop|status> [options]

Commands:
  start [--foreground]    Start the poller (--foreground for systemd)
  stop                    Stop the poller gracefully
  status                  Check if poller is running

Environment:
  SECURETTY_JIRA_URL            Jira base URL (required)
  SECURETTY_JIRA_USER           Jira username for basic auth
  JIRA_API_TOKEN                Jira API token (or via creds proxy)
  SECURETTY_JIRA_POLL_INTERVAL  Poll interval in seconds (default: 300)
  SECURETTY_JIRA_PROJECTS       Comma-separated project keys (default: AAP)

The poller queries Jira for issues assigned to the current user that have
not yet been triaged (no agent:* labels) and feeds each one into
securetty-jira-triage.sh for classification and routing.

Labels used for state tracking:
  agent:triaged       Issue has been seen by the triage agent
  agent:needs-info    Clarification requested via Jira comment
  agent:in-progress   Dispatched for implementation
  agent:completed     Work finished
  agent:skipped       Not actionable (Epic, Done, non-technical, etc.)
  agent:blocked       Blocked on external dependency

Log: ~/.securetty/jira-triage.log
PID: ~/.securetty/jira-poller.pid
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
    *)       echo "Unknown command: $1. Run 'securetty-jira-poller help' for usage." >&2; exit 1 ;;
esac
