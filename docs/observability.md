# Observability

The securetty dispatcher exposes Prometheus metrics at its `/metrics` endpoint,
giving visibility into job throughput, queue depth, error rates, and execution
duration.

## Metrics Reference

### Counters

| Metric | Labels | Description |
|--------|--------|-------------|
| `securetty_jobs_total` | `status`, `agent`, `skill` | Cumulative count of completed/failed jobs |
| `securetty_sessions_total` | `agent`, `exit_code` | Cumulative count of agent sessions (one per container run) |

### Gauges

| Metric | Description |
|--------|-------------|
| `securetty_jobs_running` | Number of jobs currently executing in containers |
| `securetty_jobs_pending` | Number of jobs waiting in the dispatch queue |

Gauges are refreshed from SQLite on every `/metrics` scrape.

### Histograms

| Metric | Labels | Description |
|--------|--------|-------------|
| `securetty_job_duration_seconds` | `agent` | Wall-clock execution time per job |
| `securetty_session_duration_seconds` | _(none)_ | Wall-clock session duration across all agents |

Bucket boundaries: 1s, 5s, 10s, 30s, 1m, 2m, 5m, 10m, 30m, 1h.

## Scraping with Prometheus

Add a scrape job to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: securetty-dispatcher
    scrape_interval: 15s
    static_configs:
      - targets: ["dispatcher:8900"]
    # If TLS is enabled on the dispatcher:
    # scheme: https
    # tls_config:
    #   insecure_skip_verify: true
```

Verify the target is up at **Status > Targets** in the Prometheus web UI.

## Grafana Dashboard

Import the panels below into a new Grafana dashboard connected to your
Prometheus data source.

### Key Panels

**Job throughput (rate of completed vs failed jobs):**

```promql
sum(rate(securetty_jobs_total[5m])) by (status)
```

**Error rate (fraction of jobs that fail):**

```promql
sum(rate(securetty_jobs_total{status="failed"}[5m]))
/ sum(rate(securetty_jobs_total[5m]))
```

**Duration p95 per agent:**

```promql
histogram_quantile(0.95, sum(rate(securetty_job_duration_seconds_bucket[5m])) by (le, agent))
```

**Queue depth (pending + running):**

```promql
securetty_jobs_pending
securetty_jobs_running
```

**Sessions by exit code (table):**

```promql
sum(securetty_sessions_total) by (agent, exit_code)
```

### Suggested Layout

| Row | Panels |
|-----|--------|
| 1 | Stat: jobs pending, Stat: jobs running, Stat: error rate |
| 2 | Time series: job throughput by status |
| 3 | Heatmap: job duration, Time series: p50/p95/p99 duration |
| 4 | Table: sessions by agent and exit code |

## Integration with securetty cost tracking

The `securetty cost` CLI command reads OmniRoute logs to compute per-provider
token spend. To correlate cost with dispatcher metrics:

- Tag dispatch requests with a `cost_tracking_id` in the metadata field.
- OmniRoute logs include `X-Request-ID` headers that can be joined against
  job IDs in the dispatcher database.
- A future Grafana panel can overlay `securetty_jobs_total` rate against
  cost-per-hour derived from OmniRoute billing data.

## Future: OpenTelemetry Tracing Roadmap

The next phase will add distributed tracing via OpenTelemetry (OTEL) spans
covering the full job lifecycle:

```
dispatch (HTTP POST /dispatch)
  |-- route (skill matching from workflows.toon)
  |-- execute (container create + start via podman socket)
       |-- agent_session (work inside the container)
  |-- complete (status update + metrics recording)
```

Planned implementation:

1. **Add `opentelemetry-api` and `opentelemetry-sdk`** to dispatcher
   requirements alongside the OTLP exporter.
2. **Instrument FastAPI** with `opentelemetry-instrumentation-fastapi` for
   automatic HTTP span creation.
3. **Create manual spans** in `_execute_job()` for the route, execute, and
   complete phases.
4. **Propagate trace context** into agent containers via the
   `TRACEPARENT` environment variable so agent-side spans can be linked.
5. **Export to Jaeger or Tempo** via the OTLP gRPC exporter, configurable
   through `OTEL_EXPORTER_OTLP_ENDPOINT`.

This will enable end-to-end latency analysis from dispatch request through
agent execution to completion, visible in Grafana via the Tempo data source.
