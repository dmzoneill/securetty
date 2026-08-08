#!/usr/bin/env python3
"""securetty dispatcher — work item router and agent launcher."""

import json
import os
import sqlite3
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from metrics import record_job_complete, render_metrics
from workflows import (
    WorkflowRunner,
    load_all_workflows,
)

app = FastAPI(title="securetty-dispatcher", version="1.0.0")

DB_PATH = os.environ.get("DISPATCHER_DB", "/data/dispatcher.db")
TOON_PATH = os.environ.get("TOON_PATH", "/config/workflows.toon")
PODMAN_SOCKET = os.environ.get("PODMAN_SOCKET", "/run/podman/podman.sock")
SECURETTY_IMAGE = os.environ.get("SECURETTY_IMAGE", "securetty_dev")
SECURETTY_NETWORK = os.environ.get("SECURETTY_NETWORK", "securetty")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "300"))
MAX_CONCURRENT_JOBS = int(os.environ.get("MAX_CONCURRENT_JOBS", "3"))
WORKFLOWS_DIR = os.environ.get("WORKFLOWS_DIR", str(Path(__file__).resolve().parent.parent / "workflows"))

_scheduler_lock = threading.Lock()


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            work_item TEXT NOT NULL,
            skill TEXT,
            agent TEXT DEFAULT 'claude',
            status TEXT DEFAULT 'pending',
            source TEXT DEFAULT 'cli',
            priority INTEGER DEFAULT 5,
            created_at TEXT NOT NULL,
            started_at TEXT,
            finished_at TEXT,
            exit_code INTEGER,
            error TEXT,
            metadata TEXT DEFAULT '{}'
        )
    """)
    # Migration: add priority column to existing databases
    try:
        conn.execute("ALTER TABLE jobs ADD COLUMN priority INTEGER DEFAULT 5")
    except sqlite3.OperationalError:
        pass  # Column already exists
    conn.execute("""
        CREATE TABLE IF NOT EXISTS triggers (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            repo TEXT NOT NULL,
            event_type TEXT NOT NULL,
            poll_interval INTEGER DEFAULT 300,
            last_checked TEXT,
            enabled INTEGER DEFAULT 1,
            config TEXT DEFAULT '{}'
        )
    """)
    conn.commit()
    conn.close()


def load_toon():
    """Parse workflows.toon CSV into routing rules."""
    rules = []
    if not os.path.exists(TOON_PATH):
        return rules
    with open(TOON_PATH) as f:
        header = None
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if header is None:
                header = parts
                continue
            if len(parts) >= len(header):
                rule = dict(zip(header, parts))
                rules.append(rule)
    return rules


def match_skill(work_item: str, rules: list) -> dict | None:
    """Match a work item to a skill via trigger keywords."""
    work_lower = work_item.lower()
    for rule in rules:
        triggers = [t.strip().lower() for t in rule.get("triggers", "").split(";") if t.strip()]
        for trigger in triggers:
            if trigger in work_lower:
                return rule
    return None


class DispatchRequest(BaseModel):
    work_item: str
    agent: str = "claude"
    skill: str | None = None
    source: str = "cli"
    priority: int = Field(default=5, ge=1, le=10, description="Job priority (1=highest, 10=lowest)")
    metadata: dict = Field(default_factory=dict)


class WebhookPayload(BaseModel):
    event: str = ""
    repo: str = ""
    data: dict = Field(default_factory=dict)


@app.on_event("startup")
def startup():
    init_db()


@app.get("/health")
def health():
    return {"status": "ok", "jobs": _count_jobs()}


@app.get("/metrics")
def metrics():
    """Expose Prometheus metrics in text exposition format."""
    return Response(content=render_metrics(), media_type="text/plain; version=0.0.4; charset=utf-8")


@app.get("/status")
def status():
    conn = get_db()
    counts = {}
    for s in ["pending", "running", "completed", "failed"]:
        row = conn.execute("SELECT COUNT(*) as c FROM jobs WHERE status=?", (s,)).fetchone()
        counts[s] = row["c"]
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    completed_today = conn.execute(
        "SELECT COUNT(*) as c FROM jobs WHERE status='completed' AND finished_at LIKE ?",
        (f"{today}%",),
    ).fetchone()["c"]
    conn.close()
    rules = load_toon()
    return {
        "status": "ok",
        "jobs": counts,
        "queue_depth": counts["pending"],
        "running_count": counts["running"],
        "completed_today": completed_today,
        "max_concurrent_jobs": MAX_CONCURRENT_JOBS,
        "skills": len(rules),
        "poll_interval": POLL_INTERVAL,
    }


@app.post("/dispatch")
def dispatch(req: DispatchRequest):
    rules = load_toon()
    skill = req.skill
    if not skill:
        matched = match_skill(req.work_item, rules)
        if matched:
            skill = matched.get("skill_name")

    job_id = str(uuid.uuid4())[:8]
    now = datetime.now(timezone.utc).isoformat()

    conn = get_db()
    conn.execute(
        "INSERT INTO jobs (id, work_item, skill, agent, status, source, priority, created_at, metadata) VALUES (?,?,?,?,?,?,?,?,?)",
        (job_id, req.work_item, skill, req.agent, "pending", req.source, req.priority, now, json.dumps(req.metadata)),
    )
    conn.commit()
    conn.close()

    # Trigger scheduler to pick up the new job if slots are available
    threading.Thread(target=_try_start_pending_jobs, daemon=True).start()

    return {"job_id": job_id, "skill": skill, "agent": req.agent, "priority": req.priority, "status": "pending"}


@app.get("/jobs")
def list_jobs(status: str | None = None, limit: int = 50):
    conn = get_db()
    if status:
        rows = conn.execute(
            "SELECT * FROM jobs WHERE status=? ORDER BY created_at DESC LIMIT ?", (status, limit)
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.get("/jobs/{job_id}")
def get_job(job_id: str):
    conn = get_db()
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Job not found")
    return dict(row)


@app.delete("/jobs/{job_id}")
def cancel_job(job_id: str):
    conn = get_db()
    conn.execute("UPDATE jobs SET status='cancelled' WHERE id=? AND status='pending'", (job_id,))
    conn.commit()
    conn.close()
    return {"job_id": job_id, "status": "cancelled"}


@app.post("/jobs/{job_id}/retry")
def retry_job(job_id: str):
    """Re-queue a failed job for execution."""
    conn = get_db()
    row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="Job not found")
    if row["status"] != "failed":
        conn.close()
        raise HTTPException(status_code=400, detail="Only failed jobs can be retried")
    conn.execute(
        "UPDATE jobs SET status='pending', started_at=NULL, finished_at=NULL, exit_code=NULL, error=NULL WHERE id=?",
        (job_id,),
    )
    conn.commit()
    conn.close()

    threading.Thread(target=_try_start_pending_jobs, daemon=True).start()

    return {"job_id": job_id, "status": "pending"}


@app.post("/webhook/github")
async def webhook_github(request: Request):
    body = await request.json()
    event = request.headers.get("X-GitHub-Event", "unknown")
    repo = body.get("repository", {}).get("full_name", "unknown")
    return _handle_webhook("github", event, repo, body)


@app.post("/webhook/gitlab")
async def webhook_gitlab(request: Request):
    body = await request.json()
    event = body.get("object_kind", "unknown")
    repo = body.get("project", {}).get("path_with_namespace", "unknown")
    return _handle_webhook("gitlab", event, repo, body)


@app.post("/webhook/jira")
async def webhook_jira(request: Request):
    body = await request.json()
    event = body.get("webhookEvent", "unknown")
    key = body.get("issue", {}).get("key", "unknown")
    return _handle_webhook("jira", event, key, body)


@app.post("/triggers")
def create_trigger(source: str, repo: str, event_type: str, poll_interval: int = 300, config: dict = {}):
    trigger_id = str(uuid.uuid4())[:8]
    conn = get_db()
    conn.execute(
        "INSERT INTO triggers (id, source, repo, event_type, poll_interval, config) VALUES (?,?,?,?,?,?)",
        (trigger_id, source, repo, event_type, poll_interval, json.dumps(config)),
    )
    conn.commit()
    conn.close()
    return {"trigger_id": trigger_id, "source": source, "repo": repo}


@app.get("/triggers")
def list_triggers():
    conn = get_db()
    rows = conn.execute("SELECT * FROM triggers WHERE enabled=1").fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.delete("/triggers/{trigger_id}")
def delete_trigger(trigger_id: str):
    conn = get_db()
    conn.execute("DELETE FROM triggers WHERE id=?", (trigger_id,))
    conn.commit()
    conn.close()
    return {"deleted": trigger_id}


# ---------------------------------------------------------------------------
# Workflow composition engine
# ---------------------------------------------------------------------------

def _dispatch_for_workflow(
    work_item: str,
    skill: str,
    agent: str = "claude",
    metadata: dict | None = None,
) -> dict:
    """Blocking dispatch: create a job and poll until it finishes.

    Used by WorkflowRunner so that stage dependencies are honoured.
    """
    req = DispatchRequest(
        work_item=work_item,
        skill=skill,
        agent=agent,
        source="workflow",
        metadata=metadata or {},
    )
    result = dispatch(req)
    job_id = result["job_id"]

    # Poll for completion (check every 2 s, up to 30 min).
    deadline = time.monotonic() + 1800
    while time.monotonic() < deadline:
        time.sleep(2)
        conn = get_db()
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        conn.close()
        if not row:
            raise RuntimeError(f"Job {job_id} disappeared")
        if row["status"] in ("completed", "failed", "cancelled"):
            if row["status"] != "completed":
                raise RuntimeError(
                    f"Job {job_id} {row['status']}: {row['error'] or 'no details'}"
                )
            return dict(row)

    raise TimeoutError(f"Job {job_id} did not complete within 30 minutes")


_workflow_runner = WorkflowRunner(dispatch_fn=_dispatch_for_workflow)


class WorkflowRunRequest(BaseModel):
    workflow: str
    work_item: str
    fail_fast: bool = Field(default=True, description="Stop on first stage failure")


@app.get("/workflows")
def list_workflows():
    """List available workflow definitions loaded from YAML."""
    workflows = load_all_workflows(WORKFLOWS_DIR)
    return [
        {
            "name": wf.name,
            "stages": [
                {
                    "name": s.name,
                    "skill": s.skill,
                    "agent": s.agent,
                    "depends_on": s.depends_on,
                }
                for s in wf.stages
            ],
        }
        for wf in workflows.values()
    ]


@app.post("/workflows/run")
def run_workflow(req: WorkflowRunRequest):
    """Start a workflow execution. Returns a workflow_id for status polling."""
    workflows = load_all_workflows(WORKFLOWS_DIR)
    wf = workflows.get(req.workflow)
    if not wf:
        raise HTTPException(
            status_code=404,
            detail=f"Workflow '{req.workflow}' not found. "
            f"Available: {list(workflows.keys())}",
        )

    try:
        run = _workflow_runner.start(wf, req.work_item, req.fail_fast)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    return {
        "workflow_id": run.id,
        "workflow_name": wf.name,
        "work_item": req.work_item,
        "status": run.status,
    }


@app.get("/workflows/{workflow_id}")
def get_workflow_status(workflow_id: str):
    """Return workflow status with per-stage breakdown."""
    run = _workflow_runner.get_run(workflow_id)
    if not run:
        raise HTTPException(status_code=404, detail="Workflow run not found")
    return run.to_dict()


def _count_jobs():
    try:
        conn = get_db()
        row = conn.execute("SELECT COUNT(*) as c FROM jobs").fetchone()
        conn.close()
        return row["c"]
    except Exception:
        return 0


def _handle_webhook(source: str, event: str, repo: str, body: dict):
    work_item = f"{source}:{event}:{repo}"
    req = DispatchRequest(work_item=work_item, source=f"webhook:{source}", metadata={"event": event, "repo": repo})
    return dispatch(req)


def _try_start_pending_jobs():
    """Check for pending jobs and start them if concurrency limits allow."""
    with _scheduler_lock:
        conn = get_db()
        running_count = conn.execute(
            "SELECT COUNT(*) as c FROM jobs WHERE status='running'"
        ).fetchone()["c"]
        available_slots = MAX_CONCURRENT_JOBS - running_count
        if available_slots <= 0:
            conn.close()
            return

        pending = conn.execute(
            "SELECT id FROM jobs WHERE status='pending' ORDER BY priority ASC, created_at ASC LIMIT ?",
            (available_slots,),
        ).fetchall()
        if not pending:
            conn.close()
            return

        now = datetime.now(timezone.utc).isoformat()
        job_ids = []
        for row in pending:
            conn.execute(
                "UPDATE jobs SET status='running', started_at=? WHERE id=? AND status='pending'",
                (now, row["id"]),
            )
            job_ids.append(row["id"])
        conn.commit()
        conn.close()

        for jid in job_ids:
            threading.Thread(target=_execute_job, args=(jid,), daemon=True).start()


def _execute_job(job_id: str):
    """Execute a dispatched job by launching an agent container via podman socket."""
    import http.client

    conn = get_db()
    row = conn.execute("SELECT * FROM jobs WHERE id=? AND status='running'", (job_id,)).fetchone()
    if not row:
        conn.close()
        return

    work_item = row["work_item"]
    agent = row["agent"]
    skill = row["skill"]

    job_start = time.monotonic()
    final_status = "failed"
    final_exit_code = None

    try:
        cmd = [agent]
        if skill:
            cmd.extend(["--prompt", f"/{skill} {work_item}"])
        else:
            cmd.extend(["--prompt", work_item])

        container_name = f"securetty-dispatch-{job_id}"

        create_body = {
            "Image": SECURETTY_IMAGE,
            "Cmd": cmd,
            "Env": [f"DISPATCH_JOB_ID={job_id}"],
            "HostConfig": {
                "NetworkMode": SECURETTY_NETWORK,
                "AutoRemove": True,
            },
            "Name": container_name,
        }

        import socket as socketmod

        s = socketmod.socket(socketmod.AF_UNIX, socketmod.SOCK_STREAM)
        s.connect(PODMAN_SOCKET)
        try:
            sock = http.client.HTTPConnection("localhost")
            sock.sock = s

            body_json = json.dumps(create_body)
            sock.request("POST", "/v4.0.0/libpod/containers/create", body=body_json, headers={"Content-Type": "application/json"})
            resp = sock.getresponse()
            result = json.loads(resp.read())

            if resp.status in (200, 201):
                container_id = result.get("Id", "")
                sock.request("POST", f"/v4.0.0/libpod/containers/{container_id}/start")
                start_resp = sock.getresponse()
                start_resp.read()

                sock.request("POST", f"/v4.0.0/libpod/containers/{container_id}/wait")
                wait_resp = sock.getresponse()
                wait_result = json.loads(wait_resp.read())
                exit_code = wait_result.get("StatusCode", -1)

                finished = datetime.now(timezone.utc).isoformat()
                final_status = "completed" if exit_code == 0 else "failed"
                final_exit_code = exit_code
                conn.execute(
                    "UPDATE jobs SET status=?, finished_at=?, exit_code=? WHERE id=?",
                    (final_status, finished, exit_code, job_id),
                )
            else:
                conn.execute(
                    "UPDATE jobs SET status='failed', error=? WHERE id=?",
                    (json.dumps(result), job_id),
                )
        finally:
            s.close()

    except Exception as e:
        print(f"Job {job_id} failed: {e}", file=sys.stderr)
        conn.execute(
            "UPDATE jobs SET status='failed', error=? WHERE id=?",
            (str(e), job_id),
        )

    conn.commit()
    conn.close()

    duration = time.monotonic() - job_start
    record_job_complete(
        agent=agent,
        skill=skill,
        status=final_status,
        duration_seconds=duration,
        exit_code=final_exit_code,
    )

    # Slot freed — trigger scheduler to pick up next pending job
    threading.Thread(target=_try_start_pending_jobs, daemon=True).start()


def _polling_loop():
    """Background thread polling configured trigger sources."""
    while True:
        try:
            conn = get_db()
            triggers = conn.execute("SELECT * FROM triggers WHERE enabled=1").fetchall()
            conn.close()

            for trigger in triggers:
                source = trigger["source"]
                repo = trigger["repo"]
                event_type = trigger["event_type"]
                config = json.loads(trigger["config"] or "{}")

                events = []
                if source == "github":
                    events = _poll_github(repo, event_type, config)
                elif source == "gitlab":
                    events = _poll_gitlab(repo, event_type, config)
                elif source == "jira":
                    events = _poll_jira(repo, event_type, config)

                for event in events:
                    req = DispatchRequest(
                        work_item=event, source=f"poll:{source}", metadata={"repo": repo, "trigger_id": trigger["id"]}
                    )
                    dispatch(req)

                conn = get_db()
                conn.execute(
                    "UPDATE triggers SET last_checked=? WHERE id=?",
                    (datetime.now(timezone.utc).isoformat(), trigger["id"]),
                )
                conn.commit()
                conn.close()

        except Exception as e:
            print(f"Polling error: {e}", file=sys.stderr)

        time.sleep(POLL_INTERVAL)


def _poll_github(repo: str, event_type: str, config: dict) -> list:
    """Poll GitHub for new events. Returns list of work item strings."""
    import subprocess

    result = subprocess.run(
        ["gh", "api", f"/repos/{repo}/events", "--jq", f'[.[] | select(.type=="{event_type}") | .id] | join(",")'],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return []
    return [f"github:{event_type}:{repo}:{eid}" for eid in result.stdout.strip().split(",") if eid]


def _poll_gitlab(repo: str, event_type: str, config: dict) -> list:
    """Poll GitLab for new events."""
    import subprocess

    result = subprocess.run(
        ["glab", "api", f"projects/{repo}/events", "--per-page", "10"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return []
    try:
        events = json.loads(result.stdout)
        return [f"gitlab:{e.get('action_name', 'unknown')}:{repo}" for e in events if e.get("action_name") == event_type]
    except (json.JSONDecodeError, TypeError):
        return []


def _poll_jira(project: str, event_type: str, config: dict) -> list:
    """Poll Jira for issues matching criteria."""
    import subprocess
    import urllib.parse

    jql = config.get("jql", f"project={project} AND status='{event_type}' AND updated >= -5m")
    encoded_jql = urllib.parse.quote(jql, safe="")
    jira_url = os.environ.get("JIRA_URL", "")
    result = subprocess.run(
        ["curl", "-sf", f"{jira_url}/rest/api/2/search?jql={encoded_jql}&maxResults=10"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return []
    try:
        data = json.loads(result.stdout)
        return [f"jira:{issue['key']}" for issue in data.get("issues", [])]
    except (json.JSONDecodeError, TypeError, KeyError):
        return []


def _scheduler_loop():
    """Background thread that checks for pending jobs every 10 seconds."""
    while True:
        try:
            _try_start_pending_jobs()
        except Exception as e:
            print(f"Scheduler error: {e}", file=sys.stderr)
        time.sleep(10)


# Start scheduler thread on startup
@app.on_event("startup")
def start_scheduler():
    t = threading.Thread(target=_scheduler_loop, daemon=True)
    t.start()


# Start polling thread on startup
@app.on_event("startup")
def start_polling():
    t = threading.Thread(target=_polling_loop, daemon=True)
    t.start()


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("PORT", "8900"))
    cert = os.environ.get("TLS_CERT", "/certs/dispatcher.crt")
    key = os.environ.get("TLS_KEY", "/certs/dispatcher.key")

    kwargs = {"host": "0.0.0.0", "port": port}
    if os.path.exists(cert) and os.path.exists(key):
        kwargs["ssl_certfile"] = cert
        kwargs["ssl_keyfile"] = key

    uvicorn.run(app, **kwargs)
