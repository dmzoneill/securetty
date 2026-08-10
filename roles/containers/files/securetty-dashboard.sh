#!/bin/bash
# securetty-dashboard — real-time TUI observability dashboard.
# Renders container health, job queue, agent metrics, cost summary,
# and recent alerts using ANSI escape codes.
#
# Usage:
#   securetty-dashboard.sh              # live refresh every 5s
#   securetty-dashboard.sh --once       # single render (for piping/logging)
#   securetty-dashboard.sh --json       # machine-readable JSON output
#
# Data sources:
#   - podman ps (container health)
#   - dispatcher /status API (job queue)
#   - ~/.securetty/outcomes/*.jsonl (agent metrics)
#   - ~/.securetty/cost/*.jsonl (cost summary)
#   - scanner containers (recent alerts)
#
# Environment:
#   SECURETTY_DISPATCHER_URL   Dispatcher base URL (default: https://securetty-dispatcher:8900)
#   SECURETTY_DASHBOARD_INTERVAL  Refresh interval in seconds (default: 5)
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

DISPATCHER_URL="${SECURETTY_DISPATCHER_URL:-https://securetty-dispatcher:8900}"
REFRESH_INTERVAL="${SECURETTY_DASHBOARD_INTERVAL:-5}"
OUTCOMES_DIR="$HOME/.securetty/outcomes"
COST_DIR="$HOME/.securetty/cost"
SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE="live"  # live | once | json

# ANSI escape codes
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'

# =============================================================================
# Argument parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) MODE="once"; shift ;;
        --json) MODE="json"; shift ;;
        --help|-h)
            echo "Usage: securetty-dashboard.sh [--once] [--json] [--help]"
            echo ""
            echo "Options:"
            echo "  --once   Render once and exit (for piping/logging)"
            echo "  --json   Output all dashboard data as JSON"
            echo "  --help   Show this help"
            echo ""
            echo "Environment:"
            echo "  SECURETTY_DISPATCHER_URL        Dispatcher URL (default: https://securetty-dispatcher:8900)"
            echo "  SECURETTY_DASHBOARD_INTERVAL    Refresh interval in seconds (default: 5)"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# =============================================================================
# TLS certificate arguments for dispatcher communication
# =============================================================================

_cert_args() {
    local args=""
    [ -f "$SECURETTY_DIR/certs/client.crt" ] && \
        args="--cert $SECURETTY_DIR/certs/client.crt --key $SECURETTY_DIR/certs/client.key --cacert $SECURETTY_DIR/certs/ca.crt"
    echo "$args"
}

# =============================================================================
# Data collection functions
# =============================================================================

collect_containers() {
    # Returns JSON array of container objects
    python3 -c "
import json
import subprocess
import sys

try:
    result = subprocess.run(
        ['podman', 'ps', '-a', '--format',
         '{{.Names}}\t{{.Status}}\t{{.Created}}\t{{.State}}'],
        capture_output=True, text=True, timeout=10
    )
    containers = []
    for line in result.stdout.strip().split('\n'):
        if not line or 'securetty' not in line:
            continue
        parts = line.split('\t')
        if len(parts) >= 4:
            name = parts[0]
            status = parts[1]
            created = parts[2]
            state = parts[3]
            healthy = 'healthy' in status.lower()
            running = state.lower() == 'running'
            containers.append({
                'name': name,
                'status': status,
                'created': created,
                'state': state,
                'healthy': healthy,
                'running': running,
            })
    print(json.dumps(containers))
except Exception as e:
    print(json.dumps([]))
" 2>/dev/null
}

collect_dispatcher_status() {
    # Returns JSON object from dispatcher /status endpoint
    local cert_args
    cert_args=$(_cert_args)
    # shellcheck disable=SC2086
    curl $cert_args -sf "${DISPATCHER_URL}/status" 2>/dev/null || echo '{}'
}

collect_agent_metrics() {
    # Returns JSON object with per-agent stats from today's outcomes
    python3 -c "
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

outcomes_dir = os.path.expanduser('$OUTCOMES_DIR')
today = datetime.now().strftime('%Y-%m-%d')
today_file = os.path.join(outcomes_dir, f'{today}.jsonl')

total = 0
failures = 0
agent_total = defaultdict(int)
agent_failures = defaultdict(int)
agent_durations = defaultdict(list)

# Read today's outcomes
if os.path.isfile(today_file):
    with open(today_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            agent = entry.get('agent', 'unknown')
            exit_code = entry.get('exit_code', 0)
            duration = entry.get('duration_seconds', 0)

            total += 1
            agent_total[agent] += 1
            agent_durations[agent].append(duration)

            if exit_code != 0:
                failures += 1
                agent_failures[agent] += 1

failure_rate = (failures / total * 100) if total > 0 else 0.0

agents = {}
for agent in sorted(agent_total.keys()):
    t = agent_total[agent]
    f = agent_failures.get(agent, 0)
    rate = (f / t * 100) if t > 0 else 0.0
    durations = agent_durations[agent]
    avg_dur = sum(durations) / len(durations) if durations else 0.0
    agents[agent] = {
        'sessions': t,
        'failures': f,
        'failure_rate': round(rate, 1),
        'avg_duration_seconds': round(avg_dur, 1),
    }

print(json.dumps({
    'sessions_today': total,
    'failures_today': failures,
    'failure_rate': round(failure_rate, 1),
    'agents': agents,
}))
" 2>/dev/null
}

collect_cost_summary() {
    # Returns JSON object with cost/session counts for today and this week
    python3 -c "
import json
import os
from datetime import datetime, timedelta
from collections import defaultdict

cost_dir = os.path.expanduser('$COST_DIR')
today = datetime.now().strftime('%Y-%m-%d')
today_file = os.path.join(cost_dir, f'{today}.jsonl')

# Today's sessions
today_count = 0
today_by_agent = defaultdict(int)
today_by_mode = defaultdict(int)
if os.path.isfile(today_file):
    with open(today_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            today_count += 1
            today_by_agent[entry.get('agent', 'unknown')] += 1
            today_by_mode[entry.get('mode', 'unknown')] += 1

# Week sessions
week_count = 0
week_daily = {}
for i in range(7):
    d = (datetime.now() - timedelta(days=i)).strftime('%Y-%m-%d')
    fpath = os.path.join(cost_dir, f'{d}.jsonl')
    day_count = 0
    if os.path.isfile(fpath):
        with open(fpath) as f:
            day_count = sum(1 for line in f if line.strip())
    week_daily[d] = day_count
    week_count += day_count

# Compute daily average for spike detection
daily_counts = [c for c in week_daily.values()]
daily_avg = sum(daily_counts) / len(daily_counts) if daily_counts else 0.0

print(json.dumps({
    'today': {
        'sessions': today_count,
        'by_agent': dict(today_by_agent),
        'by_mode': dict(today_by_mode),
    },
    'week': {
        'sessions': week_count,
        'daily': week_daily,
        'daily_avg': round(daily_avg, 1),
    },
}))
" 2>/dev/null
}

collect_alerts() {
    # Returns JSON array of recent alert conditions
    python3 -c "
import json
import subprocess
import os
from datetime import datetime, timedelta

alerts = []

# Check scanner alerts
for scanner, container in [('guarddog', 'securetty-guarddog'), ('osv-scanner', 'securetty-osv-scanner')]:
    try:
        result = subprocess.run(
            ['podman', 'exec', container, 'tail', '-5', '/results/alerts.log'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    alerts.append({
                        'source': scanner,
                        'severity': 'warning',
                        'message': line.strip()[:120],
                        'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                    })
    except Exception:
        pass

# Check for unhealthy containers
try:
    result = subprocess.run(
        ['podman', 'ps', '-a', '--format', '{{.Names}}\t{{.Status}}\t{{.State}}'],
        capture_output=True, text=True, timeout=10
    )
    for line in result.stdout.strip().split('\n'):
        if not line or 'securetty' not in line:
            continue
        parts = line.split('\t')
        if len(parts) >= 3:
            name = parts[0]
            state = parts[2]
            if state.lower() in ('exited', 'dead', 'created'):
                alerts.append({
                    'source': 'container',
                    'severity': 'critical',
                    'message': f'{name} is {state}',
                    'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
                })
except Exception:
    pass

# Check for high failure rate in last hour from outcomes
outcomes_dir = os.path.expanduser('$OUTCOMES_DIR')
today = datetime.now().strftime('%Y-%m-%d')
today_file = os.path.join(outcomes_dir, f'{today}.jsonl')
if os.path.isfile(today_file):
    hour_ago = (datetime.utcnow() - timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
    recent_total = 0
    recent_failures = 0
    with open(today_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                ts = entry.get('timestamp', '')
                if ts >= hour_ago:
                    recent_total += 1
                    if entry.get('exit_code', 0) != 0:
                        recent_failures += 1
            except json.JSONDecodeError:
                continue

    if recent_total >= 5:
        rate = recent_failures / recent_total * 100
        if rate > 20:
            alerts.append({
                'source': 'error-rate',
                'severity': 'critical',
                'message': f'Error rate {rate:.0f}% in last hour ({recent_failures}/{recent_total} sessions)',
                'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
            })

print(json.dumps(alerts))
" 2>/dev/null
}

# =============================================================================
# JSON output mode
# =============================================================================

render_json() {
    local containers dispatcher agents cost alerts_data
    containers=$(collect_containers)
    dispatcher=$(collect_dispatcher_status)
    agents=$(collect_agent_metrics)
    cost=$(collect_cost_summary)
    alerts_data=$(collect_alerts)

    python3 -c "
import json
import sys
from datetime import datetime

data = {
    'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'containers': json.loads('''$containers'''),
    'dispatcher': json.loads('''$dispatcher''') if '''$dispatcher'''.strip() else {},
    'agents': json.loads('''$agents'''),
    'cost': json.loads('''$cost'''),
    'alerts': json.loads('''$alerts_data'''),
}
print(json.dumps(data, indent=2))
"
}

# =============================================================================
# TUI rendering
# =============================================================================

_hr() {
    local width=${1:-78}
    printf '%*s\n' "$width" '' | tr ' ' '-'
}

_header() {
    local ts
    ts=$(date -u +%FT%TZ)
    local _splash_script
    _splash_script="$(dirname "$0")/../../scripts/securetty-splash.sh"
    [ -f "$_splash_script" ] || _splash_script="$(cd "$(dirname "$0")" && pwd)/../../scripts/securetty-splash.sh"
    if [ -f "$_splash_script" ]; then
        source "$_splash_script"
        show_splash "--tagline|Observability Dashboard  ${ts}"
    else
        echo -e "${BOLD}${CYAN}"
        echo -e "  securetty — Observability Dashboard"
        echo -e "${RESET}"
    fi
}

render_containers() {
    local containers="$1"

    echo -e "  ${WHITE}${BOLD}Container Health${RESET}"
    _hr 78 | sed 's/^/  /'

    python3 -c "
import json

containers = json.loads('''$containers''')
if not containers:
    print('  (no securetty containers found)')
else:
    print('  %-28s %-10s %s' % ('NAME', 'STATE', 'STATUS'))
    for c in sorted(containers, key=lambda x: x['name']):
        state = c['state']
        status = c['status']
        name = c['name']
        if state.lower() == 'running':
            if c.get('healthy'):
                icon = '\033[0;32m●\033[0m'
            else:
                icon = '\033[0;33m●\033[0m'
        else:
            icon = '\033[0;31m●\033[0m'
        print(f'  {icon} {name:<27} {state:<10} {status}')
" 2>/dev/null
    echo ""
}

render_queue() {
    local dispatcher="$1"

    echo -e "  ${WHITE}${BOLD}Job Queue${RESET}"
    _hr 78 | sed 's/^/  /'

    python3 -c "
import json

data = json.loads('''$dispatcher''') if '''$dispatcher'''.strip() else {}
if not data:
    print('  (dispatcher unreachable)')
else:
    jobs = data.get('jobs', {})
    pending = jobs.get('pending', 0)
    running = jobs.get('running', 0)
    completed = jobs.get('completed', 0)
    failed = jobs.get('failed', 0)
    completed_today = data.get('completed_today', 0)
    max_conc = data.get('max_concurrent_jobs', '?')
    skills = data.get('skills', 0)

    # Color pending count if queue is backing up
    pending_color = '\033[0;31m' if pending > 10 else '\033[0;32m'
    running_color = '\033[0;36m' if running > 0 else '\033[0m'

    print(f'  Pending:    {pending_color}{pending}\033[0m')
    print(f'  Running:    {running_color}{running}\033[0m / {max_conc} max')
    print(f'  Completed:  {completed} (today: {completed_today})')
    print(f'  Failed:     {failed}')
    print(f'  Skills:     {skills} loaded')
" 2>/dev/null
    echo ""
}

render_agents() {
    local agents="$1"

    echo -e "  ${WHITE}${BOLD}Agent Metrics (today)${RESET}"
    _hr 78 | sed 's/^/  /'

    python3 -c "
import json

data = json.loads('''$agents''')
total = data.get('sessions_today', 0)
failures = data.get('failures_today', 0)
rate = data.get('failure_rate', 0.0)
agents = data.get('agents', {})

if total == 0:
    print('  No sessions today.')
else:
    rate_color = '\033[0;31m' if rate > 20 else '\033[0;33m' if rate > 10 else '\033[0;32m'
    print(f'  Total sessions: {total}    Failures: {failures}    Failure rate: {rate_color}{rate:.1f}%\033[0m')
    print()
    if agents:
        print('  %-18s %8s %8s %8s %10s' % ('AGENT', 'SESSIONS', 'FAIL', 'RATE', 'AVG(s)'))
        for agent, stats in sorted(agents.items()):
            rate = stats['failure_rate']
            marker = ' \033[0;31m!!!\033[0m' if rate > 30 else ''
            rate_str = f'{rate:.1f}%'
            print(f'  {agent:<18} {stats[\"sessions\"]:>8} {stats[\"failures\"]:>8} {rate_str:>8} {stats[\"avg_duration_seconds\"]:>10.1f}{marker}')
" 2>/dev/null
    echo ""
}

render_cost() {
    local cost="$1"

    echo -e "  ${WHITE}${BOLD}Cost Summary${RESET}"
    _hr 78 | sed 's/^/  /'

    python3 -c "
import json

data = json.loads('''$cost''')
today = data.get('today', {})
week = data.get('week', {})

today_sessions = today.get('sessions', 0)
week_sessions = week.get('sessions', 0)
daily_avg = week.get('daily_avg', 0)

print(f'  Today:      {today_sessions} sessions')
print(f'  This week:  {week_sessions} sessions (avg {daily_avg:.1f}/day)')

by_agent = today.get('by_agent', {})
if by_agent:
    print()
    print('  By agent today:')
    for agent, count in sorted(by_agent.items(), key=lambda x: x[1], reverse=True):
        print(f'    {agent:<18} {count}')

by_mode = today.get('by_mode', {})
if by_mode:
    print('  By mode today:')
    for mode, count in sorted(by_mode.items(), key=lambda x: x[1], reverse=True):
        print(f'    {mode:<18} {count}')

# Spike detection
if daily_avg > 0 and today_sessions > daily_avg * 2:
    print(f'  \033[0;31mCOST SPIKE: today ({today_sessions}) is >2x daily average ({daily_avg:.1f})\033[0m')
" 2>/dev/null
    echo ""
}

render_alerts() {
    local alerts_data="$1"

    echo -e "  ${WHITE}${BOLD}Recent Alerts${RESET}"
    _hr 78 | sed 's/^/  /'

    python3 -c "
import json

alerts = json.loads('''$alerts_data''')
if not alerts:
    print('  \033[0;32mNo active alerts.\033[0m')
else:
    for alert in alerts[:10]:
        severity = alert.get('severity', 'info')
        source = alert.get('source', '?')
        message = alert.get('message', '')
        ts = alert.get('timestamp', '')

        if severity == 'critical':
            color = '\033[0;31m'
            icon = '\033[41m CRIT \033[0m'
        elif severity == 'warning':
            color = '\033[0;33m'
            icon = '\033[43m WARN \033[0m'
        else:
            color = '\033[0;36m'
            icon = '\033[44m INFO \033[0m'

        print(f'  {icon} {color}[{source}]{color} {message}\033[0m')
" 2>/dev/null
    echo ""
}

render_tui() {
    local containers dispatcher agents cost alerts_data

    containers=$(collect_containers)
    dispatcher=$(collect_dispatcher_status)
    agents=$(collect_agent_metrics)
    cost=$(collect_cost_summary)
    alerts_data=$(collect_alerts)

    # Clear screen for live mode
    if [ "$MODE" = "live" ]; then
        printf '\033[2J\033[H'
    fi

    _header
    render_containers "$containers"
    render_queue "$dispatcher"
    render_agents "$agents"
    render_cost "$cost"
    render_alerts "$alerts_data"

    if [ "$MODE" = "live" ]; then
        echo -e "  ${DIM}Refreshing every ${REFRESH_INTERVAL}s | Press Ctrl+C to exit${RESET}"
    fi
}

# =============================================================================
# Main
# =============================================================================

case "$MODE" in
    json)
        render_json
        ;;
    once)
        render_tui
        ;;
    live)
        trap 'printf "\033[?25h"; exit 0' INT TERM
        printf '\033[?25l'  # hide cursor
        while true; do
            render_tui
            sleep "$REFRESH_INTERVAL" &
            wait $! 2>/dev/null || true
        done
        ;;
esac
