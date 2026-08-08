"""DAG-based workflow composition engine for multi-step job orchestration."""

import json
import threading
import time
import uuid
from collections import defaultdict, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable


class StageStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    SKIPPED = "skipped"


@dataclass
class Stage:
    """A single step in a workflow DAG."""

    name: str
    skill: str
    agent: str = "claude"
    depends_on: list[str] = field(default_factory=list)


@dataclass
class Workflow:
    """A named workflow composed of stages with dependency edges."""

    name: str
    stages: list[Stage] = field(default_factory=list)

    @property
    def edges(self) -> dict[str, list[str]]:
        """Dependency edges: stage_name -> list of upstream stage names."""
        return {s.name: list(s.depends_on) for s in self.stages}

    def validate(self) -> list[str]:
        """Validate the workflow DAG. Returns a list of error strings (empty if valid)."""
        errors = []
        stage_names = {s.name for s in self.stages}

        seen: set[str] = set()
        for s in self.stages:
            if s.name in seen:
                errors.append(f"Duplicate stage name: {s.name}")
            seen.add(s.name)

        for s in self.stages:
            for dep in s.depends_on:
                if dep not in stage_names:
                    errors.append(
                        f"Stage '{s.name}' depends on unknown stage '{dep}'"
                    )

        if not errors:
            try:
                topological_sort(self.stages)
            except ValueError as exc:
                errors.append(str(exc))

        return errors


def topological_sort(stages: list[Stage]) -> list[Stage]:
    """Kahn's algorithm -- returns stages in dependency order.

    Raises ValueError if the graph contains a cycle.
    """
    stage_map = {s.name: s for s in stages}
    in_degree: dict[str, int] = {s.name: 0 for s in stages}
    dependents: dict[str, list[str]] = defaultdict(list)

    for s in stages:
        for dep in s.depends_on:
            dependents[dep].append(s.name)
            in_degree[s.name] += 1

    queue = deque(
        name for name, deg in in_degree.items() if deg == 0
    )
    result: list[Stage] = []

    while queue:
        name = queue.popleft()
        result.append(stage_map[name])
        for dependent in dependents[name]:
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)

    if len(result) != len(stages):
        raise ValueError("Workflow contains a cycle in its dependency graph")

    return result


@dataclass
class StageResult:
    """Execution result for a single workflow stage."""

    stage_name: str
    status: StageStatus
    started_at: str | None = None
    finished_at: str | None = None
    output: Any = None
    error: str | None = None


class WorkflowRun:
    """Tracks the state of a single workflow execution."""

    def __init__(
        self,
        workflow: Workflow,
        work_item: str,
        fail_fast: bool = True,
    ):
        self.id: str = str(uuid.uuid4())[:8]
        self.workflow = workflow
        self.work_item = work_item
        self.fail_fast = fail_fast
        self.created_at: str = datetime.now(timezone.utc).isoformat()
        self.finished_at: str | None = None
        self.stage_results: dict[str, StageResult] = {}
        self._lock = threading.Lock()

        for stage in workflow.stages:
            self.stage_results[stage.name] = StageResult(
                stage_name=stage.name,
                status=StageStatus.PENDING,
            )

    @property
    def status(self) -> str:
        statuses = {r.status for r in self.stage_results.values()}
        if StageStatus.RUNNING in statuses:
            return "running"
        if StageStatus.FAILED in statuses:
            return "failed"
        if all(
            s in (StageStatus.COMPLETED, StageStatus.SKIPPED)
            for s in statuses
        ):
            return "completed"
        if StageStatus.PENDING in statuses:
            return "pending"
        return "unknown"

    def to_dict(self) -> dict:
        with self._lock:
            return {
                "workflow_id": self.id,
                "workflow_name": self.workflow.name,
                "work_item": self.work_item,
                "status": self.status,
                "fail_fast": self.fail_fast,
                "created_at": self.created_at,
                "finished_at": self.finished_at,
                "stages": {
                    name: {
                        "status": r.status.value,
                        "started_at": r.started_at,
                        "finished_at": r.finished_at,
                        "output": r.output,
                        "error": r.error,
                    }
                    for name, r in self.stage_results.items()
                },
            }


class WorkflowRunner:
    """Executes workflow DAGs, running independent stages in parallel.

    Parameters
    ----------
    dispatch_fn : callable(work_item, skill, agent, metadata) -> dict
        A *blocking* function that dispatches a single job and returns its
        result dict once the job finishes.
    """

    def __init__(self, dispatch_fn: Callable[..., dict]):
        self._dispatch_fn = dispatch_fn
        self._runs: dict[str, WorkflowRun] = {}
        self._lock = threading.Lock()

    def start(
        self,
        workflow: Workflow,
        work_item: str,
        fail_fast: bool = True,
    ) -> WorkflowRun:
        """Validate and begin executing a workflow. Returns immediately."""
        errors = workflow.validate()
        if errors:
            raise ValueError(f"Invalid workflow: {'; '.join(errors)}")

        run = WorkflowRun(workflow, work_item, fail_fast)
        with self._lock:
            self._runs[run.id] = run

        threading.Thread(
            target=self._execute, args=(run,), daemon=True
        ).start()
        return run

    def get_run(self, workflow_id: str) -> WorkflowRun | None:
        return self._runs.get(workflow_id)

    def list_runs(self) -> list[dict]:
        return [r.to_dict() for r in self._runs.values()]

    # ------------------------------------------------------------------

    def _execute(self, run: WorkflowRun):
        """Drive the DAG: launch stages whose deps are satisfied, wait, repeat."""
        sorted_stages = topological_sort(run.workflow.stages)
        stage_map = {s.name: s for s in sorted_stages}

        # downstream dependents of each stage
        dependents: dict[str, list[str]] = defaultdict(list)
        for s in sorted_stages:
            for dep in s.depends_on:
                dependents[dep].append(s.name)

        # in-degree counter (protected by run._lock)
        in_degree = {s.name: len(s.depends_on) for s in sorted_stages}

        failed = threading.Event()
        active_threads: list[threading.Thread] = []

        def _run_stage(stage_name: str):
            stage = stage_map[stage_name]

            # If a prior stage failed and we are in fail-fast mode, skip.
            if failed.is_set() and run.fail_fast:
                with run._lock:
                    run.stage_results[stage_name].status = StageStatus.SKIPPED
                _unlock_dependents(stage_name)
                return

            # Check that all dependencies actually completed (not failed/skipped).
            with run._lock:
                deps_ok = all(
                    run.stage_results[d].status == StageStatus.COMPLETED
                    for d in stage.depends_on
                )
            if not deps_ok:
                with run._lock:
                    run.stage_results[stage_name].status = StageStatus.SKIPPED
                _unlock_dependents(stage_name)
                return

            # Collect outputs from upstream stages.
            upstream_outputs: dict[str, Any] = {}
            with run._lock:
                for dep in stage.depends_on:
                    dep_result = run.stage_results[dep]
                    if dep_result.output is not None:
                        upstream_outputs[dep] = dep_result.output

            now = datetime.now(timezone.utc).isoformat()
            with run._lock:
                run.stage_results[stage_name].status = StageStatus.RUNNING
                run.stage_results[stage_name].started_at = now

            try:
                stage_work_item = run.work_item
                if upstream_outputs:
                    stage_work_item = json.dumps({
                        "work_item": run.work_item,
                        "upstream_outputs": upstream_outputs,
                    })

                result = self._dispatch_fn(
                    work_item=stage_work_item,
                    skill=stage.skill,
                    agent=stage.agent,
                    metadata={
                        "workflow_id": run.id,
                        "stage": stage_name,
                    },
                )

                finished = datetime.now(timezone.utc).isoformat()
                with run._lock:
                    run.stage_results[stage_name].status = StageStatus.COMPLETED
                    run.stage_results[stage_name].finished_at = finished
                    run.stage_results[stage_name].output = result

            except Exception as exc:
                finished = datetime.now(timezone.utc).isoformat()
                with run._lock:
                    run.stage_results[stage_name].status = StageStatus.FAILED
                    run.stage_results[stage_name].finished_at = finished
                    run.stage_results[stage_name].error = str(exc)
                failed.set()

            _unlock_dependents(stage_name)

        def _unlock_dependents(stage_name: str):
            """Decrement in-degree for downstream stages; launch any that hit zero."""
            for dep_name in dependents.get(stage_name, []):
                launch = False
                with run._lock:
                    in_degree[dep_name] -= 1
                    if in_degree[dep_name] == 0:
                        launch = True
                if launch:
                    t = threading.Thread(
                        target=_run_stage, args=(dep_name,), daemon=True
                    )
                    with run._lock:
                        active_threads.append(t)
                    t.start()

        # Kick off all root stages (no dependencies).
        roots = [s.name for s in sorted_stages if in_degree[s.name] == 0]
        for stage_name in roots:
            t = threading.Thread(
                target=_run_stage, args=(stage_name,), daemon=True
            )
            active_threads.append(t)
            t.start()

        # Wait until every spawned thread has finished.
        while True:
            with run._lock:
                snapshot = list(active_threads)
            if all(not t.is_alive() for t in snapshot):
                # Re-check in case a thread spawned another just before dying.
                with run._lock:
                    if len(active_threads) == len(snapshot):
                        break
            time.sleep(0.1)

        run.finished_at = datetime.now(timezone.utc).isoformat()


# ------------------------------------------------------------------
# YAML loading helpers
# ------------------------------------------------------------------

def load_workflow(path: str) -> Workflow:
    """Load a single workflow definition from a YAML file."""
    import yaml

    with open(path) as fh:
        data = yaml.safe_load(fh)

    stages: list[Stage] = []
    for entry in data.get("stages", []):
        stages.append(
            Stage(
                name=entry["name"],
                skill=entry["skill"],
                agent=entry.get("agent", "claude"),
                depends_on=entry.get("depends_on", []),
            )
        )

    return Workflow(name=data["name"], stages=stages)


def load_all_workflows(directory: str) -> dict[str, Workflow]:
    """Load every *.yaml / *.yml workflow file from *directory*."""
    workflows: dict[str, Workflow] = {}
    dirpath = Path(directory)
    if not dirpath.exists():
        return workflows

    for pattern in ("*.yaml", "*.yml"):
        for yaml_file in sorted(dirpath.glob(pattern)):
            try:
                wf = load_workflow(str(yaml_file))
                if wf.name not in workflows:
                    workflows[wf.name] = wf
            except Exception:
                continue

    return workflows
