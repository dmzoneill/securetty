#!/usr/bin/env python3
"""securetty closed-loop remediation engine.

Reads the failure database, identifies high-failure agents, generates
additive SKILL.md patches, propagates fixes across skills that share
the same failure patterns, and maintains an audit trail.

Patches are strictly additive: they append "Known Issues" or
"Troubleshooting" sections to SKILL.md files and never remove content.

Usage:
    securetty-remediate.py --scan                  Identify agents needing remediation
    securetty-remediate.py --apply [--confirm]      Apply suggested patches
    securetty-remediate.py --propagate              Propagate fixes to similar skills
    securetty-remediate.py --changelog              Show remediation history
    securetty-remediate.py --dry-run --apply        Preview without modifying files
"""

import argparse
import copy
import json
import os
import re
import shutil
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_PATH = os.environ.get(
    "SECURETTY_FAILURE_DB", os.path.expanduser("~/.securetty/failures.db")
)
BUILTIN_SKILLS_DIR = os.environ.get(
    "SECURETTY_BUILTIN_SKILLS", os.path.expanduser("~/src/agent-mcp-skills")
)
USER_SKILLS_DIR = os.environ.get(
    "SECURETTY_USER_SKILLS", os.path.expanduser("~/.securetty/skills")
)
REMEDIATIONS_PATH = os.environ.get(
    "SECURETTY_REMEDIATIONS_LOG",
    os.path.expanduser("~/.securetty/remediations.jsonl"),
)
FAILURE_THRESHOLD = float(os.environ.get("SECURETTY_FAILURE_THRESHOLD", "30.0"))

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------


def _get_db() -> sqlite3.Connection:
    """Open the failure database read-only."""
    if not os.path.isfile(DB_PATH):
        print(
            f"error: failure database not found at {DB_PATH}\n"
            "Run securetty-failure-db.py --ingest to populate it first.",
            file=sys.stderr,
        )
        sys.exit(1)
    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _fetch_patterns(conn: sqlite3.Connection, threshold: float) -> list[dict]:
    """Return pattern rows for agents exceeding the failure threshold."""
    rows = conn.execute(
        "SELECT * FROM patterns WHERE failure_rate > ? ORDER BY failure_rate DESC",
        (threshold,),
    ).fetchall()
    return [dict(r) for r in rows]


def _fetch_exit_code_distribution(
    conn: sqlite3.Connection, agent: str
) -> list[dict]:
    """Return exit-code distribution for failed sessions of an agent."""
    rows = conn.execute(
        "SELECT exit_code, COUNT(*) as count "
        "FROM sessions WHERE agent = ? AND exit_code != 0 "
        "GROUP BY exit_code ORDER BY count DESC",
        (agent,),
    ).fetchall()
    return [dict(r) for r in rows]


def _fetch_failure_workdirs(
    conn: sqlite3.Connection, agent: str, limit: int = 5
) -> list[dict]:
    """Return top workdirs where an agent fails."""
    rows = conn.execute(
        "SELECT workdir, COUNT(*) as count "
        "FROM sessions WHERE agent = ? AND exit_code != 0 "
        "GROUP BY workdir ORDER BY count DESC LIMIT ?",
        (agent, limit),
    ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# SKILL.md discovery
# ---------------------------------------------------------------------------


def _discover_skill_files() -> dict[str, list[Path]]:
    """Find all SKILL.md files grouped by skill name.

    Returns a dict mapping skill_name -> list of SKILL.md paths.
    Multiple paths occur when a skill has both a top-level SKILL.md and
    one under .claude/skills/<name>/SKILL.md.
    """
    result: dict[str, list[Path]] = defaultdict(list)
    for base_dir in [BUILTIN_SKILLS_DIR, USER_SKILLS_DIR]:
        base = Path(base_dir)
        if not base.is_dir():
            continue
        for skill_md in sorted(base.rglob("SKILL.md")):
            # Derive the skill name from the parent directory name
            name = skill_md.parent.name
            # For .claude/skills/<name>/SKILL.md the parent is <name>
            # For <name>/SKILL.md the parent is <name>
            result[name].append(skill_md)
    return dict(result)


def _parse_frontmatter(path: Path) -> dict:
    """Parse YAML frontmatter from a SKILL.md file.

    Returns a dict with keys: name, description, version, tags, triggers.
    Only parses the simple key: value lines between --- delimiters.
    """
    meta: dict = {}
    in_fm = False
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return meta

    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "---":
            if in_fm:
                break
            in_fm = True
            continue
        if in_fm and ":" in stripped:
            key, _, val = stripped.partition(":")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key in ("name", "description", "version"):
                meta[key] = val
            elif key == "tags":
                # [tag1, tag2, ...]
                val = val.strip("[]")
                meta["tags"] = [t.strip().strip('"').strip("'") for t in val.split(",") if t.strip()]
            elif key == "triggers":
                meta.setdefault("triggers", [])
    return meta


def _skill_has_section(path: Path, heading: str) -> bool:
    """Check whether a SKILL.md already contains a markdown heading."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    pattern = re.compile(r"^#{1,3}\s+" + re.escape(heading), re.MULTILINE)
    return bool(pattern.search(text))


# ---------------------------------------------------------------------------
# Patch generation
# ---------------------------------------------------------------------------


def _classify_failure(pattern: dict, exit_codes: list[dict]) -> str:
    """Classify the dominant failure mode for template selection.

    Returns one of: 'critical', 'high', 'elevated', 'timeout', 'workdir'.
    """
    rate = pattern["failure_rate"]
    avg_dur = pattern.get("avg_duration_seconds", 0)

    if rate > 70:
        return "critical"
    if rate > 50:
        return "high"
    if avg_dur > 600:
        return "timeout"
    return "elevated"


def _build_known_issues_section(
    agent: str,
    pattern: dict,
    exit_codes: list[dict],
    workdirs: list[dict],
) -> str:
    """Build a 'Known Issues' markdown section to append to SKILL.md."""
    rate = pattern["failure_rate"]
    total = pattern["total_sessions"]
    failures = pattern["total_failures"]
    avg_dur = pattern.get("avg_duration_seconds", 0)

    lines = [
        "",
        "## Known Issues",
        "",
        f"*Auto-generated by securetty-remediate on "
        f"{datetime.now(timezone.utc).strftime('%Y-%m-%d')}. "
        f"Based on {total} sessions with {rate:.1f}% failure rate "
        f"({failures}/{total} failures).*",
        "",
    ]

    if exit_codes:
        lines.append("### Observed Failure Codes")
        lines.append("")
        for ec in exit_codes:
            code = ec["exit_code"]
            count = ec["count"]
            label = _exit_code_label(code)
            lines.append(f"- **Exit code {code}** ({label}): {count} occurrence(s)")
        lines.append("")

    if workdirs:
        lines.append("### Affected Repositories")
        lines.append("")
        for wd in workdirs:
            lines.append(f"- `{wd['workdir']}`: {wd['count']} failure(s)")
        lines.append("")

    return "\n".join(lines)


def _build_troubleshooting_section(
    agent: str,
    pattern: dict,
    classification: str,
) -> str:
    """Build a 'Troubleshooting' section tailored to the failure class."""
    rate = pattern["failure_rate"]
    avg_dur = pattern.get("avg_duration_seconds", 0)

    lines = [
        "",
        "## Troubleshooting",
        "",
    ]

    if classification == "critical":
        lines.extend([
            f"This skill has a **critical** failure rate ({rate:.1f}%). "
            "Apply the following checks before each invocation:",
            "",
            "1. **Pre-flight validation** -- Verify all required tools and "
            "credentials are available in the current environment before "
            "starting work.",
            "2. **Scope reduction** -- Break complex requests into smaller, "
            "independently verifiable steps. Fail fast on the first step "
            "that cannot be validated.",
            "3. **Fallback strategy** -- If the primary approach fails after "
            "one retry, switch to a simpler alternative (e.g., direct API "
            "calls instead of MCP tools) and report what was tried.",
            "",
        ])
    elif classification == "high":
        lines.extend([
            f"This skill has a **high** failure rate ({rate:.1f}%). "
            "The following guardrails are recommended:",
            "",
            "1. **Prerequisite check** -- Before starting, confirm that "
            "required dependencies are available and that the working "
            "directory is in the expected state (e.g., valid git repo, "
            "correct branch).",
            "2. **Incremental progress** -- Save intermediate results so "
            "that partial progress is not lost on failure.",
            "3. **Error context** -- When a step fails, capture the full "
            "error output and include it in the exit diagnostic.",
            "",
        ])
    elif classification == "timeout":
        lines.extend([
            f"This skill has an **elevated timeout risk** (average duration "
            f"{avg_dur:.0f}s). Apply time-boxing:",
            "",
            "1. **Time budget** -- Allocate a maximum of 10 minutes per "
            "invocation. If the task is not complete within that window, "
            "save progress and exit with a partial result.",
            "2. **Progress checkpoints** -- Log progress markers every 2 "
            "minutes so that a subsequent invocation can resume from the "
            "last checkpoint.",
            "3. **Scope guard** -- If the input appears to require more "
            "than 10 minutes of work, split it into sub-tasks and process "
            "them sequentially.",
            "",
        ])
    else:  # elevated
        lines.extend([
            f"This skill has an **elevated** failure rate ({rate:.1f}%). "
            "Consider the following mitigations:",
            "",
            "1. **Retry with context** -- On first failure, retry once "
            "with adjusted parameters and include the error message from "
            "the first attempt in the retry prompt.",
            "2. **Diagnostic exit** -- On second failure, exit cleanly "
            "with a structured diagnostic output (error message, command "
            "that failed, environment state).",
            "3. **Outcome logging** -- Ensure the exit code and duration "
            "are captured for retrospective analysis.",
            "",
        ])

    return "\n".join(lines)


def _exit_code_label(code: int) -> str:
    """Return a human-readable label for common exit codes."""
    labels = {
        1: "general error",
        2: "misuse of shell builtin",
        126: "command not executable",
        127: "command not found",
        128: "invalid exit argument",
        130: "interrupted (SIGINT)",
        137: "killed (SIGKILL / OOM)",
        139: "segmentation fault",
        143: "terminated (SIGTERM)",
    }
    if code > 128:
        sig = code - 128
        return labels.get(code, f"signal {sig}")
    return labels.get(code, "unknown")


# ---------------------------------------------------------------------------
# Patch application
# ---------------------------------------------------------------------------


def _generate_patch(
    skill_name: str,
    skill_path: Path,
    pattern: dict,
    exit_codes: list[dict],
    workdirs: list[dict],
    classification: str,
) -> dict | None:
    """Generate a patch descriptor for a single SKILL.md file.

    Returns None if no patch is needed (sections already present).
    """
    sections_to_add = []

    if not _skill_has_section(skill_path, "Known Issues"):
        section = _build_known_issues_section(
            skill_name, pattern, exit_codes, workdirs
        )
        sections_to_add.append(("Known Issues", section))

    if not _skill_has_section(skill_path, "Troubleshooting"):
        section = _build_troubleshooting_section(
            skill_name, pattern, classification
        )
        sections_to_add.append(("Troubleshooting", section))

    if not sections_to_add:
        return None

    return {
        "skill": skill_name,
        "path": str(skill_path),
        "classification": classification,
        "failure_rate": pattern["failure_rate"],
        "total_sessions": pattern["total_sessions"],
        "total_failures": pattern["total_failures"],
        "sections": [
            {"heading": heading, "content": content}
            for heading, content in sections_to_add
        ],
    }


def _apply_patch(patch: dict, dry_run: bool = False) -> bool:
    """Append patch sections to a SKILL.md file.

    Creates a .bak backup before modifying.  Returns True if the file was
    modified (or would have been in dry-run mode).
    """
    path = Path(patch["path"])
    if not path.is_file():
        print(f"  warning: {path} does not exist, skipping", file=sys.stderr)
        return False

    content_to_append = ""
    for section in patch["sections"]:
        content_to_append += section["content"]

    if dry_run:
        print(f"  [dry-run] Would append to {path}:")
        for section in patch["sections"]:
            print(f"    + ## {section['heading']}")
        return True

    # Create backup
    backup_path = path.with_suffix(".md.bak")
    shutil.copy2(path, backup_path)

    # Append sections
    with open(path, "a", encoding="utf-8") as f:
        f.write(content_to_append)

    print(f"  Patched {path}")
    print(f"  Backup at {backup_path}")
    return True


def _log_remediation(entry: dict) -> None:
    """Append a remediation record to the JSONL log."""
    log_dir = os.path.dirname(REMEDIATIONS_PATH)
    os.makedirs(log_dir, exist_ok=True)
    with open(REMEDIATIONS_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, default=str) + "\n")


# ---------------------------------------------------------------------------
# Scan mode
# ---------------------------------------------------------------------------


def cmd_scan(conn: sqlite3.Connection, dry_run: bool = False) -> list[dict]:
    """Identify agents with high failure rates and generate patch suggestions."""
    patterns = _fetch_patterns(conn, FAILURE_THRESHOLD)
    if not patterns:
        print(
            f"No agents exceed the {FAILURE_THRESHOLD:.0f}% failure threshold. "
            "Nothing to remediate."
        )
        return []

    skill_files = _discover_skill_files()
    patches: list[dict] = []

    print("=" * 70)
    print("securetty remediation scan")
    print("=" * 70)
    print()
    print(
        f"Agents exceeding {FAILURE_THRESHOLD:.0f}% failure rate: "
        f"{len(patterns)}"
    )
    print()

    for pattern in patterns:
        agent = pattern["agent"]
        exit_codes = _fetch_exit_code_distribution(conn, agent)
        workdirs = _fetch_failure_workdirs(conn, agent)
        classification = _classify_failure(pattern, exit_codes)

        print("-" * 70)
        print(f"Agent: {agent}")
        print(
            f"  Failure rate: {pattern['failure_rate']:.1f}% "
            f"({pattern['total_failures']}/{pattern['total_sessions']} sessions)"
        )
        print(f"  Classification: {classification}")
        print(
            f"  Avg duration: {pattern.get('avg_duration_seconds', 0):.0f}s"
        )

        if exit_codes:
            codes_str = ", ".join(
                f"{ec['exit_code']}({ec['count']})" for ec in exit_codes
            )
            print(f"  Exit codes: {codes_str}")

        # Find matching SKILL.md files
        # Try exact match first, then partial match on agent name
        matched_skills = _match_agent_to_skills(agent, skill_files)

        if not matched_skills:
            print(f"  No SKILL.md files found for agent '{agent}'")
            print()
            continue

        for skill_name, skill_paths in matched_skills.items():
            for skill_path in skill_paths:
                patch = _generate_patch(
                    skill_name, skill_path, pattern,
                    exit_codes, workdirs, classification,
                )
                if patch:
                    patches.append(patch)
                    for section in patch["sections"]:
                        print(
                            f"  Patch: +{section['heading']} -> "
                            f"{skill_path}"
                        )
                else:
                    print(
                        f"  {skill_path}: sections already present, "
                        "no patch needed"
                    )

        print()

    print("=" * 70)
    if patches:
        print(
            f"\n{len(patches)} patch(es) generated. "
            "Run --apply --confirm to apply them."
        )
    else:
        print("\nNo patches to generate (all sections already present).")
    print("=" * 70)

    return patches


def _match_agent_to_skills(
    agent: str, skill_files: dict[str, list[Path]]
) -> dict[str, list[Path]]:
    """Match an agent name to SKILL.md files.

    Tries several strategies:
    1. Exact match on skill directory name
    2. Agent name appears in skill directory name
    3. Skill directory name appears in agent name
    4. Agent name with common suffixes stripped (-query, -skill)
    """
    matches: dict[str, list[Path]] = {}
    agent_lower = agent.lower().replace("_", "-")

    # Strategy 1: exact match
    if agent_lower in skill_files:
        matches[agent_lower] = skill_files[agent_lower]
        return matches

    # Strategy 2: agent name with -query suffix (common pattern)
    query_name = f"{agent_lower}-query"
    if query_name in skill_files:
        matches[query_name] = skill_files[query_name]
        return matches

    # Strategy 3: partial match
    for skill_name, paths in skill_files.items():
        skill_lower = skill_name.lower()
        if agent_lower in skill_lower or skill_lower in agent_lower:
            matches[skill_name] = paths

    return matches


# ---------------------------------------------------------------------------
# Apply mode
# ---------------------------------------------------------------------------


def cmd_apply(
    conn: sqlite3.Connection, confirm: bool = False, dry_run: bool = False
) -> None:
    """Apply suggested patches to SKILL.md files."""
    patches = cmd_scan(conn, dry_run=dry_run)

    if not patches:
        return

    if not confirm and not dry_run:
        print(
            "\nUse --confirm to apply patches. "
            "Use --dry-run to preview changes."
        )
        return

    print()
    print("=" * 70)
    if dry_run:
        print("DRY RUN -- showing what would change")
    else:
        print("APPLYING PATCHES")
    print("=" * 70)
    print()

    applied = 0
    now = datetime.now(timezone.utc).isoformat()

    for patch in patches:
        success = _apply_patch(patch, dry_run=dry_run)
        if success:
            applied += 1
            entry = {
                "timestamp": now,
                "action": "apply",
                "skill": patch["skill"],
                "path": patch["path"],
                "classification": patch["classification"],
                "failure_rate": patch["failure_rate"],
                "total_sessions": patch["total_sessions"],
                "total_failures": patch["total_failures"],
                "sections_added": [s["heading"] for s in patch["sections"]],
                "dry_run": dry_run,
            }
            if not dry_run:
                _log_remediation(entry)

    print()
    verb = "would be" if dry_run else "were"
    print(f"{applied}/{len(patches)} patch(es) {verb} applied.")


# ---------------------------------------------------------------------------
# Propagate mode
# ---------------------------------------------------------------------------


def _extract_pattern_signature(patch: dict) -> str:
    """Extract a pattern signature for cross-skill matching.

    Two patches share a pattern if they have the same classification.
    The signature is the classification string itself.
    """
    return patch["classification"]


def cmd_propagate(
    conn: sqlite3.Connection, confirm: bool = False, dry_run: bool = False
) -> None:
    """Propagate fixes across skills that share failure patterns.

    When a fix has been applied to one skill, this checks whether other
    skills exhibit the same failure classification and suggests (or
    applies) the same remediation sections.
    """
    # Load applied remediations to find what has been fixed
    applied_remediations = _load_remediations()
    if not applied_remediations:
        print(
            "No remediations have been applied yet. "
            "Run --apply --confirm first."
        )
        return

    # Build a set of classifications that have been remediated and
    # the corresponding patch templates
    remediated_classifications: dict[str, dict] = {}
    for entry in applied_remediations:
        if entry.get("action") == "apply" and not entry.get("dry_run"):
            classification = entry.get("classification", "")
            if classification:
                remediated_classifications[classification] = entry

    if not remediated_classifications:
        print("No completed remediations found to propagate.")
        return

    # Scan all agents for matching patterns
    patterns = _fetch_patterns(conn, FAILURE_THRESHOLD)
    skill_files = _discover_skill_files()

    # Find skills that need the same remediation but have not been patched
    already_patched = {
        r["path"] for r in applied_remediations
        if r.get("action") in ("apply", "propagate") and not r.get("dry_run")
    }

    propagation_targets: list[dict] = []

    print("=" * 70)
    print("securetty remediation propagation")
    print("=" * 70)
    print()
    print(
        f"Remediated classifications: "
        f"{', '.join(sorted(remediated_classifications.keys()))}"
    )
    print()

    for pattern in patterns:
        agent = pattern["agent"]
        exit_codes = _fetch_exit_code_distribution(conn, agent)
        classification = _classify_failure(pattern, exit_codes)

        if classification not in remediated_classifications:
            continue

        matched_skills = _match_agent_to_skills(agent, skill_files)
        for skill_name, skill_paths in matched_skills.items():
            for skill_path in skill_paths:
                if str(skill_path) in already_patched:
                    continue
                workdirs = _fetch_failure_workdirs(conn, agent)
                patch = _generate_patch(
                    skill_name, skill_path, pattern,
                    exit_codes, workdirs, classification,
                )
                if patch:
                    patch["propagated_from"] = remediated_classifications[
                        classification
                    ].get("skill", "unknown")
                    propagation_targets.append(patch)

    if not propagation_targets:
        print("No propagation targets found. All matching skills are patched.")
        return

    print(f"Found {len(propagation_targets)} skill(s) to propagate to:")
    print()
    for target in propagation_targets:
        print(
            f"  {target['skill']} ({target['path']}) "
            f"-- {target['classification']} "
            f"(propagated from {target.get('propagated_from', '?')})"
        )
    print()

    if not confirm and not dry_run:
        print(
            "Use --confirm to apply propagated patches. "
            "Use --dry-run to preview."
        )
        return

    if dry_run:
        print("DRY RUN -- showing what would change")
        print()

    applied = 0
    now = datetime.now(timezone.utc).isoformat()

    for patch in propagation_targets:
        success = _apply_patch(patch, dry_run=dry_run)
        if success:
            applied += 1
            entry = {
                "timestamp": now,
                "action": "propagate",
                "skill": patch["skill"],
                "path": patch["path"],
                "classification": patch["classification"],
                "failure_rate": patch["failure_rate"],
                "total_sessions": patch["total_sessions"],
                "total_failures": patch["total_failures"],
                "sections_added": [s["heading"] for s in patch["sections"]],
                "propagated_from": patch.get("propagated_from", "unknown"),
                "dry_run": dry_run,
            }
            if not dry_run:
                _log_remediation(entry)

    print()
    verb = "would be" if dry_run else "were"
    print(f"{applied}/{len(propagation_targets)} propagation(s) {verb} applied.")


# ---------------------------------------------------------------------------
# Changelog mode
# ---------------------------------------------------------------------------


def _load_remediations() -> list[dict]:
    """Load all remediation entries from the JSONL log."""
    if not os.path.isfile(REMEDIATIONS_PATH):
        return []
    entries = []
    with open(REMEDIATIONS_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


def cmd_changelog() -> None:
    """Output the remediation changelog."""
    entries = _load_remediations()
    if not entries:
        print("No remediations recorded yet.")
        return

    print("=" * 70)
    print("securetty remediation changelog")
    print("=" * 70)
    print()

    # Summary statistics
    total = len(entries)
    applies = [e for e in entries if e.get("action") == "apply" and not e.get("dry_run")]
    propagations = [e for e in entries if e.get("action") == "propagate" and not e.get("dry_run")]
    dry_runs = [e for e in entries if e.get("dry_run")]

    print(f"Total entries:    {total}")
    print(f"Applied patches:  {len(applies)}")
    print(f"Propagations:     {len(propagations)}")
    print(f"Dry runs:         {len(dry_runs)}")
    print()

    # Group by date
    by_date: dict[str, list[dict]] = defaultdict(list)
    for entry in entries:
        ts = entry.get("timestamp", "unknown")
        date = ts[:10] if len(ts) >= 10 else ts
        by_date[date].append(entry)

    for date in sorted(by_date.keys(), reverse=True):
        date_entries = by_date[date]
        print("-" * 70)
        print(f"Date: {date}")
        print("-" * 70)
        for entry in date_entries:
            action = entry.get("action", "?")
            skill = entry.get("skill", "?")
            path = entry.get("path", "?")
            classification = entry.get("classification", "?")
            rate = entry.get("failure_rate", 0)
            sections = entry.get("sections_added", [])
            is_dry = entry.get("dry_run", False)

            prefix = "[dry-run] " if is_dry else ""
            print(f"  {prefix}{action}: {skill}")
            print(f"    Path: {path}")
            print(f"    Classification: {classification} ({rate:.1f}% failure)")
            print(f"    Sections added: {', '.join(sections)}")
            if entry.get("propagated_from"):
                print(f"    Propagated from: {entry['propagated_from']}")
            print()

    # Remediation velocity
    if applies:
        first_ts = applies[0].get("timestamp", "")
        last_ts = applies[-1].get("timestamp", "")
        print("-" * 70)
        print("Remediation velocity")
        print("-" * 70)
        print(f"  First remediation: {first_ts}")
        print(f"  Latest remediation: {last_ts}")
        print(f"  Total applied: {len(applies)}")
        if len(applies) > 1:
            try:
                first = datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
                last = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
                span = (last - first).total_seconds() / 3600
                if span > 0:
                    rate = len(applies) / span
                    print(f"  Rate: {rate:.2f} patches/hour over {span:.1f}h")
            except (ValueError, TypeError):
                pass
        print()

    # Skills patched
    patched_skills = set()
    for entry in applies + propagations:
        patched_skills.add(entry.get("skill", "?"))

    if patched_skills:
        print("-" * 70)
        print("Skills with remediations")
        print("-" * 70)
        for skill in sorted(patched_skills):
            count = sum(
                1 for e in applies + propagations if e.get("skill") == skill
            )
            print(f"  {skill}: {count} patch(es)")
        print()

    print("=" * 70)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "securetty closed-loop remediation engine -- "
            "scan, patch, propagate, and audit SKILL.md fixes"
        )
    )
    parser.add_argument(
        "--scan",
        action="store_true",
        help=(
            "Scan failure DB for agents exceeding the failure threshold "
            "and generate SKILL.md patch suggestions"
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply suggested patches to SKILL.md files (requires --confirm)",
    )
    parser.add_argument(
        "--propagate",
        action="store_true",
        help=(
            "Propagate applied fixes to other skills with the same "
            "failure pattern"
        ),
    )
    parser.add_argument(
        "--changelog",
        action="store_true",
        help="Output the remediation changelog",
    )
    parser.add_argument(
        "--confirm",
        action="store_true",
        help="Required with --apply/--propagate to actually modify files",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without modifying any files",
    )

    args = parser.parse_args()

    if not any([args.scan, args.apply, args.propagate, args.changelog]):
        parser.print_help()
        sys.exit(1)

    # Changelog does not need the database
    if args.changelog:
        cmd_changelog()
        if not any([args.scan, args.apply, args.propagate]):
            return

    # All other modes need the failure database
    conn = _get_db()
    try:
        if args.scan and not args.apply and not args.propagate:
            cmd_scan(conn, dry_run=args.dry_run)
        if args.apply:
            cmd_apply(conn, confirm=args.confirm, dry_run=args.dry_run)
        if args.propagate:
            cmd_propagate(
                conn, confirm=args.confirm, dry_run=args.dry_run
            )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
