"""Prometheus metrics for the securetty dispatcher."""

import os
import sqlite3
import time

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

DB_PATH = os.environ.get("DISPATCHER_DB", "/data/dispatcher.db")

registry = CollectorRegistry()

# Counters
securetty_jobs_total = Counter(
    "securetty_jobs_total",
    "Total number of jobs processed",
    ["status", "agent", "skill"],
    registry=registry,
)

securetty_sessions_total = Counter(
    "securetty_sessions_total",
    "Total number of agent sessions completed",
    ["agent", "exit_code"],
    registry=registry,
)

# Gauges
securetty_jobs_running = Gauge(
    "securetty_jobs_running",
    "Number of jobs currently running",
    registry=registry,
)

securetty_jobs_pending = Gauge(
    "securetty_jobs_pending",
    "Number of jobs waiting in the queue",
    registry=registry,
)

# Histograms
securetty_job_duration_seconds = Histogram(
    "securetty_job_duration_seconds",
    "Duration of job execution in seconds",
    ["agent"],
    buckets=(1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600),
    registry=registry,
)

securetty_session_duration_seconds = Histogram(
    "securetty_session_duration_seconds",
    "Duration of agent sessions in seconds",
    buckets=(1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600),
    registry=registry,
)


def _get_db():
    """Open a read-only connection to the dispatcher database."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def update_from_db():
    """Read current job counts from SQLite and update gauge metrics."""
    try:
        conn = _get_db()
        running = conn.execute(
            "SELECT COUNT(*) as c FROM jobs WHERE status='running'"
        ).fetchone()["c"]
        pending = conn.execute(
            "SELECT COUNT(*) as c FROM jobs WHERE status='pending'"
        ).fetchone()["c"]
        conn.close()

        securetty_jobs_running.set(running)
        securetty_jobs_pending.set(pending)
    except Exception:
        pass


def record_job_complete(agent: str, skill: str | None, status: str,
                        duration_seconds: float, exit_code: int | None = None):
    """Record metrics when a job finishes execution.

    Called from app.py after a job's status is updated in the database.

    Args:
        agent: The agent type that ran the job (e.g. 'claude').
        skill: The skill used, or None if no skill was matched.
        status: Final job status ('completed' or 'failed').
        duration_seconds: Wall-clock seconds the job ran.
        exit_code: Container exit code, or None if the container never started.
    """
    skill_label = skill or ""

    securetty_jobs_total.labels(status=status, agent=agent, skill=skill_label).inc()

    if exit_code is not None:
        securetty_sessions_total.labels(
            agent=agent, exit_code=str(exit_code)
        ).inc()

    securetty_job_duration_seconds.labels(agent=agent).observe(duration_seconds)
    securetty_session_duration_seconds.observe(duration_seconds)


def render_metrics() -> bytes:
    """Generate Prometheus text exposition format.

    Refreshes gauge values from the database before rendering so that
    /metrics always reflects current queue state.
    """
    update_from_db()
    return generate_latest(registry)
