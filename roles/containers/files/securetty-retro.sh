#!/bin/bash
# Retrospective analysis of securetty agent session outcomes.
# Reads JSONL outcome logs and produces failure pattern reports.
# Usage: securetty-retro.sh [--json] [--since <duration>]
#   --json    Machine-readable JSON output
#   --since   Limit to entries within duration (e.g. 7d, 24h, 30d)
set -euo pipefail

OUTCOMES_DIR="$HOME/.securetty/outcomes"
JSON_OUTPUT=0
SINCE_SECONDS=0

usage() {
    echo "Usage: securetty-retro.sh [--json] [--since <duration>]"
    echo ""
    echo "Options:"
    echo "  --json         Output report as JSON"
    echo "  --since <dur>  Limit to entries within duration (e.g. 7d, 24h, 30d)"
    echo "  --help         Show this help"
    exit 0
}

parse_duration() {
    local dur="$1"
    local num="${dur%[dhm]}"
    local unit="${dur##*[0-9]}"
    case "$unit" in
        d) echo $((num * 86400)) ;;
        h) echo $((num * 3600)) ;;
        m) echo $((num * 60)) ;;
        *) echo 0 ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUTPUT=1; shift ;;
        --since) SINCE_SECONDS=$(parse_duration "$2"); shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -d "$OUTCOMES_DIR" ]]; then
    echo "No outcomes directory found at $OUTCOMES_DIR" >&2
    exit 1
fi

shopt -s nullglob
jsonl_files=("$OUTCOMES_DIR"/*.jsonl)
shopt -u nullglob

if [[ ${#jsonl_files[@]} -eq 0 ]]; then
    echo "No outcome files found in $OUTCOMES_DIR" >&2
    exit 1
fi

# Compute cutoff timestamp if --since was provided
CUTOFF=""
if [[ $SINCE_SECONDS -gt 0 ]]; then
    CUTOFF=$(date -u -d "-${SINCE_SECONDS} seconds" +%FT%TZ 2>/dev/null || \
             date -u -v-"${SINCE_SECONDS}"S +%FT%TZ 2>/dev/null || echo "")
fi

# Process all JSONL files with a single awk pass
cat "${jsonl_files[@]}" | python3 -c "
import json
import sys
from collections import defaultdict

cutoff = '$CUTOFF'
json_output = $JSON_OUTPUT

total = 0
failures = 0
agent_total = defaultdict(int)
agent_failures = defaultdict(int)
agent_durations = defaultdict(list)
workdir_total = defaultdict(int)
workdir_failures = defaultdict(int)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue

    ts = entry.get('timestamp', '')
    if cutoff and ts < cutoff:
        continue

    agent = entry.get('agent', 'unknown')
    exit_code = entry.get('exit_code', 0)
    duration = entry.get('duration_seconds', 0)
    workdir = entry.get('workdir', 'unknown')

    total += 1
    agent_total[agent] += 1
    agent_durations[agent].append(duration)
    workdir_total[workdir] += 1

    if exit_code != 0:
        failures += 1
        agent_failures[agent] += 1
        workdir_failures[workdir] += 1

failure_rate = (failures / total * 100) if total > 0 else 0

# Build per-agent stats
agent_stats = {}
for agent in sorted(agent_total.keys()):
    t = agent_total[agent]
    f = agent_failures.get(agent, 0)
    rate = (f / t * 100) if t > 0 else 0
    durations = agent_durations[agent]
    avg_dur = sum(durations) / len(durations) if durations else 0
    agent_stats[agent] = {
        'total': t,
        'failures': f,
        'failure_rate': round(rate, 1),
        'avg_duration_seconds': round(avg_dur, 1),
    }

# Build per-workdir (skill proxy) stats
workdir_stats = {}
for wd in sorted(workdir_total.keys()):
    t = workdir_total[wd]
    f = workdir_failures.get(wd, 0)
    rate = (f / t * 100) if t > 0 else 0
    workdir_stats[wd] = {
        'total': t,
        'failures': f,
        'failure_rate': round(rate, 1),
    }

# Identify high-failure agents (>30%)
high_failure_agents = {
    agent: stats for agent, stats in agent_stats.items()
    if stats['failure_rate'] > 30.0
}

# Most common failure agents (sorted by failure count descending)
common_failure_agents = sorted(
    [(a, s) for a, s in agent_stats.items() if s['failures'] > 0],
    key=lambda x: x[1]['failures'],
    reverse=True,
)

if json_output:
    report = {
        'summary': {
            'total_sessions': total,
            'total_failures': failures,
            'overall_failure_rate': round(failure_rate, 1),
            'outcomes_dir': '$OUTCOMES_DIR',
        },
        'agents': agent_stats,
        'workdirs': workdir_stats,
        'patterns': {
            'high_failure_agents': high_failure_agents,
            'most_common_failure_agents': [
                {'agent': a, **s} for a, s in common_failure_agents[:10]
            ],
        },
    }
    if '$CUTOFF':
        report['summary']['since'] = '$CUTOFF'
    print(json.dumps(report, indent=2))
else:
    print('=' * 60)
    print('securetty session retrospective')
    print('=' * 60)
    if '$CUTOFF':
        print(f'Period: since $CUTOFF')
    print(f'Total sessions:     {total}')
    print(f'Total failures:     {failures}')
    print(f'Overall failure rate: {failure_rate:.1f}%')
    print()

    print('-' * 60)
    print('Per-agent breakdown:')
    print('-' * 60)
    print(f'{\"Agent\":<20} {\"Total\":>8} {\"Fail\":>8} {\"Rate\":>8} {\"Avg(s)\":>8}')
    for agent, stats in sorted(agent_stats.items()):
        marker = ' !!!' if stats['failure_rate'] > 30.0 else ''
        print(f'{agent:<20} {stats[\"total\"]:>8} {stats[\"failures\"]:>8} {stats[\"failure_rate\"]:>7.1f}% {stats[\"avg_duration_seconds\"]:>8.1f}{marker}')
    print()

    if high_failure_agents:
        print('-' * 60)
        print('HIGH FAILURE AGENTS (>30% failure rate):')
        print('-' * 60)
        for agent, stats in sorted(high_failure_agents.items(), key=lambda x: x[1]['failure_rate'], reverse=True):
            print(f'  {agent}: {stats[\"failure_rate\"]}% failure rate ({stats[\"failures\"]}/{stats[\"total\"]} sessions)')
        print()

    if common_failure_agents:
        print('-' * 60)
        print('Most common failure agents (by failure count):')
        print('-' * 60)
        for agent, stats in common_failure_agents[:10]:
            print(f'  {agent}: {stats[\"failures\"]} failures out of {stats[\"total\"]} sessions')
        print()

    print('-' * 60)
    print('Per-workdir breakdown:')
    print('-' * 60)
    print(f'{\"Workdir\":<40} {\"Total\":>8} {\"Fail\":>8} {\"Rate\":>8}')
    for wd, stats in sorted(workdir_stats.items()):
        print(f'{wd:<40} {stats[\"total\"]:>8} {stats[\"failures\"]:>8} {stats[\"failure_rate\"]:>7.1f}%')
    print()

    print('=' * 60)
"
