#!/bin/bash
# securetty-alerts — SLI alerting for the securetty platform.
# Checks service-level indicator conditions and fires notifications
# when thresholds are breached.
#
# Usage:
#   securetty-alerts.sh --check    Run all checks, exit 1 if any alert fires
#   securetty-alerts.sh --notify   Run checks and send desktop notifications
#   securetty-alerts.sh --json     Output alert state as JSON
#   securetty-alerts.sh --help     Show help
#
# Designed to run from cron or systemd timer (every 5 minutes).
#
# Alert conditions:
#   - Agent stuck:        running >30min without output
#   - Cost spike:         >2x daily average in sessions today
#   - Error rate:         >20% failure rate in the last hour
#   - Container unhealthy: any securetty service not in running state
#   - Queue backup:       >10 pending jobs in the dispatcher queue
#
# Environment (threshold overrides):
#   SECURETTY_ALERT_STUCK_MINUTES     Minutes before agent is "stuck" (default: 30)
#   SECURETTY_ALERT_COST_MULTIPLIER   Cost spike multiplier (default: 2)
#   SECURETTY_ALERT_ERROR_RATE_PCT    Error rate threshold percent (default: 20)
#   SECURETTY_ALERT_QUEUE_LIMIT       Queue backup threshold (default: 10)
#   SECURETTY_ALERT_MIN_SAMPLES       Minimum sessions for error rate check (default: 5)
#   SECURETTY_DISPATCHER_URL          Dispatcher base URL (default: https://securetty-dispatcher:8900)
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

DISPATCHER_URL="${SECURETTY_DISPATCHER_URL:-https://securetty-dispatcher:8900}"
OUTCOMES_DIR="$HOME/.securetty/outcomes"
COST_DIR="$HOME/.securetty/cost"
SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"

# Thresholds (overridable via environment)
STUCK_MINUTES="${SECURETTY_ALERT_STUCK_MINUTES:-30}"
COST_MULTIPLIER="${SECURETTY_ALERT_COST_MULTIPLIER:-2}"
ERROR_RATE_PCT="${SECURETTY_ALERT_ERROR_RATE_PCT:-20}"
QUEUE_LIMIT="${SECURETTY_ALERT_QUEUE_LIMIT:-10}"
MIN_SAMPLES="${SECURETTY_ALERT_MIN_SAMPLES:-5}"

MODE=""
ALERT_COUNT=0

# =============================================================================
# Argument parsing
# =============================================================================

usage() {
    cat <<'HELP'
Usage: securetty-alerts.sh <--check|--notify|--json> [--help]

Modes:
  --check    Run all SLI checks, exit 1 if any alert fires
  --notify   Run checks and send desktop notifications via notify-send
  --json     Output all alert state as JSON

Environment (threshold overrides):
  SECURETTY_ALERT_STUCK_MINUTES     Minutes before agent is "stuck" (default: 30)
  SECURETTY_ALERT_COST_MULTIPLIER   Cost spike multiplier (default: 2)
  SECURETTY_ALERT_ERROR_RATE_PCT    Error rate threshold percent (default: 20)
  SECURETTY_ALERT_QUEUE_LIMIT       Queue backup threshold (default: 10)
  SECURETTY_ALERT_MIN_SAMPLES       Minimum sessions for error rate check (default: 5)
  SECURETTY_DISPATCHER_URL          Dispatcher base URL

Cron example (check every 5 minutes, notify on alert):
  */5 * * * * /path/to/securetty-alerts.sh --notify 2>/dev/null
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)  MODE="check"; shift ;;
        --notify) MODE="notify"; shift ;;
        --json)   MODE="json"; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "Error: specify --check, --notify, or --json" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

# =============================================================================
# TLS certificate arguments
# =============================================================================

_cert_args() {
    local args=""
    [ -f "$SECURETTY_DIR/certs/client.crt" ] && \
        args="--cert $SECURETTY_DIR/certs/client.crt --key $SECURETTY_DIR/certs/client.key --cacert $SECURETTY_DIR/certs/ca.crt"
    echo "$args"
}

# =============================================================================
# Alert state accumulator
# =============================================================================

# Alerts are accumulated as JSON lines in a temp file
ALERT_FILE=$(mktemp /tmp/securetty-alerts.XXXXXX)
trap 'rm -f "$ALERT_FILE"' EXIT

_add_alert() {
    local check="$1"
    local severity="$2"
    local message="$3"
    local ts
    ts=$(date -u +%FT%TZ)
    printf '{"check":"%s","severity":"%s","message":"%s","timestamp":"%s","fired":true}\n' \
        "$check" "$severity" "$message" "$ts" >> "$ALERT_FILE"
    ALERT_COUNT=$((ALERT_COUNT + 1))
}

_add_ok() {
    local check="$1"
    local message="$2"
    local ts
    ts=$(date -u +%FT%TZ)
    printf '{"check":"%s","severity":"ok","message":"%s","timestamp":"%s","fired":false}\n' \
        "$check" "$message" "$ts" >> "$ALERT_FILE"
}

# =============================================================================
# Check: Container Unhealthy
# =============================================================================

check_containers() {
    local unhealthy_containers=""
    local count=0

    while IFS=$'\t' read -r name state status; do
        [ -z "$name" ] && continue
        echo "$name" | grep -q securetty || continue
        if [ "$state" != "running" ]; then
            unhealthy_containers="${unhealthy_containers}${name} (${state}), "
            count=$((count + 1))
        fi
    done < <(podman ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true)

    if [ "$count" -gt 0 ]; then
        unhealthy_containers="${unhealthy_containers%, }"
        _add_alert "container_unhealthy" "critical" "${count} unhealthy: ${unhealthy_containers}"
    else
        _add_ok "container_unhealthy" "All containers healthy"
    fi
}

# =============================================================================
# Check: Agent Stuck
# =============================================================================

check_stuck_agents() {
    local stuck_count=0
    local stuck_names=""
    local threshold_seconds=$((STUCK_MINUTES * 60))
    local now_epoch
    now_epoch=$(date +%s)

    # Check dispatcher for running jobs that started more than STUCK_MINUTES ago
    local cert_args
    cert_args=$(_cert_args)
    local response
    # shellcheck disable=SC2086
    response=$(curl $cert_args -sf "${DISPATCHER_URL}/jobs?status=running&limit=50" 2>/dev/null || echo "")

    if [ -n "$response" ] && [ "$response" != "" ]; then
        stuck_count=$(python3 -c "
import json
import sys
from datetime import datetime, timezone

threshold = $threshold_seconds
now_epoch = $now_epoch
jobs = json.loads('''$response''')
stuck = []
for job in jobs:
    started = job.get('started_at', '')
    if not started:
        continue
    try:
        # Parse ISO timestamp
        if started.endswith('Z'):
            started = started[:-1] + '+00:00'
        dt = datetime.fromisoformat(started)
        started_epoch = int(dt.timestamp())
        elapsed = now_epoch - started_epoch
        if elapsed > threshold:
            stuck.append(job.get('id', '?'))
    except (ValueError, TypeError):
        continue

print(len(stuck))
for s in stuck:
    print(s)
" 2>/dev/null || echo "0")

        # First line is count, remaining lines are job IDs
        local first_line
        first_line=$(echo "$stuck_count" | head -1)
        if [ "$first_line" -gt 0 ] 2>/dev/null; then
            local stuck_ids
            stuck_ids=$(echo "$stuck_count" | tail -n +2 | paste -sd, || true)
            _add_alert "agent_stuck" "warning" "${first_line} agent(s) running >${STUCK_MINUTES}min: ${stuck_ids}"
        else
            _add_ok "agent_stuck" "No stuck agents"
        fi
    else
        _add_ok "agent_stuck" "Dispatcher unreachable (skipped)"
    fi
}

# =============================================================================
# Check: Cost Spike
# =============================================================================

check_cost_spike() {
    if [ ! -d "$COST_DIR" ]; then
        _add_ok "cost_spike" "No cost data available"
        return
    fi

    python3 -c "
import json
import os
import sys
from datetime import datetime, timedelta

cost_dir = os.path.expanduser('$COST_DIR')
multiplier = float($COST_MULTIPLIER)
today = datetime.now().strftime('%Y-%m-%d')
today_file = os.path.join(cost_dir, f'{today}.jsonl')

# Count today's sessions
today_count = 0
if os.path.isfile(today_file):
    with open(today_file) as f:
        today_count = sum(1 for line in f if line.strip())

# Compute average over last 7 days (excluding today)
daily_counts = []
for i in range(1, 8):
    d = (datetime.now() - timedelta(days=i)).strftime('%Y-%m-%d')
    fpath = os.path.join(cost_dir, f'{d}.jsonl')
    count = 0
    if os.path.isfile(fpath):
        with open(fpath) as f:
            count = sum(1 for line in f if line.strip())
    daily_counts.append(count)

daily_avg = sum(daily_counts) / len(daily_counts) if daily_counts else 0

if daily_avg > 0 and today_count > daily_avg * multiplier:
    print(f'ALERT|cost_spike|warning|Cost spike: {today_count} sessions today vs {daily_avg:.1f} daily avg (>{multiplier}x)')
else:
    print(f'OK|cost_spike|Today: {today_count} sessions, avg: {daily_avg:.1f}/day')
" 2>/dev/null | while IFS='|' read -r status check severity message; do
        if [ "$status" = "ALERT" ]; then
            _add_alert "$check" "$severity" "$message"
        else
            _add_ok "$check" "$message"
        fi
    done
}

# =============================================================================
# Check: Error Rate
# =============================================================================

check_error_rate() {
    if [ ! -d "$OUTCOMES_DIR" ]; then
        _add_ok "error_rate" "No outcomes data available"
        return
    fi

    local today
    today=$(date +%Y-%m-%d)
    local today_file="$OUTCOMES_DIR/${today}.jsonl"

    if [ ! -f "$today_file" ]; then
        _add_ok "error_rate" "No sessions today"
        return
    fi

    python3 -c "
import json
import sys
from datetime import datetime, timedelta, timezone

threshold_pct = float($ERROR_RATE_PCT)
min_samples = int($MIN_SAMPLES)
today_file = '$today_file'
hour_ago = (datetime.utcnow() - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')

total = 0
failures = 0
with open(today_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            ts = entry.get('timestamp', '')
            if ts >= hour_ago:
                total += 1
                if entry.get('exit_code', 0) != 0:
                    failures += 1
        except json.JSONDecodeError:
            continue

if total < min_samples:
    print(f'OK|error_rate|Insufficient data ({total}/{min_samples} min samples)')
else:
    rate = failures / total * 100
    if rate > threshold_pct:
        print(f'ALERT|error_rate|critical|Error rate {rate:.0f}% in last hour ({failures}/{total} sessions, threshold {threshold_pct}%)')
    else:
        print(f'OK|error_rate|Error rate {rate:.1f}% in last hour ({failures}/{total} sessions)')
" 2>/dev/null | while IFS='|' read -r status check severity message; do
        if [ "$status" = "ALERT" ]; then
            _add_alert "$check" "$severity" "$message"
        else
            _add_ok "$check" "$message"
        fi
    done
}

# =============================================================================
# Check: Queue Backup
# =============================================================================

check_queue_backup() {
    local cert_args
    cert_args=$(_cert_args)
    local response
    # shellcheck disable=SC2086
    response=$(curl $cert_args -sf "${DISPATCHER_URL}/status" 2>/dev/null || echo "")

    if [ -z "$response" ]; then
        _add_ok "queue_backup" "Dispatcher unreachable (skipped)"
        return
    fi

    local pending
    pending=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('queue_depth', data.get('jobs', {}).get('pending', 0)))
except:
    print(0)
" 2>/dev/null || echo "0")

    if [ "$pending" -gt "$QUEUE_LIMIT" ] 2>/dev/null; then
        _add_alert "queue_backup" "warning" "Queue backup: ${pending} pending jobs (threshold: ${QUEUE_LIMIT})"
    else
        _add_ok "queue_backup" "Queue depth: ${pending} (limit: ${QUEUE_LIMIT})"
    fi
}

# =============================================================================
# Run all checks
# =============================================================================

run_all_checks() {
    check_containers
    check_stuck_agents
    check_cost_spike
    check_error_rate
    check_queue_backup
}

# =============================================================================
# Output: --check mode (human-readable)
# =============================================================================

output_check() {
    local ts
    ts=$(date -u +%FT%TZ)

    echo ""
    echo "securetty SLI alert check  ${ts}"
    echo "=================================================="

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local check severity message fired
        check=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('check',''))" 2>/dev/null || true)
        severity=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('severity',''))" 2>/dev/null || true)
        message=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('message',''))" 2>/dev/null || true)
        fired=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('true' if d.get('fired') else 'false')" 2>/dev/null || true)

        local icon color
        if [ "$fired" = "true" ]; then
            if [ "$severity" = "critical" ]; then
                icon="[CRIT]"
                color='\033[0;31m'
            else
                icon="[WARN]"
                color='\033[0;33m'
            fi
        else
            icon="[ OK ]"
            color='\033[0;32m'
        fi

        printf "  ${color}%-8s %-22s %s${RESET}\n" "$icon" "$check" "$message"
    done < "$ALERT_FILE"

    echo ""

    if [ "$ALERT_COUNT" -gt 0 ]; then
        echo -e "  \033[0;31m${ALERT_COUNT} alert(s) firing\033[0m"
    else
        echo -e "  \033[0;32mAll checks passed\033[0m"
    fi
    echo ""
}

# =============================================================================
# Output: --notify mode (desktop notifications)
# =============================================================================

output_notify() {
    # Also print the check output
    output_check

    # Send desktop notification for each fired alert
    if ! command -v notify-send &>/dev/null; then
        echo "  (notify-send not available — skipping desktop notifications)"
        return
    fi

    local fired_count=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local fired severity check message
        fired=$(echo "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('true' if d.get('fired') else 'false')" 2>/dev/null || true)
        [ "$fired" != "true" ] && continue

        severity=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('severity',''))" 2>/dev/null || true)
        check=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('check',''))" 2>/dev/null || true)
        message=$(echo "$line" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('message',''))" 2>/dev/null || true)

        local urgency="normal"
        [ "$severity" = "critical" ] && urgency="critical"

        notify-send -u "$urgency" -a "securetty" \
            "securetty alert: ${check}" \
            "$message" 2>/dev/null || true

        fired_count=$((fired_count + 1))
    done < "$ALERT_FILE"

    if [ "$fired_count" -gt 0 ]; then
        echo "  Sent ${fired_count} desktop notification(s)"
    fi
}

# =============================================================================
# Output: --json mode
# =============================================================================

output_json() {
    python3 -c "
import json
import sys
from datetime import datetime

alerts = []
with open('$ALERT_FILE') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            alerts.append(json.loads(line))
        except json.JSONDecodeError:
            continue

fired = [a for a in alerts if a.get('fired')]
result = {
    'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'alerts_firing': len(fired),
    'total_checks': len(alerts),
    'thresholds': {
        'stuck_minutes': $STUCK_MINUTES,
        'cost_multiplier': $COST_MULTIPLIER,
        'error_rate_pct': $ERROR_RATE_PCT,
        'queue_limit': $QUEUE_LIMIT,
        'min_samples': $MIN_SAMPLES,
    },
    'checks': alerts,
}
print(json.dumps(result, indent=2))
" 2>/dev/null
}

# =============================================================================
# Main
# =============================================================================

run_all_checks

# Re-count alerts from the file (subshell writes may not propagate)
ALERT_COUNT=$(grep -c '"fired":true' "$ALERT_FILE" 2>/dev/null || echo 0)

case "$MODE" in
    check)
        output_check
        [ "$ALERT_COUNT" -gt 0 ] && exit 1
        exit 0
        ;;
    notify)
        output_notify
        [ "$ALERT_COUNT" -gt 0 ] && exit 1
        exit 0
        ;;
    json)
        output_json
        [ "$ALERT_COUNT" -gt 0 ] && exit 1
        exit 0
        ;;
esac
