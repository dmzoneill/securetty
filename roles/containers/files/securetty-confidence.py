#!/usr/bin/env python3
"""securetty confidence scoring model -- learned escalation thresholds.

Reads historical session outcomes from the failure database and computes
per-agent, per-repo confidence scores.  These scores feed into escalation
decisions: a low-confidence agent working on a high-failure repo gets
escalated sooner than a high-confidence agent on a clean repo.

The confidence formula is:

    confidence = base_rate * recency_weight * repo_factor

Where:
    base_rate      = agent success rate (0.0-1.0)
    recency_weight = exponential decay giving more weight to recent sessions
    repo_factor    = repo-specific modifier (repos with more failures penalize)

Usage:
    securetty-confidence.py --score <agent> [repo]   Confidence score (0.0-1.0)
    securetty-confidence.py --threshold              Recommended escalation threshold
    securetty-confidence.py --adjust                 Suggest threshold changes
    securetty-confidence.py --report                 Full confidence report
"""

import argparse
import json
import math
import os
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timezone, timedelta

DB_PATH = os.environ.get(
    "SECURETTY_FAILURE_DB", os.path.expanduser("~/.securetty/failures.db")
)

# Recency half-life in days.  Sessions older than this contribute half as
# much to the confidence score as sessions that happened today.
RECENCY_HALF_LIFE_DAYS = float(
    os.environ.get("SECURETTY_CONFIDENCE_HALFLIFE", "14")
)

# Minimum number of sessions before we produce a meaningful score.
# Below this threshold the score is marked as provisional.
MIN_SESSIONS = int(os.environ.get("SECURETTY_CONFIDENCE_MIN_SESSIONS", "5"))

# Default escalation threshold when no historical data exists.
DEFAULT_THRESHOLD = float(
    os.environ.get("SECURETTY_CONFIDENCE_DEFAULT_THRESHOLD", "0.6")
)

# Duration penalty: sessions longer than this (seconds) are penalised.
DURATION_PENALTY_THRESHOLD = int(
    os.environ.get("SECURETTY_CONFIDENCE_DURATION_PENALTY", "600")
)

# ---- database access -------------------------------------------------------


def get_db() -> sqlite3.Connection:
    """Open the failure database (read-only), creating if needed."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    if not os.path.isfile(DB_PATH):
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "CREATE TABLE IF NOT EXISTS sessions ("
            "id INTEGER PRIMARY KEY, agent TEXT, repo TEXT, "
            "exit_code INTEGER, duration INTEGER, timestamp TEXT, "
            "workdir TEXT, mode TEXT)"
        )
        conn.commit()
        conn.close()
        print(f"Initialized empty failure database at {DB_PATH}", file=sys.stderr)

    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _has_sessions_table(conn: sqlite3.Connection) -> bool:
    """Return True if the sessions table exists."""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='sessions'"
    ).fetchone()
    return row is not None


# ---- scoring helpers --------------------------------------------------------


def _recency_weight(timestamp_str: str, now: datetime) -> float:
    """Exponential decay weight for a session based on its timestamp.

    Returns a float in (0.0, 1.0] where 1.0 is 'right now' and values
    decay toward 0 as the session ages.  The half-life is controlled by
    RECENCY_HALF_LIFE_DAYS.
    """
    try:
        # Handle both ISO-format variants the logger produces
        ts = timestamp_str.replace("Z", "+00:00")
        session_time = datetime.fromisoformat(ts)
        if session_time.tzinfo is None:
            session_time = session_time.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return 0.5  # unknown timestamp -- neutral weight

    age_days = max((now - session_time).total_seconds() / 86400, 0)
    return math.exp(-math.log(2) * age_days / RECENCY_HALF_LIFE_DAYS)


def _duration_factor(avg_duration: float) -> float:
    """Penalise agents with long average durations.

    Returns 1.0 for durations at or below the penalty threshold, scaling
    down linearly to 0.5 at 3x the threshold.
    """
    if avg_duration <= DURATION_PENALTY_THRESHOLD:
        return 1.0
    ratio = avg_duration / DURATION_PENALTY_THRESHOLD
    # Clamp to minimum 0.5 -- even very slow agents get some credit
    return max(1.0 - (ratio - 1.0) * 0.25, 0.5)


def compute_agent_score(
    conn: sqlite3.Connection, agent: str, repo: str | None = None
) -> dict:
    """Compute the confidence score for an agent, optionally scoped to a repo.

    Returns a dict with:
        score        -- float 0.0-1.0
        provisional  -- True if insufficient data
        base_rate    -- raw success rate
        recency_weight -- weighted recency factor
        repo_factor  -- repo-specific modifier
        duration_factor -- duration-based modifier
        total_sessions -- count of sessions considered
        total_failures -- count of failures
        failure_patterns -- number of distinct failure exit codes
    """
    now = datetime.now(timezone.utc)

    # Fetch sessions for this agent
    if repo:
        rows = conn.execute(
            "SELECT timestamp, exit_code, duration_seconds "
            "FROM sessions WHERE agent = ? AND workdir = ? "
            "ORDER BY timestamp DESC",
            (agent, repo),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT timestamp, exit_code, duration_seconds "
            "FROM sessions WHERE agent = ? "
            "ORDER BY timestamp DESC",
            (agent,),
        ).fetchall()

    total = len(rows)
    if total == 0:
        return {
            "score": DEFAULT_THRESHOLD,
            "provisional": True,
            "base_rate": DEFAULT_THRESHOLD,
            "recency_weight": 1.0,
            "repo_factor": 1.0,
            "duration_factor": 1.0,
            "total_sessions": 0,
            "total_failures": 0,
            "failure_patterns": 0,
        }

    # Weighted success rate: recent sessions count more
    weighted_successes = 0.0
    weighted_total = 0.0
    total_failures = 0
    failure_exit_codes = set()
    durations = []

    for row in rows:
        w = _recency_weight(row["timestamp"], now)
        weighted_total += w
        if row["exit_code"] == 0:
            weighted_successes += w
        else:
            total_failures += 1
            failure_exit_codes.add(row["exit_code"])
        durations.append(row["duration_seconds"] or 0)

    base_rate = weighted_successes / weighted_total if weighted_total > 0 else 0.0

    # Recency weight: average weight of all sessions (reflects data freshness)
    recency_w = weighted_total / total if total > 0 else 1.0

    # Duration factor
    avg_dur = sum(durations) / len(durations) if durations else 0
    dur_factor = _duration_factor(avg_dur)

    # Repo factor: if scoped to a repo, compare its failure rate to the
    # agent's global failure rate.  Repos that fail more than average get
    # penalised.
    repo_factor = 1.0
    if repo:
        global_rows = conn.execute(
            "SELECT COUNT(*) as total, "
            "SUM(CASE WHEN exit_code != 0 THEN 1 ELSE 0 END) as failures "
            "FROM sessions WHERE agent = ?",
            (agent,),
        ).fetchone()
        global_total = global_rows["total"] or 1
        global_failures = global_rows["failures"] or 0
        global_fail_rate = global_failures / global_total

        repo_fail_rate = total_failures / total if total > 0 else 0

        if global_fail_rate > 0 and repo_fail_rate > global_fail_rate:
            # Repo is worse than average -- penalise proportionally
            excess = repo_fail_rate / global_fail_rate
            repo_factor = max(1.0 / excess, 0.3)  # floor at 0.3
        elif repo_fail_rate < global_fail_rate and global_fail_rate > 0:
            # Repo is better than average -- slight bonus
            repo_factor = min(1.0 + (global_fail_rate - repo_fail_rate), 1.2)

    # Failure pattern penalty: agents with many distinct failure modes
    # (different exit codes) are less predictable
    pattern_count = len(failure_exit_codes)
    pattern_penalty = max(1.0 - pattern_count * 0.05, 0.7)

    # Final composite score
    score = base_rate * recency_w * repo_factor * dur_factor * pattern_penalty
    score = max(0.0, min(1.0, score))

    return {
        "score": round(score, 4),
        "provisional": total < MIN_SESSIONS,
        "base_rate": round(base_rate, 4),
        "recency_weight": round(recency_w, 4),
        "repo_factor": round(repo_factor, 4),
        "duration_factor": round(dur_factor, 4),
        "total_sessions": total,
        "total_failures": total_failures,
        "failure_patterns": pattern_count,
    }


# ---- repo-level confidence -------------------------------------------------


def compute_repo_score(conn: sqlite3.Connection, repo: str) -> dict:
    """Compute aggregate confidence for a repo across all agents."""
    now = datetime.now(timezone.utc)

    rows = conn.execute(
        "SELECT timestamp, agent, exit_code, duration_seconds "
        "FROM sessions WHERE workdir = ? ORDER BY timestamp DESC",
        (repo,),
    ).fetchall()

    total = len(rows)
    if total == 0:
        return {
            "score": DEFAULT_THRESHOLD,
            "provisional": True,
            "total_sessions": 0,
            "total_failures": 0,
            "agents": [],
        }

    weighted_successes = 0.0
    weighted_total = 0.0
    total_failures = 0
    agents_seen = set()

    for row in rows:
        w = _recency_weight(row["timestamp"], now)
        weighted_total += w
        if row["exit_code"] == 0:
            weighted_successes += w
        else:
            total_failures += 1
        agents_seen.add(row["agent"])

    success_rate = weighted_successes / weighted_total if weighted_total > 0 else 0.0

    return {
        "score": round(max(0.0, min(1.0, success_rate)), 4),
        "provisional": total < MIN_SESSIONS,
        "total_sessions": total,
        "total_failures": total_failures,
        "agents": sorted(agents_seen),
    }


# ---- threshold computation -------------------------------------------------


def compute_threshold(conn: sqlite3.Connection) -> dict:
    """Recommend an escalation threshold based on historical data.

    The recommended threshold is the score at which historically half the
    sessions below it failed.  This creates a natural decision boundary:
    sessions scoring below the threshold should be escalated.
    """
    rows = conn.execute(
        "SELECT agent, exit_code FROM sessions"
    ).fetchall()

    if not rows:
        return {
            "recommended_threshold": DEFAULT_THRESHOLD,
            "basis": "default (no historical data)",
            "total_sessions": 0,
        }

    # Compute per-agent success rates
    agent_totals = defaultdict(int)
    agent_successes = defaultdict(int)

    for row in rows:
        agent_totals[row["agent"]] += 1
        if row["exit_code"] == 0:
            agent_successes[row["agent"]] += 1

    rates = []
    for agent in agent_totals:
        rate = agent_successes[agent] / agent_totals[agent]
        rates.append(rate)

    if not rates:
        return {
            "recommended_threshold": DEFAULT_THRESHOLD,
            "basis": "default (insufficient data)",
            "total_sessions": len(rows),
        }

    # Threshold = median agent success rate minus one standard deviation.
    # This sets the bar at a point where agents scoring below it are
    # performing meaningfully worse than the population.
    rates.sort()
    median = rates[len(rates) // 2]
    mean = sum(rates) / len(rates)
    variance = sum((r - mean) ** 2 for r in rates) / len(rates)
    stddev = math.sqrt(variance)

    threshold = max(0.1, min(0.9, median - stddev))

    return {
        "recommended_threshold": round(threshold, 4),
        "basis": f"median({round(median, 4)}) - stddev({round(stddev, 4)}) across {len(rates)} agents",
        "total_sessions": len(rows),
        "agent_count": len(rates),
        "median_success_rate": round(median, 4),
        "mean_success_rate": round(mean, 4),
        "stddev": round(stddev, 4),
    }


# ---- threshold adjustment --------------------------------------------------


def compute_adjustment(conn: sqlite3.Connection) -> dict:
    """Analyze recent outcomes and suggest threshold adjustments.

    Looks at sessions from the last 7 days.  If >80% of low-confidence
    outputs got accepted (exit_code 0), the threshold can be relaxed.
    If >20% of high-confidence outputs got rejected (exit_code != 0),
    the threshold should be tightened.
    """
    threshold_info = compute_threshold(conn)
    current_threshold = threshold_info["recommended_threshold"]

    # Look at the last 7 days of sessions
    cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()

    rows = conn.execute(
        "SELECT agent, workdir, exit_code, timestamp "
        "FROM sessions WHERE timestamp > ? ORDER BY timestamp DESC",
        (cutoff,),
    ).fetchall()

    if not rows:
        return {
            "current_threshold": current_threshold,
            "suggestion": "no_change",
            "reason": "No recent sessions to analyze (last 7 days).",
            "recent_sessions": 0,
        }

    # Compute confidence for each session's agent+repo combo and classify
    low_confidence_sessions = []
    high_confidence_sessions = []

    # Cache scores to avoid recomputation
    score_cache = {}

    for row in rows:
        cache_key = (row["agent"], row["workdir"])
        if cache_key not in score_cache:
            result = compute_agent_score(conn, row["agent"], row["workdir"])
            score_cache[cache_key] = result["score"]
        score = score_cache[cache_key]

        entry = {
            "agent": row["agent"],
            "repo": row["workdir"],
            "exit_code": row["exit_code"],
            "score": score,
        }

        if score < current_threshold:
            low_confidence_sessions.append(entry)
        else:
            high_confidence_sessions.append(entry)

    # Analyze low-confidence sessions: how many actually succeeded?
    low_total = len(low_confidence_sessions)
    low_accepted = sum(1 for s in low_confidence_sessions if s["exit_code"] == 0)
    low_accept_rate = (low_accepted / low_total * 100) if low_total > 0 else 0

    # Analyze high-confidence sessions: how many failed?
    high_total = len(high_confidence_sessions)
    high_rejected = sum(1 for s in high_confidence_sessions if s["exit_code"] != 0)
    high_reject_rate = (high_rejected / high_total * 100) if high_total > 0 else 0

    suggestion = "no_change"
    reason = "Threshold appears well-calibrated."
    suggested_threshold = current_threshold

    if low_total > 0 and low_accept_rate > 80:
        # Most low-confidence sessions actually succeeded -- threshold is
        # too strict, causing unnecessary escalations.
        suggested_threshold = max(0.1, current_threshold - 0.1)
        suggestion = "relax"
        reason = (
            f"{low_accept_rate:.0f}% of low-confidence sessions (below {current_threshold:.2f}) "
            f"were accepted ({low_accepted}/{low_total}). "
            f"Threshold is too strict -- suggest relaxing to {suggested_threshold:.4f}."
        )
    elif high_total > 0 and high_reject_rate > 20:
        # Too many high-confidence sessions are failing -- threshold needs
        # to be tighter to catch these before they waste time.
        suggested_threshold = min(0.9, current_threshold + 0.1)
        suggestion = "tighten"
        reason = (
            f"{high_reject_rate:.0f}% of high-confidence sessions (above {current_threshold:.2f}) "
            f"were rejected ({high_rejected}/{high_total}). "
            f"Threshold is too loose -- suggest tightening to {suggested_threshold:.4f}."
        )

    return {
        "current_threshold": round(current_threshold, 4),
        "suggested_threshold": round(suggested_threshold, 4),
        "suggestion": suggestion,
        "reason": reason,
        "recent_sessions": len(rows),
        "low_confidence": {
            "total": low_total,
            "accepted": low_accepted,
            "accept_rate": round(low_accept_rate, 1),
        },
        "high_confidence": {
            "total": high_total,
            "rejected": high_rejected,
            "reject_rate": round(high_reject_rate, 1),
        },
    }


# ---- full report ------------------------------------------------------------


def full_report(conn: sqlite3.Connection) -> None:
    """Print a comprehensive confidence report across all agents and repos."""

    # Gather all distinct agents and repos
    agents = [
        r["agent"]
        for r in conn.execute(
            "SELECT DISTINCT agent FROM sessions ORDER BY agent"
        ).fetchall()
    ]
    repos = [
        r["workdir"]
        for r in conn.execute(
            "SELECT DISTINCT workdir FROM sessions ORDER BY workdir"
        ).fetchall()
    ]

    if not agents:
        print("No session data available. Run securetty-failure-db.py --ingest first.")
        return

    # Threshold
    threshold_info = compute_threshold(conn)
    threshold = threshold_info["recommended_threshold"]

    print("=" * 72)
    print("securetty confidence scoring report")
    print("=" * 72)
    print()
    print(f"Recommended escalation threshold: {threshold:.4f}")
    print(f"  Basis: {threshold_info['basis']}")
    print(f"  Total sessions in database: {threshold_info['total_sessions']}")
    print()

    # Per-agent scores
    print("-" * 72)
    print("Per-agent confidence scores:")
    print("-" * 72)
    header = (
        f"{'Agent':<20} {'Score':>8} {'Base':>8} {'Recency':>8} "
        f"{'DurFctr':>8} {'Sess':>6} {'Fail':>6} {'Prov':>5}"
    )
    print(header)

    for agent in agents:
        result = compute_agent_score(conn, agent)
        prov = "yes" if result["provisional"] else "no"
        flag = ""
        if result["score"] < threshold:
            flag = " << below threshold"
        print(
            f"{agent:<20} {result['score']:>8.4f} {result['base_rate']:>8.4f} "
            f"{result['recency_weight']:>8.4f} {result['duration_factor']:>8.4f} "
            f"{result['total_sessions']:>6} {result['total_failures']:>6} "
            f"{prov:>5}{flag}"
        )
    print()

    # Per-repo scores
    print("-" * 72)
    print("Per-repo confidence scores:")
    print("-" * 72)
    print(f"{'Repo':<45} {'Score':>8} {'Sess':>6} {'Fail':>6}")

    for repo in repos:
        result = compute_repo_score(conn, repo)
        flag = ""
        if result["score"] < threshold:
            flag = " << below threshold"
        print(
            f"{repo:<45} {result['score']:>8.4f} "
            f"{result['total_sessions']:>6} {result['total_failures']:>6}{flag}"
        )
    print()

    # Agent x Repo matrix (top combinations by session count)
    print("-" * 72)
    print("Agent x Repo confidence (top combinations):")
    print("-" * 72)

    combos = conn.execute(
        "SELECT agent, workdir, COUNT(*) as c "
        "FROM sessions GROUP BY agent, workdir "
        "ORDER BY c DESC LIMIT 20"
    ).fetchall()

    print(f"{'Agent':<20} {'Repo':<30} {'Score':>8} {'Sess':>6} {'Fail':>6}")
    for combo in combos:
        result = compute_agent_score(conn, combo["agent"], combo["workdir"])
        flag = ""
        if result["score"] < threshold:
            flag = " <<"
        print(
            f"{combo['agent']:<20} {combo['workdir']:<30} "
            f"{result['score']:>8.4f} {result['total_sessions']:>6} "
            f"{result['total_failures']:>6}{flag}"
        )
    print()

    # Adjustment suggestion
    adj = compute_adjustment(conn)
    print("-" * 72)
    print("Threshold adjustment analysis (last 7 days):")
    print("-" * 72)
    print(f"  Recent sessions: {adj['recent_sessions']}")
    if adj["recent_sessions"] > 0:
        lc = adj["low_confidence"]
        hc = adj["high_confidence"]
        print(f"  Low-confidence sessions:  {lc['total']} total, {lc['accepted']} accepted ({lc['accept_rate']:.1f}%)")
        print(f"  High-confidence sessions: {hc['total']} total, {hc['rejected']} rejected ({hc['reject_rate']:.1f}%)")
        print(f"  Suggestion: {adj['suggestion']}")
        print(f"  Reason: {adj['reason']}")
    else:
        print(f"  {adj['reason']}")
    print()

    print("=" * 72)


# ---- CLI entry point --------------------------------------------------------


def cmd_score(args, conn: sqlite3.Connection) -> None:
    """Handle --score <agent> [repo]."""
    agent = args.agent
    repo = args.repo

    result = compute_agent_score(conn, agent, repo)

    if args.json:
        output = {"agent": agent, **result}
        if repo:
            output["repo"] = repo
        print(json.dumps(output, indent=2))
    else:
        label = f"{agent}"
        if repo:
            label += f" @ {repo}"
        prov = " (provisional -- fewer than {0} sessions)".format(MIN_SESSIONS) if result["provisional"] else ""
        print(f"Confidence score for {label}: {result['score']:.4f}{prov}")
        print(f"  base_rate:       {result['base_rate']:.4f}")
        print(f"  recency_weight:  {result['recency_weight']:.4f}")
        print(f"  repo_factor:     {result['repo_factor']:.4f}")
        print(f"  duration_factor: {result['duration_factor']:.4f}")
        print(f"  sessions:        {result['total_sessions']}")
        print(f"  failures:        {result['total_failures']}")
        print(f"  failure_patterns:{result['failure_patterns']}")


def cmd_threshold(args, conn: sqlite3.Connection) -> None:
    """Handle --threshold."""
    result = compute_threshold(conn)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Recommended escalation threshold: {result['recommended_threshold']:.4f}")
        print(f"  Basis: {result['basis']}")
        print(f"  Total sessions: {result['total_sessions']}")


def cmd_adjust(args, conn: sqlite3.Connection) -> None:
    """Handle --adjust."""
    result = compute_adjustment(conn)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"Current threshold:   {result['current_threshold']:.4f}")
        print(f"Suggestion:          {result['suggestion']}")
        print(f"Suggested threshold: {result['suggested_threshold']:.4f}")
        print(f"Reason: {result['reason']}")
        print()
        if result["recent_sessions"] > 0:
            lc = result["low_confidence"]
            hc = result["high_confidence"]
            print(f"Low-confidence sessions (last 7 days):  {lc['total']} total, {lc['accepted']} accepted ({lc['accept_rate']:.1f}%)")
            print(f"High-confidence sessions (last 7 days): {hc['total']} total, {hc['rejected']} rejected ({hc['reject_rate']:.1f}%)")


def cmd_report(args, conn: sqlite3.Connection) -> None:
    """Handle --report."""
    full_report(conn)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="securetty confidence scoring model -- learned escalation thresholds"
    )

    sub = parser.add_subparsers(dest="command")

    # --score
    score_parser = sub.add_parser("score", help="Confidence score for agent [repo]")
    score_parser.add_argument("agent", help="Agent name (e.g. claude, gemini)")
    score_parser.add_argument("repo", nargs="?", default=None, help="Repository/workdir path")
    score_parser.add_argument("--json", action="store_true", help="JSON output")

    # --threshold
    threshold_parser = sub.add_parser("threshold", help="Recommended escalation threshold")
    threshold_parser.add_argument("--json", action="store_true", help="JSON output")

    # --adjust
    adjust_parser = sub.add_parser("adjust", help="Suggest threshold changes")
    adjust_parser.add_argument("--json", action="store_true", help="JSON output")

    # --report
    sub.add_parser("report", help="Full confidence report")

    # Also support legacy --flag style
    parser.add_argument("--score", nargs="+", metavar="AGENT", dest="score_args",
                        help="Confidence score: --score <agent> [repo]")
    parser.add_argument("--threshold", action="store_true", dest="threshold_flag",
                        help="Recommended escalation threshold")
    parser.add_argument("--adjust", action="store_true", dest="adjust_flag",
                        help="Suggest threshold changes")
    parser.add_argument("--report", action="store_true", dest="report_flag",
                        help="Full confidence report")
    parser.add_argument("--json", action="store_true", help="JSON output (for --flag style)")

    args = parser.parse_args()

    # Handle legacy --flag style
    if args.command is None:
        if not any([args.score_args, args.threshold_flag, args.adjust_flag, args.report_flag]):
            parser.print_help()
            sys.exit(1)

    conn = get_db()
    if not _has_sessions_table(conn):
        print(
            "error: sessions table not found in database. "
            "Run securetty-failure-db.py --ingest first.",
            file=sys.stderr,
        )
        conn.close()
        sys.exit(1)

    try:
        if args.command == "score":
            cmd_score(args, conn)
        elif args.command == "threshold":
            cmd_threshold(args, conn)
        elif args.command == "adjust":
            cmd_adjust(args, conn)
        elif args.command == "report":
            cmd_report(args, conn)
        elif args.score_args:
            # Legacy --score <agent> [repo]
            class LegacyArgs:
                pass
            la = LegacyArgs()
            la.agent = args.score_args[0]
            la.repo = args.score_args[1] if len(args.score_args) > 1 else None
            la.json = args.json
            cmd_score(la, conn)
        elif args.threshold_flag:
            class LegacyArgs:
                pass
            la = LegacyArgs()
            la.json = args.json
            cmd_threshold(la, conn)
        elif args.adjust_flag:
            class LegacyArgs:
                pass
            la = LegacyArgs()
            la.json = args.json
            cmd_adjust(la, conn)
        elif args.report_flag:
            class LegacyArgs:
                pass
            la = LegacyArgs()
            cmd_report(la, conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
