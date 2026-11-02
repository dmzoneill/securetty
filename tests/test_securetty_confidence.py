"""Behaviour tests for securetty_confidence.py: scores, thresholds, adjustments and the CLI."""

import sqlite3
from datetime import datetime, timedelta, timezone

import pytest
from conftest import golden, load_script

NOW = datetime(2026, 6, 15, 12, 0, tzinfo=timezone.utc)

# agent, workdir, exit_code, duration_seconds, age_days
SESSIONS = [
    *[("claude", "/r/alpha", 0, 120, d) for d in (0, 1, 2, 3, 4, 20)],
    ("claude", "/r/beta", 1, 900, 1),
    ("claude", "/r/beta", 2, 1500, 2),
    ("claude", "/r/beta", 0, 300, 30),
    *[("gemini", "/r/alpha", 0 if d % 3 else 1, 700, d) for d in range(6)],
    ("gemini", "/r/gamma", 0, 50, 40),
    ("codex", "/r/beta", 0, 10, 1),
    ("codex", "/r/beta", 137, 2400, 2),
    ("codex", "/r/alpha", 0, 10, 3),
    # unparseable and timezone-naive timestamps
    ("codex", "/r/gamma", 3, 10, "not a date"),
    ("codex", "/r/gamma", 0, 10, "2026-06-15T11:00:00"),
]


class FrozenDatetime(datetime):
    """datetime whose now() is fixed at NOW."""

    @classmethod
    def now(cls, tz=None):
        """Return the frozen time."""
        return NOW if tz else NOW.replace(tzinfo=None)


def _create_db(path, sessions):
    """Create a failure database containing the given sessions."""
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE sessions (timestamp TEXT, agent TEXT, exit_code INTEGER,
           duration_seconds INTEGER, workdir TEXT)""",
    )
    for agent, workdir, code, duration, age in sessions:
        stamp = age
        if not isinstance(age, str):
            stamp = (NOW - timedelta(days=age, hours=1)).isoformat()
        conn.execute(
            "INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
            (stamp, agent, code, duration, workdir),
        )
    conn.commit()
    conn.close()


def _load(tmp_path, monkeypatch, sessions=None):
    """Load the module against a temporary database with a frozen clock."""
    db = tmp_path / "failures.db"
    if sessions is not None:
        _create_db(db, sessions)
    monkeypatch.setenv("SECURETTY_FAILURE_DB", str(db))
    module = load_script("roles/containers/files/securetty_confidence.py", "confidence")
    monkeypatch.setattr(module, "datetime", FrozenDatetime)
    return module


@pytest.fixture(name="conf")
def fixture_conf(tmp_path, monkeypatch):
    """The confidence module backed by the SESSIONS database."""
    return _load(tmp_path, monkeypatch, SESSIONS)


CLI_CASES = [
    (["score", "claude"], "confidence_score_claude.txt"),
    (["score", "claude", "/r/beta"], "confidence_score_claude_beta.txt"),
    (["score", "codex", "/r/beta", "--json"], "confidence_score_codex_beta.json"),
    (["score", "nobody"], "confidence_score_nobody.txt"),
    (["score", "gemini", "/r/alpha"], "confidence_score_gemini_alpha.txt"),
    (["threshold"], "confidence_threshold.txt"),
    (["threshold", "--json"], "confidence_threshold.json"),
    (["adjust"], "confidence_adjust.txt"),
    (["adjust", "--json"], "confidence_adjust.json"),
    (["report"], "confidence_report.txt"),
    (["--score", "claude", "/r/alpha"], "confidence_legacy_score.txt"),
    (["--score", "codex", "--json"], "confidence_legacy_score.json"),
    (["--threshold"], "confidence_threshold.txt"),
    (["--threshold", "--json"], "confidence_threshold.json"),
    (["--adjust"], "confidence_adjust.txt"),
    (["--adjust", "--json"], "confidence_adjust.json"),
    (["--report"], "confidence_report.txt"),
]


@pytest.mark.parametrize(("argv", "name"), CLI_CASES)
def test_cli_output(conf, monkeypatch, capsys, argv, name):
    """Every subcommand and legacy flag prints the same output as before."""
    monkeypatch.setattr("sys.argv", ["securetty_confidence.py", *argv])
    conf.main()
    assert capsys.readouterr().out == golden(name)


def test_no_command_prints_help_and_exits(conf, monkeypatch, capsys):
    """Without a command or flag the help is printed and the exit status is 1."""
    monkeypatch.setattr("sys.argv", ["securetty_confidence.py"])
    with pytest.raises(SystemExit) as exc:
        conf.main()
    assert exc.value.code == 1
    assert capsys.readouterr().out.startswith("usage:")


def test_missing_sessions_table_exits(tmp_path, monkeypatch, capsys):
    """A database without a sessions table is reported and exits with status 1."""
    db = tmp_path / "failures.db"
    sqlite3.connect(db).close()
    module = _load(tmp_path, monkeypatch)
    monkeypatch.setattr("sys.argv", ["securetty_confidence.py", "report"])
    with pytest.raises(SystemExit) as exc:
        module.main()
    assert exc.value.code == 1
    assert "sessions table not found" in capsys.readouterr().err


def test_new_database_is_initialised(tmp_path, monkeypatch, capsys):
    """A missing database is created empty and the report says there is no data."""
    module = _load(tmp_path, monkeypatch)
    monkeypatch.setattr("sys.argv", ["securetty_confidence.py", "--report"])
    module.main()
    captured = capsys.readouterr()
    assert captured.err.startswith("Initialized empty failure database at ")
    expected = "No session data available. "
    expected += "Run securetty_failure_db.py --ingest first.\n"
    assert captured.out == expected


def test_empty_database_defaults(tmp_path, monkeypatch, capsys):
    """With no sessions every command falls back to the default threshold."""
    module = _load(tmp_path, monkeypatch, [])
    # Text-mode "adjust" is not exercised here: it raises KeyError when there
    # are no recent sessions (reported separately as a pre-existing bug).
    for argv in (["threshold"], ["adjust", "--json"], ["score", "x", "/r"]):
        monkeypatch.setattr("sys.argv", ["securetty_confidence.py", *argv])
        module.main()
    assert capsys.readouterr().out == golden("confidence_empty.txt")


MOSTLY_OK = [("a", "/r", 0 if d else 1, 10, d % 6) for d in range(10)]


@pytest.mark.parametrize(
    ("sessions", "threshold", "suggestion"),
    [
        (MOSTLY_OK, 0.99, "relax"),
        (SESSIONS, 0.0, "tighten"),
        (SESSIONS, 0.5, "no_change"),
    ],
)
def test_adjustment_suggestions(tmp_path, monkeypatch, sessions, threshold, suggestion):
    """Each adjustment branch produces the same result as before."""
    module = _load(tmp_path, monkeypatch, sessions)
    info = {"recommended_threshold": threshold}
    monkeypatch.setattr(module, "compute_threshold", lambda conn: info)
    conn = module.get_db()
    result = module.compute_adjustment(conn)
    conn.close()
    assert result["suggestion"] == suggestion
    assert repr(result) + "\n" == golden(f"confidence_adjust_{suggestion}.txt")


def test_old_sessions_only(tmp_path, monkeypatch):
    """Sessions older than 7 days give no adjustment data."""
    module = _load(tmp_path, monkeypatch, [("a", "/r", 0, 10, 30)])
    conn = module.get_db()
    result = module.compute_adjustment(conn)
    conn.close()
    assert result == {
        "current_threshold": 0.9,
        "suggestion": "no_change",
        "reason": "No recent sessions to analyze (last 7 days).",
        "recent_sessions": 0,
    }
