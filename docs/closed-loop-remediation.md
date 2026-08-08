# Closed-Loop Remediation

How securetty automatically detects failure patterns, generates SKILL.md patches, propagates fixes across the skill fleet, and maintains an audit trail.

## Overview

The remediation engine (`securetty-remediate.py`) closes the loop between observing agent failures and fixing the instructions that caused them. Instead of manually reviewing failure reports and editing SKILL.md files, the engine scans the failure database, classifies failure patterns, generates additive patches, and propagates successful fixes to other skills that exhibit the same problems.

The pipeline is fully auditable: every patch is logged with the failure pattern that triggered it, a backup of the original file is preserved, and the changelog tracks what changed, when, and why.

## Remediation Pipeline

```
Session runs and exits
        |
        v
securetty-session-logger.sh  -->  ~/.securetty/outcomes/*.jsonl
        |
        v
securetty-failure-db.py --ingest  -->  ~/.securetty/failures.db
        |                                 (sessions + patterns tables)
        v
securetty-remediate.py --scan     -->  Identify agents with >30% failure rate
        |                                 Match agents to SKILL.md files
        |                                 Classify failure mode
        |                                 Generate patch suggestions
        v
securetty-remediate.py --apply    -->  Append sections to SKILL.md files
        |                                 Create .bak backups
        |                                 Log to ~/.securetty/remediations.jsonl
        v
securetty-remediate.py --propagate -->  Find other skills with same pattern
        |                                  Apply equivalent patches fleet-wide
        v
securetty-remediate.py --changelog -->  Audit trail of all changes
```

Each stage is independently runnable. The scan stage is read-only and safe to run at any time. The apply stage requires `--confirm` to modify files. The propagate stage extends fixes that have already been validated on one skill to the rest of the fleet.

## How Patches Are Generated

### Pattern detection

The engine reads the `patterns` table from the failure database, which aggregates per-agent statistics:

- **Total sessions** and **total failures** for the agent
- **Failure rate** as a percentage
- **Average duration** in seconds
- **Most common workdir** where failures occur

Agents exceeding the failure threshold (default 30%, configurable via `SECURETTY_FAILURE_THRESHOLD`) are candidates for remediation.

### Failure classification

Each high-failure agent is classified into one of four categories based on its failure pattern:

| Classification | Criteria | Patch Focus |
|---------------|----------|-------------|
| **critical** | Failure rate > 70% | Pre-flight validation, scope reduction, fallback strategy |
| **high** | Failure rate > 50% | Prerequisite checks, incremental progress, error context capture |
| **timeout** | Average duration > 600s | Time budget, progress checkpoints, scope guards |
| **elevated** | Failure rate > 30% (default) | Retry guidance, diagnostic exits, outcome logging |

### Suggestion templates

For each classification, the engine generates two additive markdown sections:

**Known Issues** -- Documents the observed failure codes, their frequency, and the repositories where failures occur. This gives the agent (and human reviewers) concrete context about what goes wrong.

**Troubleshooting** -- Provides classification-specific remediation steps. For example, a `critical` classification adds pre-flight validation and fallback strategy guidance, while a `timeout` classification adds time-boxing and checkpoint instructions.

### Template example (critical classification)

When a skill has a critical failure rate, the generated Troubleshooting section includes:

```markdown
## Troubleshooting

This skill has a **critical** failure rate (75.0%). Apply the following
checks before each invocation:

1. **Pre-flight validation** -- Verify all required tools and credentials
   are available in the current environment before starting work.
2. **Scope reduction** -- Break complex requests into smaller, independently
   verifiable steps. Fail fast on the first step that cannot be validated.
3. **Fallback strategy** -- If the primary approach fails after one retry,
   switch to a simpler alternative (e.g., direct API calls instead of MCP
   tools) and report what was tried.
```

### Additive-only policy

Patches never remove or modify existing SKILL.md content. They only append new sections. If a "Known Issues" or "Troubleshooting" section already exists in a file, that section is skipped. This ensures that human-authored content, custom troubleshooting steps, and other manual edits are never overwritten.

Before any modification, a backup is created at `<filename>.md.bak`.

## Fleet-Wide Propagation

### The propagation concept

When a fix is applied to one skill and reduces its failure rate, the same failure pattern may exist in other skills. Propagation automatically identifies these sibling skills and applies equivalent patches.

### How propagation works

1. **Load applied remediations** -- Read `~/.securetty/remediations.jsonl` to find patches that have been applied (not dry-run) via `--apply`.

2. **Extract pattern signatures** -- Each applied remediation has a classification (critical, high, timeout, elevated). These classifications serve as pattern signatures.

3. **Scan for matching agents** -- Query the failure database for all agents exceeding the failure threshold. Classify each one.

4. **Match against remediated patterns** -- If an unpatched skill shares the same classification as a remediated skill, it is a propagation candidate.

5. **Generate equivalent patches** -- Build the same "Known Issues" and "Troubleshooting" sections, customized with the target skill's specific failure data (exit codes, workdirs, rates).

6. **Apply with audit trail** -- Each propagation is logged separately with a `propagated_from` field linking it back to the original remediation.

### Propagation example

```
1. securetty-remediate.py --apply --confirm
   -> Patches slack-query SKILL.md (classification: high, 55% failure rate)

2. securetty-remediate.py --propagate --confirm
   -> Finds gmail-query also has "high" classification (52% failure rate)
   -> gmail-query SKILL.md does not have Troubleshooting section
   -> Generates equivalent patch customized for gmail-query's data
   -> Applies patch, logs: propagated_from=slack-query
```

### What propagation does NOT do

- It does not propagate to skills that already have the target sections
- It does not re-propagate to skills that have already been patched (tracked via the remediations log)
- It does not propagate across different classifications (a "critical" fix does not propagate to an "elevated" skill)

## Remediation Changelog and Audit Trail

### Remediations log

Every patch application and propagation is recorded in `~/.securetty/remediations.jsonl`. Each entry contains:

```json
{
    "timestamp": "2025-01-15T14:30:00+00:00",
    "action": "apply",
    "skill": "slack-query",
    "path": "/home/user/src/agent-mcp-skills/slack/SKILL.md",
    "classification": "high",
    "failure_rate": 55.0,
    "total_sessions": 40,
    "total_failures": 22,
    "sections_added": ["Known Issues", "Troubleshooting"],
    "dry_run": false
}
```

Propagation entries include an additional `propagated_from` field:

```json
{
    "timestamp": "2025-01-15T14:35:00+00:00",
    "action": "propagate",
    "skill": "gmail-query",
    "path": "/home/user/src/agent-mcp-skills/gmail/SKILL.md",
    "classification": "high",
    "failure_rate": 52.0,
    "total_sessions": 35,
    "total_failures": 18,
    "sections_added": ["Troubleshooting"],
    "propagated_from": "slack-query",
    "dry_run": false
}
```

### Changelog output

The `--changelog` command reads the remediations log and produces a structured report:

- **Summary statistics** -- total entries, applied patches, propagations, dry runs
- **Entries grouped by date** -- each entry shows action, skill, path, classification, failure rate, and sections added
- **Remediation velocity** -- time span from first to latest remediation, patches per hour
- **Skills with remediations** -- which skills have been patched and how many times

### Backup files

Every patched SKILL.md has a corresponding `.md.bak` file created at the time of modification. To revert a patch:

```bash
cp /path/to/SKILL.md.bak /path/to/SKILL.md
```

## A/B Testing

### Concept

After applying a remediation patch to a SKILL.md, the improvement can be measured by comparing session outcomes before and after the patch.

### Measurement approach

1. **Baseline** -- Record the agent's failure rate, average duration, and confidence score before the patch is applied. The failure database already tracks these metrics.

2. **Apply patch** -- Use `securetty-remediate.py --apply --confirm` to add the remediation sections.

3. **Observation window** -- Allow the agent to accumulate new sessions (recommended: at least 10-20 sessions or 7 days, whichever comes first).

4. **Compare** -- Run `securetty-failure-db.py --report` and `securetty-confidence.py --report` to compare post-patch metrics against the baseline.

### What to measure

| Metric | Source | Better means |
|--------|--------|-------------|
| Failure rate | `securetty-failure-db.py --report` | Lower percentage |
| Confidence score | `securetty-confidence.py --score <agent>` | Higher score |
| Average duration | `securetty-failure-db.py --report` | Shorter (for timeout remediations) |
| Failure pattern count | `securetty-confidence.py --score <agent>` | Fewer distinct exit codes |

### Rollback decision

If the failure rate does not improve after the observation window, the patch may not be addressing the root cause. In that case:

1. Restore the backup: `cp SKILL.md.bak SKILL.md`
2. Investigate the failure logs more deeply with `securetty-failure-db.py --suggest`
3. Consider manual, targeted edits to the SKILL.md rather than template-based patches

The remediation changelog provides the audit trail needed to identify which patches were applied and when, making rollback decisions traceable.

## Remediation Velocity

Remediation velocity measures how quickly the system moves from detecting a failure pattern to applying a fix. The `--changelog` output includes this metric.

### Components of velocity

```
Detection time:    Time from first failure to pattern appearing in DB
                   (depends on --ingest frequency)

Analysis time:     Time from pattern detection to --scan identifying it
                   (immediate once --scan runs)

Application time:  Time from scan to --apply --confirm
                   (depends on operator review)

Propagation time:  Time from apply to --propagate
                   (immediate once --propagate runs)

Validation time:   Time from apply to measurable improvement
                   (depends on session volume, typically 1-7 days)
```

### Improving velocity

- **Automate ingestion** -- Run `securetty-failure-db.py --ingest` on a schedule (e.g., cron every hour)
- **Automate scanning** -- Run `securetty-remediate.py --scan` after each ingestion to surface new candidates
- **Review and apply** -- The `--apply` step intentionally requires `--confirm` to keep a human in the loop
- **Propagate aggressively** -- Once a fix is validated on one skill, propagate immediately to reduce fleet-wide failure rates

## CLI Reference

### Scan for remediation candidates

```bash
# Identify agents with >30% failure rate, show patch suggestions
securetty-remediate.py --scan

# Preview mode (no database reads are affected either way; scan is read-only)
securetty-remediate.py --scan --dry-run
```

### Apply patches

```bash
# Preview what would change
securetty-remediate.py --apply --dry-run

# Apply patches (creates .bak backups, logs to remediations.jsonl)
securetty-remediate.py --apply --confirm
```

### Propagate fixes fleet-wide

```bash
# Preview propagation targets
securetty-remediate.py --propagate --dry-run

# Apply propagated patches
securetty-remediate.py --propagate --confirm
```

### View changelog

```bash
securetty-remediate.py --changelog
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECURETTY_FAILURE_DB` | `~/.securetty/failures.db` | Path to the failure database |
| `SECURETTY_BUILTIN_SKILLS` | `~/src/agent-mcp-skills` | Directory containing built-in skill definitions |
| `SECURETTY_USER_SKILLS` | `~/.securetty/skills` | Directory containing user-installed skill definitions |
| `SECURETTY_REMEDIATIONS_LOG` | `~/.securetty/remediations.jsonl` | Path to the remediations audit log |
| `SECURETTY_FAILURE_THRESHOLD` | `30.0` | Failure rate percentage above which agents are remediated |

## Related Documentation

- [confidence-scoring.md](confidence-scoring.md) -- Confidence scoring model and escalation thresholds
- [escalation-gates.md](escalation-gates.md) -- Session-level escalation controls
- [skill-marketplace.md](skill-marketplace.md) -- Skill discovery and management
- `roles/containers/files/securetty-failure-db.py` -- Failure database ingest and pattern detection
- `roles/containers/files/securetty-confidence.py` -- Confidence scoring computation
- `roles/containers/files/securetty-remediate.py` -- Remediation engine (this document)
