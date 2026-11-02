"""Behaviour tests for securetty_remediate.py: scan, apply, propagate and changelog."""

import json
import sqlite3
from datetime import datetime, timezone

import pytest
from conftest import golden, load_script

AGENTS = {
    # agent: (sessions, failures, duration, workdirs)
    "crit": (4, 4, 900, ["/w/one"]),
    "high": (5, 3, 30, ["/w/a", "/w/b"]),
    "elev": (5, 2, 10, ["/w/x"]),
    "lonely": (3, 2, 10, ["/w/l"]),
    "ok": (2, 0, 5, ["/w/ok"]),
}

SKILLS = {
    "crit": "",
    "high-query": "",
    "elev-tools": "## Known Issues\nalready\n",
    "lonely-done": "## Known Issues\n\n## Troubleshooting\n",
    "unrelated": "",
}


def _build_db(path):
    """Create a failures database with sessions and patterns for AGENTS."""
    conn = sqlite3.connect(path)
    conn.execute(
        """CREATE TABLE sessions (timestamp TEXT, agent TEXT, exit_code INTEGER,
           duration_seconds INTEGER, workdir TEXT)""",
    )
    conn.execute(
        "CREATE TABLE patterns (agent TEXT, total_sessions INTEGER, total_failures INTEGER, "
        "failure_rate REAL, avg_duration_seconds REAL, most_common_workdir TEXT)",
    )
    for agent, (total, failures, duration, workdirs) in AGENTS.items():
        for i in range(total):
            code = (2 if i % 2 else 137) if i < failures else 0
            conn.execute(
                "INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
                (
                    f"2026-01-01T00:0{i}:00Z",
                    agent,
                    code,
                    duration,
                    workdirs[i % len(workdirs)],
                ),
            )
        conn.execute(
            "INSERT INTO patterns VALUES (?, ?, ?, ?, ?, ?)",
            (
                agent,
                total,
                failures,
                round(failures / total * 100, 1),
                float(duration),
                workdirs[0],
            ),
        )
    conn.commit()
    conn.close()


@pytest.fixture(name="env")
def fixture_env(tmp_path, monkeypatch):
    """Load the module against a temporary database, skills tree and remediation log."""
    db = tmp_path / "failures.db"
    _build_db(db)
    skills = tmp_path / "skills"
    for name, body in SKILLS.items():
        (skills / name).mkdir(parents=True)
        (skills / name / "SKILL.md").write_text(
            f"---\nname: {name}\n---\n# {name}\n{body}",
            encoding="utf-8",
        )
    monkeypatch.setenv("SECURETTY_FAILURE_DB", str(db))
    monkeypatch.setenv("SECURETTY_MCP_SKILLS_DIR", str(skills))
    monkeypatch.setenv("SECURETTY_USER_SKILLS", str(tmp_path / "no-user-skills"))
    monkeypatch.setenv(
        "SECURETTY_REMEDIATIONS_LOG",
        str(tmp_path / "log" / "remediations.jsonl"),
    )
    module = load_script("roles/containers/files/securetty_remediate.py", "remediate")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    yield module, conn, tmp_path
    conn.close()


def _normalise(text, tmp_path):
    """Replace run-specific paths and dates so output can be compared to golden files."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return text.replace(str(tmp_path), "<TMP>").replace(today, "<TODAY>")


def _headings(patch):
    """Return the section headings of a patch."""
    return [s["heading"] for s in patch["sections"]]


def _log_summary(entry):
    """Return the action, skill, sections and dry-run flag of a log entry."""
    return entry["action"], entry["skill"], entry["sections_added"], entry["dry_run"]


def _write_log(tmp_path, entries):
    """Write remediation log entries, plus a blank and an invalid line."""
    log = tmp_path / "log" / "remediations.jsonl"
    log.parent.mkdir(exist_ok=True)
    lines = [json.dumps(e) for e in entries] + ["", "{bad"]
    log.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _read_log(tmp_path):
    """Return the remediation log entries without their timestamps."""
    log = tmp_path / "log" / "remediations.jsonl"
    lines = log.read_text(encoding="utf-8").splitlines()
    entries = [json.loads(line) for line in lines if line.startswith('{"')]
    for entry in entries:
        entry.pop("timestamp")
    return entries


def test_scan_output_and_patches(env, capsys):
    """Scan prints the same report and returns the same patches."""
    module, conn, tmp_path = env
    patches = module.cmd_scan(conn)
    out = _normalise(capsys.readouterr().out, tmp_path)
    assert out == golden("remediate_scan.txt")
    summary = [(p["skill"], p["classification"], _headings(p)) for p in patches]
    assert summary == [
        ("crit", "critical", ["Known Issues", "Troubleshooting"]),
        ("high-query", "high", ["Known Issues", "Troubleshooting"]),
        ("elev-tools", "elevated", ["Troubleshooting"]),
    ]


def test_scan_patch_content(env):
    """Generated section text is unchanged."""
    module, conn, tmp_path = env
    patches = module.cmd_scan(conn)
    content = "".join(s["content"] for p in patches for s in p["sections"])
    assert _normalise(content, tmp_path) == golden("remediate_sections.txt")


def test_scan_nothing_over_threshold(env, monkeypatch, capsys):
    """Scan reports nothing to do when no agent exceeds the threshold."""
    module, conn, _ = env
    monkeypatch.setattr(module, "FAILURE_THRESHOLD", 100.0)
    assert not module.cmd_scan(conn)
    expected = "No agents exceed the 100% failure threshold. Nothing to remediate.\n"
    assert capsys.readouterr().out == expected


def test_apply_without_confirm(env, capsys):
    """Apply without --confirm or --dry-run changes nothing."""
    module, conn, tmp_path = env
    module.cmd_apply(conn)
    out = capsys.readouterr().out
    assert out.endswith(
        "\nUse --confirm to apply patches. Use --dry-run to preview changes.\n",
    )
    assert not (tmp_path / "log").exists()
    assert not list(tmp_path.rglob("*.bak"))


def test_apply_dry_run(env, capsys):
    """A dry-run apply previews changes without writing files or the log."""
    module, conn, tmp_path = env
    module.cmd_apply(conn, dry_run=True)
    out = _normalise(capsys.readouterr().out, tmp_path)
    assert out == golden("remediate_apply_dry_run.txt")
    assert not (tmp_path / "log").exists()


def test_apply_confirm(env, capsys):
    """A confirmed apply patches files, makes backups and logs each patch."""
    module, conn, tmp_path = env
    module.cmd_apply(conn, confirm=True)
    out = _normalise(capsys.readouterr().out, tmp_path)
    assert out == golden("remediate_apply_confirm.txt")
    crit = tmp_path / "skills" / "crit" / "SKILL.md"
    backup = tmp_path / "skills" / "crit" / "SKILL.md.bak"
    assert backup.read_text(encoding="utf-8") == "---\nname: crit\n---\n# crit\n"
    assert "## Known Issues" in crit.read_text(encoding="utf-8")
    entries = _read_log(tmp_path)
    logged = [_log_summary(e) for e in entries]
    assert logged == [
        ("apply", "crit", ["Known Issues", "Troubleshooting"], False),
        ("apply", "high-query", ["Known Issues", "Troubleshooting"], False),
        ("apply", "elev-tools", ["Troubleshooting"], False),
    ]


APPLIED_HIGH = {
    "timestamp": "2026-01-01T00:00:00Z",
    "action": "apply",
    "skill": "other",
    "path": "/elsewhere/SKILL.md",
    "classification": "high",
    "failure_rate": 60.0,
    "sections_added": ["Known Issues"],
    "dry_run": False,
}


def test_propagate_without_log(env, capsys):
    """Propagate needs at least one applied remediation."""
    module, conn, _ = env
    module.cmd_propagate(conn)
    expected = "No remediations have been applied yet. Run --apply --confirm first.\n"
    assert capsys.readouterr().out == expected


def test_propagate_only_dry_runs(env, capsys):
    """Dry-run entries are not propagated."""
    module, conn, tmp_path = env
    _write_log(tmp_path, [dict(APPLIED_HIGH, dry_run=True)])
    module.cmd_propagate(conn)
    assert capsys.readouterr().out == "No completed remediations found to propagate.\n"


def test_propagate_no_targets(env, capsys):
    """Skills already patched are not propagation targets."""
    module, conn, tmp_path = env
    target = str(tmp_path / "skills" / "high-query" / "SKILL.md")
    _write_log(
        tmp_path,
        [APPLIED_HIGH, dict(APPLIED_HIGH, action="propagate", path=target)],
    )
    module.cmd_propagate(conn)
    assert capsys.readouterr().out.endswith(
        "No propagation targets found. All matching skills are patched.\n",
    )


@pytest.mark.parametrize(
    ("kwargs", "name"),
    [
        ({}, "remediate_propagate_preview.txt"),
        ({"dry_run": True}, "remediate_propagate_dry_run.txt"),
        ({"confirm": True}, "remediate_propagate_confirm.txt"),
    ],
)
def test_propagate_modes(env, capsys, kwargs, name):
    """Propagate output for preview, dry-run and confirm modes is unchanged."""
    module, conn, tmp_path = env
    _write_log(tmp_path, [APPLIED_HIGH])
    module.cmd_propagate(conn, **kwargs)
    assert _normalise(capsys.readouterr().out, tmp_path) == golden(name)
    entries = _read_log(tmp_path)
    if kwargs.get("confirm"):
        assert entries[-1]["action"] == "propagate"
        assert entries[-1]["propagated_from"] == "other"
        assert entries[-1]["skill"] == "high-query"
    else:
        assert len(entries) == 1


CHANGELOG = [
    APPLIED_HIGH,
    dict(
        APPLIED_HIGH,
        timestamp="2026-01-01T04:00:00Z",
        skill="crit",
        classification="critical",
    ),
    dict(
        APPLIED_HIGH,
        timestamp="2026-01-02T00:00:00Z",
        action="propagate",
        skill="crit",
        propagated_from="x",
    ),
    dict(APPLIED_HIGH, timestamp="2026-01-02T01:00:00Z", dry_run=True),
    {
        "timestamp": "2026-01-03",
        "action": "apply",
        "skill": "nots",
        "sections_added": ["Notes"],
        "dry_run": False,
    },
]


def test_changelog_output(env, capsys):
    """The changelog report is unchanged."""
    module, _, tmp_path = env
    _write_log(tmp_path, CHANGELOG)
    module.cmd_changelog()
    assert capsys.readouterr().out == golden("remediate_changelog.txt")


def test_changelog_single_apply(env, capsys):
    """With a single apply no velocity rate is printed."""
    module, _, tmp_path = env
    _write_log(tmp_path, [APPLIED_HIGH])
    module.cmd_changelog()
    out = capsys.readouterr().out
    assert "Total applied: 1" in out
    assert "Rate:" not in out


def test_changelog_empty(env, capsys):
    """An empty log prints a single message."""
    module, _, _ = env
    module.cmd_changelog()
    assert capsys.readouterr().out == "No remediations recorded yet.\n"


def test_main_dispatch(env, monkeypatch, capsys):
    """main() dispatches --changelog and --scan."""
    module, _, tmp_path = env
    monkeypatch.setattr("sys.argv", ["securetty_remediate.py", "--changelog", "--scan"])
    module.main()
    out = _normalise(capsys.readouterr().out, tmp_path)
    assert out == "No remediations recorded yet.\n" + golden("remediate_scan.txt")


def test_main_requires_an_action(env, monkeypatch):
    """main() exits with status 1 when no action flag is given."""
    module, _, _ = env
    monkeypatch.setattr("sys.argv", ["securetty_remediate.py"])
    with pytest.raises(SystemExit) as exc:
        module.main()
    assert exc.value.code == 1


def test_changelog_velocity_rate(env, capsys):
    """Two timed applies four hours apart report a patch rate."""
    module, _, tmp_path = env
    _write_log(
        tmp_path,
        [APPLIED_HIGH, dict(APPLIED_HIGH, timestamp="2026-01-01T04:00:00Z")],
    )
    module.cmd_changelog()
    assert "  Rate: 0.50 patches/hour over 4.0h\n" in capsys.readouterr().out
