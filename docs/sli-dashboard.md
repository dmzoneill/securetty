# SLI Dashboard and Alerting

This document covers the securetty observability dashboard and alerting
system: what is measured, how alerts fire, and how to customize the setup.

## SLI Definitions

Service Level Indicators track the operational health of the securetty
platform across four dimensions.

### Availability

Percentage of securetty services in a running/healthy state.

- **Measurement:** `podman ps -a` filtered to `securetty-*` containers.
- **Target:** 100% of 14 services running at all times.
- **Degraded:** Any service exited, dead, or in created state.

### Completion Rate

Percentage of dispatched jobs that finish with exit code 0.

- **Measurement:** `securetty_jobs_total{status="completed"}` vs total from
  Prometheus, cross-checked against `~/.securetty/outcomes/*.jsonl`.
- **Target:** >95% completion rate over a rolling 24-hour window.
- **Error budget:** 5% — roughly 1 in 20 sessions may fail before alerting.

### P95 Latency

95th percentile wall-clock duration for agent sessions.

- **Measurement:** `securetty_job_duration_seconds` histogram with buckets
  from 1s to 1h.
- **Target:** P95 under 600s (10 minutes) for standard jobs.
- **Query:** `histogram_quantile(0.95, sum(rate(securetty_job_duration_seconds_bucket[5m])) by (le, agent))`

### Error Budget

Remaining failure allowance before the completion rate SLO is breached.

- **Calculation:** `1 - (actual_error_rate / allowed_error_rate)` expressed
  as a percentage. When this reaches 0%, the SLO is violated.
- **Window:** Rolling 7-day period.
- **Alert threshold:** Error budget below 20% remaining triggers a warning.

## Dashboard Layout

The TUI dashboard (`securetty-dashboard.sh`) renders five panels.

### Panel 1: Container Health

Shows all securetty services with status indicators:

```
  Container Health
  ------------------------------------------------------------------
  NAME                         STATE      STATUS
  ● securetty                  running    Up 3 hours (healthy)
  ● securetty-dispatcher       running    Up 3 hours
  ● securetty-omniroute        running    Up 3 hours (healthy)
  ● securetty-headroom         running    Up 3 hours
  ...
```

- Green dot: running (healthy if applicable)
- Yellow dot: starting
- Red dot: exited/dead/created

**Data source:** `podman ps -a`

### Panel 2: Job Queue

Dispatcher queue state from the `/status` API:

```
  Job Queue
  ------------------------------------------------------------------
  Pending:    0
  Running:    1 / 3 max
  Completed:  42 (today: 7)
  Failed:     3
  Skills:     12 loaded
```

Pending count turns red when it exceeds 10 (queue backup).

**Data source:** dispatcher `/status` endpoint

### Panel 3: Agent Metrics (today)

Per-agent breakdown from today's session outcomes:

```
  Agent Metrics (today)
  ------------------------------------------------------------------
  Total sessions: 15    Failures: 2    Failure rate: 13.3%

  AGENT              SESSIONS     FAIL     RATE     AVG(s)
  claude                   10        1    10.0%      120.5
  codex                     3        1    33.3%       85.2 !!!
  gemini                    2        0     0.0%       95.0
```

Agents with >30% failure rate are flagged with `!!!`.

**Data source:** `~/.securetty/outcomes/YYYY-MM-DD.jsonl`

### Panel 4: Cost Summary

Session counts and cost spike detection:

```
  Cost Summary
  ------------------------------------------------------------------
  Today:      8 sessions
  This week:  42 sessions (avg 6.0/day)

  By agent today:
    claude             5
    codex              3
```

A cost spike warning appears when today's count exceeds 2x the 7-day daily
average.

**Data source:** `~/.securetty/cost/YYYY-MM-DD.jsonl`

### Panel 5: Recent Alerts

Active alert conditions from scanners and failure patterns:

```
  Recent Alerts
  ------------------------------------------------------------------
   CRIT  [container] securetty-guarddog is exited
   WARN  [error-rate] Error rate 25% in last hour (5/20 sessions)
```

**Data source:** Scanner container logs, outcomes analysis, container state

## Alert Conditions and Thresholds

The alerting script (`securetty-alerts.sh`) checks five SLI conditions.

| Check | Default Threshold | Severity | Description |
|-------|-------------------|----------|-------------|
| `container_unhealthy` | Any service not running | Critical | A securetty container is exited, dead, or stuck in created state |
| `agent_stuck` | Running >30 minutes | Warning | A dispatched job has been running longer than the threshold without completing |
| `cost_spike` | >2x daily average | Warning | Today's session count exceeds the multiplier times the 7-day daily average |
| `error_rate` | >20% in last hour | Critical | Failure rate in the last hour exceeds the threshold (minimum 5 samples) |
| `queue_backup` | >10 pending jobs | Warning | Dispatcher queue depth exceeds the limit |

### Exit Codes

- `0` — All checks passed, no alerts firing.
- `1` — One or more alerts are firing.

## Customizing Alert Thresholds

All thresholds are configurable via environment variables:

```bash
# Agent stuck threshold (minutes)
export SECURETTY_ALERT_STUCK_MINUTES=45

# Cost spike multiplier (today vs 7-day daily average)
export SECURETTY_ALERT_COST_MULTIPLIER=3

# Error rate threshold (percent, applied over last hour)
export SECURETTY_ALERT_ERROR_RATE_PCT=15

# Queue backup limit (pending jobs)
export SECURETTY_ALERT_QUEUE_LIMIT=20

# Minimum sessions required before error rate check applies
export SECURETTY_ALERT_MIN_SAMPLES=10

# Dispatcher URL (if non-default)
export SECURETTY_DISPATCHER_URL=https://localhost:8900
```

Set these in your shell profile, cron environment, or systemd unit override.

## Cron and systemd Timer Setup

### Cron (check every 5 minutes, notify on alert)

```cron
*/5 * * * * /path/to/securetty-alerts.sh --notify 2>/dev/null
```

### Cron (log JSON to file for later analysis)

```cron
*/5 * * * * /path/to/securetty-alerts.sh --json >> ~/.securetty/alerts.jsonl 2>/dev/null
```

### systemd Timer

Create two unit files:

**`~/.config/systemd/user/securetty-alerts.service`**

```ini
[Unit]
Description=securetty SLI alert check

[Service]
Type=oneshot
ExecStart=%h/src/securetty/roles/containers/files/securetty-alerts.sh --notify
Environment=SECURETTY_DISPATCHER_URL=https://securetty-dispatcher:8900
```

**`~/.config/systemd/user/securetty-alerts.timer`**

```ini
[Unit]
Description=Run securetty SLI checks every 5 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=300
AccuracySec=30

[Install]
WantedBy=timers.target
```

Enable with:

```bash
systemctl --user daemon-reload
systemctl --user enable --now securetty-alerts.timer
```

Check timer status:

```bash
systemctl --user list-timers securetty-alerts.timer
journalctl --user -u securetty-alerts.service --since "1 hour ago"
```

## Integration with Grafana

The dispatcher already exposes Prometheus metrics at `/metrics`
(see `docs/observability.md`). To build a Grafana dashboard that mirrors
the TUI panels:

### Data Source Setup

1. Add a Prometheus data source pointing at your Prometheus instance.
2. Ensure the `securetty-dispatcher` scrape job is configured
   (see `docs/observability.md` for the scrape config).

### Dashboard Panels

**Row 1 — Overview stats:**

| Panel | Type | Query |
|-------|------|-------|
| Jobs Pending | Stat | `securetty_jobs_pending` |
| Jobs Running | Stat | `securetty_jobs_running` |
| Error Rate | Stat | `sum(rate(securetty_jobs_total{status="failed"}[1h])) / sum(rate(securetty_jobs_total[1h]))` |
| Completion Rate | Stat | `1 - (sum(rate(securetty_jobs_total{status="failed"}[24h])) / sum(rate(securetty_jobs_total[24h])))` |

**Row 2 — Throughput:**

| Panel | Type | Query |
|-------|------|-------|
| Job Throughput | Time series | `sum(rate(securetty_jobs_total[5m])) by (status)` |
| Sessions by Agent | Time series | `sum(rate(securetty_sessions_total[5m])) by (agent)` |

**Row 3 — Latency:**

| Panel | Type | Query |
|-------|------|-------|
| Duration P50/P95/P99 | Time series | `histogram_quantile(0.50, sum(rate(securetty_job_duration_seconds_bucket[5m])) by (le))` (repeat for 0.95, 0.99) |
| Duration Heatmap | Heatmap | `sum(rate(securetty_job_duration_seconds_bucket[5m])) by (le)` |

**Row 4 — Error budget:**

| Panel | Type | Query |
|-------|------|-------|
| Error Budget Remaining | Gauge | `1 - (sum(increase(securetty_jobs_total{status="failed"}[7d])) / (sum(increase(securetty_jobs_total[7d])) * 0.05))` |
| Sessions by Exit Code | Table | `sum(securetty_sessions_total) by (agent, exit_code)` |

### Alert Rules in Grafana

Create Grafana alert rules matching the CLI alert conditions:

```yaml
# Error rate above threshold
- alert: SecurettyHighErrorRate
  expr: >
    sum(rate(securetty_jobs_total{status="failed"}[1h]))
    / sum(rate(securetty_jobs_total[1h])) > 0.20
  for: 5m
  labels:
    severity: critical

# Queue backup
- alert: SecurettyQueueBackup
  expr: securetty_jobs_pending > 10
  for: 5m
  labels:
    severity: warning

# Agent stuck (job running too long)
- alert: SecurettyAgentStuck
  expr: securetty_jobs_running > 0 and securetty_jobs_pending > 0
  for: 30m
  labels:
    severity: warning
```

These complement the CLI-based alerts with persistent, time-windowed
monitoring.
