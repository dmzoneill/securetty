#!/usr/bin/env python3
"""securetty failure database — ingest session outcomes, detect patterns, suggest fixes.

Reads JSONL outcome files into a SQLite database for persistent failure analysis.
Tracks ingestion state to avoid re-importing entries on subsequent runs.

Usage:
    securetty_failure_db.py --ingest   Import new JSONL entries since last run
    securetty_failure_db.py --report   Query patterns and output summary
    securetty_failure_db.py --suggest  Suggest SKILL.md edits for high-failure agents
"""

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

DB_PATH = os.environ.get(
    "SECURETTY_FAILURE_DB",
    os.path.expanduser("~/.securetty/failures.db"),
)
OUTCOMES_DIR = os.environ.get(
    "SECURETTY_OUTCOMES_DIR",
    os.path.expanduser("~/.securetty/outcomes"),
)
FAILURE_THRESHOLD = 30.0  # percent


def get_db() -> sqlite3.Connection:
    """Open or create the failure database."""
    db_dir = os.path.dirname(DB_PATH)
    os.makedirs(db_dir, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    """Create tables if they do not exist."""
    conn.execute("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            agent TEXT NOT NULL,
            exit_code INTEGER NOT NULL,
            duration_seconds INTEGER NOT NULL,
            workdir TEXT NOT NULL,
            session_id TEXT NOT NULL,
            source_file TEXT NOT NULL,
            ingested_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_dedup
        ON sessions (timestamp, agent, session_id)
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS patterns (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT NOT NULL,
            total_sessions INTEGER NOT NULL,
            total_failures INTEGER NOT NULL,
            failure_rate REAL NOT NULL,
            avg_duration_seconds REAL NOT NULL,
            most_common_workdir TEXT,
            updated_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_patterns_agent
        ON patterns (agent)
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ingestion_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_file TEXT NOT NULL,
            lines_imported INTEGER NOT NULL,
            lines_skipped INTEGER NOT NULL,
            ingested_at TEXT NOT NULL
        )
    """)
    conn.commit()


def _read_jsonl(path: Path) -> tuple[list[dict], int]:
    """Parse a JSONL file, returning the decoded entries and the count of invalid lines."""
    entries: list[dict] = []
    invalid = 0
    with open(path, encoding="utf-8") as handle:
        raw_lines = [raw.strip() for raw in handle]
    for raw in filter(None, raw_lines):
        try:
            entries.append(json.loads(raw))
        except json.JSONDecodeError:
            invalid += 1
    return entries, invalid


def _insert_session(
    conn: sqlite3.Connection,
    entry: dict,
    fname: str,
    now: str,
) -> bool:
    """Insert one session row; return False if it is a duplicate."""
    row = (
        entry.get("timestamp", ""),
        entry.get("agent", "unknown"),
        entry.get("exit_code", 0),
        entry.get("duration_seconds", 0),
        entry.get("workdir", "unknown"),
        entry.get("session_id", ""),
        fname,
        now,
    )
    try:
        conn.execute(
            """INSERT INTO sessions
               (timestamp, agent, exit_code, duration_seconds, workdir,
                session_id, source_file, ingested_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            row,
        )
    except sqlite3.IntegrityError:
        return False
    return True


def _ingest_file(
    conn: sqlite3.Connection,
    jsonl_file: Path,
    now: str,
) -> tuple[int, int]:
    """Import one JSONL file and log it; return (imported, skipped)."""
    fname = str(jsonl_file)
    entries, skipped = _read_jsonl(jsonl_file)
    imported = 0
    for entry in entries:
        if _insert_session(conn, entry, fname, now):
            imported += 1
        else:
            skipped += 1
    conn.execute(
        "INSERT INTO ingestion_log (source_file, lines_imported, lines_skipped, ingested_at) VALUES (?, ?, ?, ?)",
        (fname, imported, skipped, now),
    )
    return imported, skipped


def ingest(conn: sqlite3.Connection) -> None:
    """Import new JSONL entries since last run."""
    outcomes_path = Path(OUTCOMES_DIR)
    if not outcomes_path.is_dir():
        print(f"No outcomes directory at {OUTCOMES_DIR}", file=sys.stderr)
        sys.exit(1)

    jsonl_files = sorted(outcomes_path.glob("*.jsonl"))
    if not jsonl_files:
        print("No JSONL files found.", file=sys.stderr)
        sys.exit(1)

    now = datetime.now(timezone.utc).isoformat()
    total_imported = 0
    total_skipped = 0
    for jsonl_file in jsonl_files:
        imported, skipped = _ingest_file(conn, jsonl_file, now)
        total_imported += imported
        total_skipped += skipped

    # Refresh pattern aggregates
    _refresh_patterns(conn)

    conn.commit()
    print(
        f"Ingestion complete: {total_imported} new entries imported, {total_skipped} skipped (duplicates/errors).",
    )


def _refresh_patterns(conn: sqlite3.Connection) -> None:
    """Recompute the patterns table from all sessions."""
    now = datetime.now(timezone.utc).isoformat()
    conn.execute("DELETE FROM patterns")

    rows = conn.execute("""
        SELECT
            agent,
            COUNT(*) as total,
            SUM(CASE WHEN exit_code != 0 THEN 1 ELSE 0 END) as failures,
            AVG(duration_seconds) as avg_dur
        FROM sessions
        GROUP BY agent
    """).fetchall()

    for row in rows:
        agent = row["agent"]
        total = row["total"]
        failures = row["failures"]
        rate = (failures / total * 100) if total > 0 else 0
        avg_dur = row["avg_dur"] or 0

        # Find most common workdir for this agent
        wd_row = conn.execute(
            "SELECT workdir, COUNT(*) as c FROM sessions WHERE agent=? GROUP BY workdir ORDER BY c DESC LIMIT 1",
            (agent,),
        ).fetchone()
        most_common_wd = wd_row["workdir"] if wd_row else ""

        conn.execute(
            """INSERT INTO patterns (agent, total_sessions, total_failures, failure_rate,
               avg_duration_seconds, most_common_workdir, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                agent,
                total,
                failures,
                round(rate, 1),
                round(avg_dur, 1),
                most_common_wd,
                now,
            ),
        )


def report(conn: sqlite3.Connection) -> None:
    """Query patterns and output a summary report."""
    total_row = conn.execute("SELECT COUNT(*) as c FROM sessions").fetchone()
    fail_row = conn.execute(
        "SELECT COUNT(*) as c FROM sessions WHERE exit_code != 0",
    ).fetchone()
    total = total_row["c"]
    failures = fail_row["c"]
    rate = (failures / total * 100) if total > 0 else 0

    print("=" * 60)
    print("securetty failure database report")
    print("=" * 60)
    print(f"Total sessions:       {total}")
    print(f"Total failures:       {failures}")
    print(f"Overall failure rate: {rate:.1f}%")
    print()

    patterns = conn.execute(
        "SELECT * FROM patterns ORDER BY failure_rate DESC",
    ).fetchall()

    if not patterns:
        print("No pattern data available. Run --ingest first.")
        return

    print("-" * 60)
    print("Agent failure patterns:")
    print("-" * 60)
    print(f"{'Agent':<20} {'Total':>8} {'Fail':>8} {'Rate':>8} {'Avg(s)':>8}")
    for p in patterns:
        marker = " !!!" if p["failure_rate"] > FAILURE_THRESHOLD else ""
        print(
            f"{p['agent']:<20} {p['total_sessions']:>8} {p['total_failures']:>8} "
            f"{p['failure_rate']:>7.1f}% {p['avg_duration_seconds']:>8.1f}{marker}"
        )
    print()

    # High-failure agents
    high_failure = [p for p in patterns if p["failure_rate"] > FAILURE_THRESHOLD]
    if high_failure:
        print("-" * 60)
        print(f"HIGH FAILURE AGENTS (>{FAILURE_THRESHOLD:.0f}% failure rate):")
        print("-" * 60)
        for p in high_failure:
            print(
                f"  {p['agent']}: {p['failure_rate']}% failure rate "
                f"({p['total_failures']}/{p['total_sessions']} sessions, "
                f"common workdir: {p['most_common_workdir']})"
            )
        print()

    # Recent failures
    recent = conn.execute(
        "SELECT * FROM sessions WHERE exit_code != 0 ORDER BY timestamp DESC LIMIT 10",
    ).fetchall()
    if recent:
        print("-" * 60)
        print("Recent failures (last 10):")
        print("-" * 60)
        for r in recent:
            print(
                f"  {r['timestamp']}  agent={r['agent']}  exit={r['exit_code']} "
                f" dur={r['duration_seconds']}s "
                f" workdir={r['workdir']}"
            )
        print()

    print("=" * 60)


RATE_SUGGESTIONS = {
    "CRITICAL": [
        "     Consider adding a pre-flight check to the agent's SKILL.md",
        "     that validates the working environment before starting work.",
        "",
        "  2. Add an explicit error-handling section to the skill definition:",
        "     ---",
        "     ## Error Recovery",
        "     If the initial approach fails, try:",
        "     - Verify all required tools are installed",
        "     - Check connectivity to required services",
        "     - Fall back to a simpler implementation strategy",
        "     ---",
    ],
    "HIGH": [
        "     Add guardrails to the SKILL.md prompt:",
        "     ---",
        "     ## Prerequisites",
        "     Before starting, verify:",
        "     - Required dependencies are available",
        "     - Working directory is a valid git repository",
        "     - Network access to required endpoints is confirmed",
        "     ---",
    ],
    "ELEVATED": [
        "     Consider adding retry guidance to the SKILL.md:",
        "     ---",
        "     ## On Failure",
        "     If a step fails:",
        "     - Log the error context for retrospective analysis",
        "     - Attempt one retry with adjusted parameters",
        "     - If still failing, exit cleanly with diagnostic output",
        "     ---",
    ],
}

TIMEOUT_SUGGESTION = [
    "     Add a timeout clause to the SKILL.md:",
    "     ---",
    "     ## Timeout",
    "     If the task is not complete within 10 minutes,",
    "     save progress and exit with a partial result.",
    "     ---",
]


def _print_lines(lines: list[str]) -> None:
    """Print each line in order."""
    for line in lines:
        print(line)


def _failure_breakdown(conn: sqlite3.Connection, agent: str) -> tuple[list, list]:
    """Return the top failure workdirs and the exit code distribution for an agent."""
    wd_rows = conn.execute(
        """SELECT workdir, COUNT(*) as c
           FROM sessions
           WHERE agent=? AND exit_code != 0
           GROUP BY workdir
           ORDER BY c DESC
           LIMIT 5""",
        (agent,),
    ).fetchall()
    ec_rows = conn.execute(
        """SELECT exit_code, COUNT(*) as c
           FROM sessions
           WHERE agent=? AND exit_code != 0
           GROUP BY exit_code
           ORDER BY c DESC""",
        (agent,),
    ).fetchall()
    return wd_rows, ec_rows


def _print_agent_summary(p: sqlite3.Row, wd_rows: list, ec_rows: list) -> None:
    """Print an agent's failure statistics."""
    print("-" * 60)
    print(f"Agent: {p['agent']}")
    print(
        f"  Failure rate: {p['failure_rate']}% ({p['total_failures']}/{p['total_sessions']} sessions)",
    )
    print(f"  Avg duration: {p['avg_duration_seconds']}s")
    print(f"  Common workdir: {p['most_common_workdir']}")
    print()
    if ec_rows:
        print("  Exit code distribution:")
        for ec in ec_rows:
            print(f"    exit_code={ec['exit_code']}: {ec['c']} occurrences")
        print()
    if wd_rows:
        print("  Top failure workdirs:")
        for wd in wd_rows:
            print(f"    {wd['workdir']}: {wd['c']} failures")
        print()


def _print_agent_suggestions(
    agent: str,
    rate: float,
    avg_dur: float,
    wd_rows: list,
) -> None:
    """Print the SKILL.md suggestions for one agent."""
    print("  Suggested SKILL.md changes:")
    print()
    if rate > 70:
        level = "CRITICAL"
    elif rate > 50:
        level = "HIGH"
    else:
        level = "ELEVATED"
    print(f"  1. {level}: {agent} fails in >{rate:.0f}% of sessions.")
    _print_lines(RATE_SUGGESTIONS[level])

    # Duration-based suggestions
    if avg_dur > 600:
        print()
        print(f"  2. TIMEOUT RISK: Average duration is {avg_dur:.0f}s (>{600}s).")
        _print_lines(TIMEOUT_SUGGESTION)

    # Workdir-specific suggestions
    if wd_rows and len(wd_rows) == 1:
        print()
        print(f"  3. WORKDIR-SPECIFIC: All failures occur in {wd_rows[0]['workdir']}.")
        print(
            "     This may indicate a repo-specific issue rather than a skill problem.",
        )
        print("     Check the repo's CLAUDE.md or .claude/ configuration.")
    print()


def suggest(conn: sqlite3.Connection) -> None:
    """Suggest SKILL.md edits for agents with high failure rates."""
    patterns = conn.execute(
        "SELECT * FROM patterns WHERE failure_rate > ? ORDER BY failure_rate DESC",
        (FAILURE_THRESHOLD,),
    ).fetchall()

    if not patterns:
        print("No agents exceed the failure threshold. No suggestions to make.")
        return

    print("=" * 60)
    print("SKILL.md improvement suggestions")
    print("=" * 60)
    print()
    print(f"Agents with >{FAILURE_THRESHOLD:.0f}% failure rate need attention.")
    print("These suggestions should be reviewed and applied manually.")
    print()

    for p in patterns:
        wd_rows, ec_rows = _failure_breakdown(conn, p["agent"])
        _print_agent_summary(p, wd_rows, ec_rows)
        _print_agent_suggestions(
            p["agent"],
            p["failure_rate"],
            p["avg_duration_seconds"],
            wd_rows,
        )

    print("=" * 60)
    print("To apply changes, edit the relevant SKILL.md files manually.")
    print("Skill definitions are typically in the agent's working directory")
    print("under .claude/skills/ or in the securetty configuration.")
    print("=" * 60)


def main():
    """Parse command-line arguments and run the requested failure-db command."""
    parser = argparse.ArgumentParser(
        description="securetty failure database — ingest outcomes, detect patterns, suggest fixes"
    )
    parser.add_argument(
        "--ingest",
        action="store_true",
        help="Import new JSONL entries since last run",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="Query patterns and output summary",
    )
    parser.add_argument(
        "--suggest",
        action="store_true",
        help="Suggest SKILL.md edits for high-failure agents",
    )
    args = parser.parse_args()

    if not any([args.ingest, args.report, args.suggest]):
        parser.print_help()
        sys.exit(1)

    conn = get_db()
    init_db(conn)

    try:
        if args.ingest:
            ingest(conn)
        if args.report:
            report(conn)
        if args.suggest:
            suggest(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
