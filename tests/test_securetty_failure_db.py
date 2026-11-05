"""Behaviour tests for securetty_failure_db.py: ingest, report and suggest output."""

import json
import os
import sqlite3

from conftest import ExpectExit, golden, load_script

SESSIONS = [
    # crit: 4/4 failures, long runs, one workdir -> critical, timeout, workdir-specific
    *[
        {
            "timestamp": f"2026-01-0{i}T00:00:00Z",
            "agent": "crit",
            "exit_code": 2,
            "duration_seconds": 900,
            "workdir": "/w/one",
            "session_id": f"c{i}",
        }
        for i in range(1, 5)
    ],
    # high: 3/5 failures across two workdirs -> high
    *[
        {
            "timestamp": f"2026-02-0{i}T00:00:00Z",
            "agent": "high",
            "exit_code": 1 if i <= 3 else 0,
            "duration_seconds": 30,
            "workdir": f"/w/{i % 2}",
            "session_id": f"h{i}",
        }
        for i in range(1, 6)
    ],
    # elev: 2/5 failures -> elevated
    *[
        {
            "timestamp": f"2026-03-0{i}T00:00:00Z",
            "agent": "elev",
            "exit_code": 3 if i <= 2 else 0,
            "duration_seconds": 10,
            "workdir": f"/w/{i}",
            "session_id": f"e{i}",
        }
        for i in range(1, 6)
    ],
    # ok: never fails
    {
        "timestamp": "2026-04-01T00:00:00Z",
        "agent": "ok",
        "exit_code": 0,
        "duration_seconds": 5,
        "workdir": "/w/ok",
        "session_id": "o1",
    },
]


def _fdb(request):
    """Load the module with its database and outcomes directory under tmp_path."""
    tmp_path = request.getfixturevalue("tmp_path")
    monkeypatch = request.getfixturevalue("monkeypatch")
    monkeypatch.setenv("SECURETTY_FAILURE_DB", str(tmp_path / "db" / "failures.db"))
    outcomes = tmp_path / "outcomes"
    outcomes.mkdir()
    monkeypatch.setenv("SECURETTY_OUTCOMES_DIR", str(outcomes))
    lines = [json.dumps(s) for s in SESSIONS[:8]]
    lines += ["", "not json"]
    (outcomes / "a.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")
    rest = [json.dumps(s) for s in SESSIONS[8:]] + [json.dumps(SESSIONS[0])]
    (outcomes / "b.jsonl").write_text("\n".join(rest) + "\n", encoding="utf-8")
    module = load_script("roles/containers/files/securetty_failure_db.py", "failure_db")
    conn = module.get_db()
    module.init_db(conn)
    request.addfinalizer(conn.close)
    return module, conn


def test_ingest_counts_and_rows(request, capsys):
    """Ingest imports valid rows, skips bad JSON and duplicates, and logs each file."""
    fdb = _fdb(request)
    module, conn = fdb
    module.ingest(conn)
    out = capsys.readouterr().out
    expected = "Ingestion complete: 15 new entries imported, "
    expected += "2 skipped (duplicates/errors).\n"
    assert out == expected
    assert conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 15
    log_sql = "SELECT lines_imported, lines_skipped FROM ingestion_log ORDER BY id"
    log = conn.execute(log_sql).fetchall()
    assert [tuple(r) for r in log] == [(8, 1), (7, 1)]


def test_ingest_patterns(request):
    """Pattern aggregates are recomputed after ingest."""
    fdb = _fdb(request)
    module, conn = fdb
    module.ingest(conn)
    rows = conn.execute(
        "SELECT agent, total_sessions, total_failures, failure_rate, avg_duration_seconds, most_common_workdir "
        "FROM patterns ORDER BY agent",
    ).fetchall()
    assert [tuple(r) for r in rows] == [
        ("crit", 4, 4, 100.0, 900.0, "/w/one"),
        ("elev", 5, 2, 40.0, 10.0, rows[1][5]),
        ("high", 5, 3, 60.0, 30.0, "/w/1"),
        ("ok", 1, 0, 0.0, 5.0, "/w/ok"),
    ]


def test_ingest_missing_dir_exits(request, monkeypatch, tmp_path, capsys):
    """A missing outcomes directory exits with status 1."""
    fdb = _fdb(request)
    module, conn = fdb
    monkeypatch.setattr(module, "OUTCOMES_DIR", str(tmp_path / "missing"))
    with ExpectExit() as exc:
        module.ingest(conn)
    assert exc.value.code == 1
    assert "No outcomes directory" in capsys.readouterr().err


def test_ingest_no_files_exits(request, monkeypatch, tmp_path, capsys):
    """An empty outcomes directory exits with status 1."""
    fdb = _fdb(request)
    module, conn = fdb
    empty = tmp_path / "empty"
    empty.mkdir()
    monkeypatch.setattr(module, "OUTCOMES_DIR", str(empty))
    with ExpectExit() as exc:
        module.ingest(conn)
    assert exc.value.code == 1
    assert capsys.readouterr().err == "No JSONL files found.\n"


def test_report_output(request, capsys):
    """The report output is unchanged."""
    fdb = _fdb(request)
    module, conn = fdb
    module.ingest(conn)
    capsys.readouterr()
    module.report(conn)
    assert capsys.readouterr().out == golden("failure_db_report.txt")


def test_suggest_output(request, capsys):
    """The suggestion output is unchanged for critical, high and elevated agents."""
    fdb = _fdb(request)
    module, conn = fdb
    module.ingest(conn)
    capsys.readouterr()
    module.suggest(conn)
    assert capsys.readouterr().out == golden("failure_db_suggest.txt")


def test_empty_database_messages(request, capsys):
    """Report and suggest handle an empty database."""
    fdb = _fdb(request)
    module, conn = fdb
    module.report(conn)
    module.suggest(conn)
    out = capsys.readouterr().out
    assert "No pattern data available. Run --ingest first." in out
    assert out.endswith(
        "No agents exceed the failure threshold. No suggestions to make.\n",
    )


def test_main_requires_an_action(monkeypatch):
    """main() exits with status 1 when no action flag is given."""
    module = load_script(
        "roles/containers/files/securetty_failure_db.py",
        "failure_db_main",
    )
    monkeypatch.setattr("sys.argv", ["securetty_failure_db.py"])
    with ExpectExit() as exc:
        module.main()
    assert exc.value.code == 1


def test_main_runs_report(request, monkeypatch, capsys):
    """main() opens the database and dispatches --report."""
    fdb = _fdb(request)
    module, _ = fdb
    monkeypatch.setattr("sys.argv", ["securetty_failure_db.py", "--report"])
    module.main()
    assert "securetty failure database report" in capsys.readouterr().out
    assert os.path.isfile(module.DB_PATH)
    check = sqlite3.connect(module.DB_PATH)
    assert check.execute("SELECT COUNT(*) FROM sessions").fetchone()[0] == 0
    check.close()
