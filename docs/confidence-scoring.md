# Confidence Scoring

How securetty learns from historical session outcomes to make smarter escalation decisions.

## Overview

The confidence scoring model (`securetty-confidence.py`) reads the failure database (`~/.securetty/failures.db`) and computes per-agent, per-repo confidence scores between 0.0 and 1.0. These scores feed into escalation decisions alongside the risk classifier: a low-confidence agent working on a high-failure repo gets escalated sooner than a high-confidence agent on a clean repo.

The system is self-tuning. As more session outcomes accumulate, the recommended escalation threshold adjusts automatically based on whether the model's predictions align with actual outcomes.

## How Confidence Scores Are Calculated

The core formula is:

```
confidence = base_rate * recency_weight * repo_factor * duration_factor * pattern_penalty
```

Each component is described below.

### base_rate (0.0-1.0)

The agent's weighted success rate, computed from all sessions in the failure database. Success means `exit_code == 0`. This is a recency-weighted average, not a simple ratio -- recent sessions contribute more than old ones.

```
base_rate = sum(weight_i * success_i) / sum(weight_i)
```

Where `weight_i` is the recency weight for session `i` (see below).

### recency_weight (0.0-1.0)

Exponential decay giving more importance to recent sessions. Each session's weight is:

```
weight = exp(-ln(2) * age_days / half_life)
```

The half-life defaults to 14 days (`SECURETTY_CONFIDENCE_HALFLIFE` env var). A session from today has weight 1.0; a session from 14 days ago has weight 0.5; a session from 28 days ago has weight 0.25.

The `recency_weight` in the report is the average weight across all sessions for that agent, reflecting how fresh the data is. A value near 1.0 means most data is recent; a value near 0.5 means the data is mostly stale.

### repo_factor (0.3-1.2)

A repo-specific modifier that compares the agent's failure rate in a specific repo against its global failure rate.

- If the repo failure rate exceeds the global rate, `repo_factor` is `1 / excess_ratio`, floored at 0.3.
- If the repo failure rate is below the global rate, `repo_factor` gets a slight bonus up to 1.2.
- When no repo is specified, `repo_factor` is 1.0.

Repos with chronic problems pull scores down; repos where the agent consistently succeeds get a small boost.

### duration_factor (0.5-1.0)

Penalises agents with long average session durations. Sessions under the penalty threshold (default 600 seconds, configurable via `SECURETTY_CONFIDENCE_DURATION_PENALTY`) get a factor of 1.0. Above that, the factor decreases linearly, bottoming out at 0.5 at 3x the threshold.

Long-running sessions correlate with agents struggling to converge. The penalty ensures the score reflects this.

### pattern_penalty (0.7-1.0)

Agents that fail in diverse ways (many distinct exit codes) are less predictable. Each distinct failure exit code reduces the score by 5%, down to a floor of 0.7.

An agent that always fails with exit code 1 is more predictable (and fixable) than one that fails with codes 1, 2, 127, and 137.

## Escalation Threshold

The recommended escalation threshold is computed from the population of agent success rates:

```
threshold = median(agent_success_rates) - stddev(agent_success_rates)
```

This sets the bar at a point where agents scoring below it are performing meaningfully worse than the population. When no historical data exists, the default threshold is 0.6 (configurable via `SECURETTY_CONFIDENCE_DEFAULT_THRESHOLD`).

Agents and agent+repo combinations scoring below the threshold should trigger escalation -- either promoting the escalation action from `warn` to `pause`, or tightening gate thresholds.

## How Thresholds Adapt Over Time

The `--adjust` command analyzes the last 7 days of session outcomes and compares predictions against reality.

### Relaxing the threshold

If more than 80% of sessions that scored below the current threshold actually succeeded (exit_code 0), the model is being too cautious. The threshold was flagging sessions for escalation that did not need it. The suggestion is to reduce the threshold by 0.1.

**Example:** Current threshold is 0.6. Over the last week, 85% of sessions scoring below 0.6 completed successfully. Suggestion: relax to 0.5.

### Tightening the threshold

If more than 20% of sessions that scored above the current threshold actually failed (exit_code != 0), the model is too permissive. Sessions that should have been escalated were allowed to proceed and failed. The suggestion is to increase the threshold by 0.1.

**Example:** Current threshold is 0.5. Over the last week, 25% of sessions scoring above 0.5 failed. Suggestion: tighten to 0.6.

### Feedback loop

Over time, this creates a feedback loop:

1. Sessions complete and their outcomes are logged by `securetty-session-logger.sh`.
2. `securetty-failure-db.py --ingest` imports the outcomes into the database.
3. `securetty-confidence.py --adjust` analyzes whether the threshold is well-calibrated.
4. The operator (or automation) adjusts the threshold.
5. Future escalation decisions use the new threshold.

This is a human-in-the-loop system. The model suggests; the operator decides. There is no automatic threshold modification.

## Integration with Risk Classifier

The risk classifier (`securetty-risk-classifier.sh`) and the confidence scorer work together to make escalation decisions. The risk classifier categorizes the *change* (what files are being modified); the confidence scorer categorizes the *agent and repo* (how reliable this combination has been historically).

The combined decision matrix:

| Risk Level | High Confidence (above threshold) | Low Confidence (below threshold) |
|-----------|----------------------------------|----------------------------------|
| **High** | `pause` -- risky change but reliable agent, human reviews before proceeding | `abort` -- risky change and unreliable agent, stop immediately |
| **Medium** | `warn` -- standard change with reliable agent, proceed with notice | `pause` -- standard change but unreliable agent, human confirms |
| **Low** | no action -- safe change with reliable agent | `warn` -- safe change but unreliable agent, log a notice |

This refines the tier-based escalation documented in [security-tiers.md](security-tiers.md). Without confidence scoring, all agents at the same risk level get the same treatment. With confidence scoring, agents that have earned trust get more latitude while agents with poor track records face stricter gates.

### Example integration flow

```
1. Agent starts session on ~/src/myproject
2. Risk classifier inspects the git diff -> "medium"
3. Confidence scorer: securetty-confidence.py --score claude ~/src/myproject -> 0.82
4. Threshold: 0.55
5. 0.82 > 0.55 -> high confidence
6. Combined decision: medium risk + high confidence = "warn"
7. Session proceeds with a logged warning
```

```
1. Agent starts session on ~/src/auth-service
2. Risk classifier inspects the git diff -> "high"
3. Confidence scorer: securetty-confidence.py --score gemini ~/src/auth-service -> 0.31
4. Threshold: 0.55
5. 0.31 < 0.55 -> low confidence
6. Combined decision: high risk + low confidence = "abort"
7. Session terminated, operator must run manually
```

## Manual Overrides

### Per-agent override

Set the `SECURETTY_CONFIDENCE_OVERRIDE_<AGENT>` environment variable to force a specific confidence score for an agent, bypassing the model entirely:

```bash
# Force claude to always score 0.9 (high confidence)
export SECURETTY_CONFIDENCE_OVERRIDE_CLAUDE=0.9

# Force gemini to always score 0.3 (low confidence, will escalate)
export SECURETTY_CONFIDENCE_OVERRIDE_GEMINI=0.3
```

### Per-repo override

Set `SECURETTY_CONFIDENCE_REPO_OVERRIDE` to a colon-separated list of `repo=score` pairs:

```bash
export SECURETTY_CONFIDENCE_REPO_OVERRIDE="~/src/legacy-app=0.3:~/src/stable-lib=0.95"
```

### Disable confidence scoring

Set the threshold to 0.0 to effectively disable confidence-based escalation (all agents will score above the threshold):

```bash
export SECURETTY_CONFIDENCE_DEFAULT_THRESHOLD=0.0
```

### Tuning parameters

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `SECURETTY_FAILURE_DB` | `~/.securetty/failures.db` | Path to the failure database |
| `SECURETTY_CONFIDENCE_HALFLIFE` | `14` | Recency half-life in days |
| `SECURETTY_CONFIDENCE_MIN_SESSIONS` | `5` | Minimum sessions before score is non-provisional |
| `SECURETTY_CONFIDENCE_DEFAULT_THRESHOLD` | `0.6` | Default threshold when no data exists |
| `SECURETTY_CONFIDENCE_DURATION_PENALTY` | `600` | Duration (seconds) above which agents are penalised |

## CLI Usage

### Score a specific agent

```bash
# Agent-level confidence
securetty-confidence.py --score claude

# Agent + repo combination
securetty-confidence.py --score claude ~/src/myproject

# JSON output for scripting
securetty-confidence.py --score claude ~/src/myproject --json
```

### Check the recommended threshold

```bash
securetty-confidence.py --threshold
securetty-confidence.py --threshold --json
```

### Get adjustment suggestions

```bash
securetty-confidence.py --adjust
securetty-confidence.py --adjust --json
```

### Full report

```bash
securetty-confidence.py --report
```

The report includes per-agent scores, per-repo scores, the top agent-repo combinations, and threshold adjustment analysis.

## Relationship to WG HAERCVM E Dimension

The WG HAERCVM framework evaluates AI agent trustworthiness across multiple dimensions. The **E (Effectiveness)** dimension measures how well an agent accomplishes its assigned tasks -- precisely what the confidence scoring model quantifies.

### Mapping to E dimension scoring

| HAERCVM E Criterion | securetty Confidence Component |
|---------------------|-------------------------------|
| Task completion rate | `base_rate` -- weighted success rate |
| Consistency over time | `recency_weight` -- are recent results consistent with historical? |
| Context sensitivity | `repo_factor` -- does the agent perform differently across repos? |
| Efficiency | `duration_factor` -- does the agent converge in reasonable time? |
| Failure predictability | `pattern_penalty` -- are failures diverse or concentrated? |

The composite confidence score maps to a WG HAERCVM E score as follows:

| Confidence Score | E Dimension Rating | Interpretation |
|-----------------|-------------------|----------------|
| 0.8 - 1.0 | High effectiveness | Agent reliably completes tasks; minimal oversight needed |
| 0.6 - 0.8 | Moderate effectiveness | Agent usually succeeds but warrants monitoring |
| 0.4 - 0.6 | Low effectiveness | Agent struggles; escalation recommended |
| 0.0 - 0.4 | Insufficient effectiveness | Agent should not operate autonomously |

The confidence scoring model provides empirical, data-driven evidence for E dimension assessments rather than relying on subjective evaluation.  When an agent's confidence score drops below the escalation threshold, that is a quantitative signal that its E dimension rating has degraded and additional human oversight is warranted.

## Data Flow

```
Session runs
    |
    v
securetty-session-logger.sh  --> ~/.securetty/outcomes/*.jsonl
    |
    v
securetty-failure-db.py --ingest  --> ~/.securetty/failures.db
    |
    v
securetty-confidence.py --score/--threshold/--adjust/--report
    |
    v
Escalation decision (combined with risk classifier output)
```

## Related Documentation

- [escalation-gates.md](escalation-gates.md) -- Session-level escalation controls
- [security-tiers.md](security-tiers.md) -- Graduated risk-adaptive routing
- [trust-model.md](trust-model.md) -- Input trust classification
- `roles/escalation/defaults/main.yml` -- Escalation gate configuration
- `roles/containers/files/securetty-failure-db.py` -- Failure database ingest and patterns
- `roles/containers/files/securetty-risk-classifier.sh` -- Risk classification of git diffs
