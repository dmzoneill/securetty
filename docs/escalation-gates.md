# Escalation Gates

How securetty decides when autonomous agent work should stop and a human should take over.

## What Are Escalation Gates

An escalation gate is a runtime check that fires during an agent session. When a gate condition is met -- the diff is too large, the session has run too long, a security-sensitive file was touched -- securetty intervenes. Depending on configuration the intervention is a warning, a pause that waits for operator confirmation, or an immediate abort.

Gates exist because AI agents can run indefinitely, produce unbounded diffs, and touch files they should not modify without review. The operator sets thresholds; the system enforces them.

## Supported Gates

### Max-turns limit

Caps the number of agentic loop iterations (tool calls / reasoning steps). Prevents runaway sessions that burn tokens without converging on a solution.

Default: `50` turns.

### Max duration

Wall-clock time limit in minutes. The agent is interrupted after this duration regardless of progress.

Default: `30` minutes.

### Test coverage threshold

Minimum test coverage percentage for the changed code. If coverage falls below the threshold after the agent finishes, the session pauses for human review rather than allowing a self-merge.

Default: `70`%.

### Diff size limit

Maximum number of lines changed across all files in the session diff. Large diffs are harder to review, more likely to contain regressions, and more expensive to roll back.

Default: `500` lines.

### High-risk file patterns

Glob patterns matched against the list of changed files. Any match triggers an escalation regardless of other gate values. This is the safety net for files that always need human sign-off: authentication logic, cryptographic material, security configuration.

Default patterns:

```
*/auth/*
*/security/*
*/crypto/*
*.key
*.pem
```

## Planned CLI Flags

These flags are not yet wired into `securetty.sh.j2`. They document the intended interface.

### `securetty run --max-turns N`

Override the configured max-turns gate for a single session.

```bash
# Allow up to 100 turns for a complex refactor
securetty run claude --max-turns 100

# Limit to 10 turns for a quick fix
securetty run-work gemini --max-turns 10
```

When `--max-turns` is not provided, the value from `securetty_escalation.max_turns` applies.

### `securetty run --risk high|medium|low`

Declare the risk level of the task. This affects which gates are active and how strict they are.

| Risk level | Behavior |
|-----------|----------|
| **low** | All gates use their configured defaults. `escalation_action` applies as-is. |
| **medium** | High-risk file patterns are enforced. Diff limit is halved. `escalation_action` is promoted to `pause` if set to `warn`. |
| **high** | All gates are enforced at reduced thresholds. `escalation_action` is forced to `pause`. Any high-risk pattern match forces `abort`. |

```bash
# Declare a high-risk session (auth changes)
securetty run claude --risk high

# Low-risk documentation pass
securetty run-work gemini --risk low
```

## Configuration

Escalation defaults live in `roles/escalation/defaults/main.yml`. To override, add a `securetty_escalation` section to `group_vars/all.yml`:

```yaml
securetty_escalation:
  max_turns: 50
  max_duration_minutes: 30
  test_coverage_threshold: 70
  max_diff_lines: 500
  high_risk_patterns:
    - "*/auth/*"
    - "*/security/*"
    - "*/crypto/*"
    - "*.key"
    - "*.pem"
  escalation_action: warn    # warn | pause | abort
```

### Configuration schema

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_turns` | int | `50` | Maximum agentic loop iterations |
| `max_duration_minutes` | int | `30` | Wall-clock session cap |
| `test_coverage_threshold` | int | `70` | Minimum coverage % to skip human review |
| `max_diff_lines` | int | `500` | Maximum diff size in lines |
| `high_risk_patterns` | list[str] | see above | Glob patterns that always trigger escalation |
| `escalation_action` | enum | `warn` | Action on gate trip: `warn`, `pause`, or `abort` |

The Ansible merge strategy means you only need to specify keys you want to change. Unspecified keys inherit the role defaults.

## Integration with ai-guardian (#54)

securetty already installs [ai-guardian](https://pypi.org/project/ai-guardian/) in the dev container (see `securetty_pip_tools` in `group_vars/all.yml` and `roles/containers/templates/Containerfile.dev.j2`). ai-guardian provides its own pre-commit and pre-push hooks that scan for security issues.

Escalation gates complement ai-guardian by adding session-level controls:

- **ai-guardian** catches security issues at commit/push time (file-level, static analysis).
- **Escalation gates** catch session-level problems before a commit is even attempted (turn count, diff size, duration, file-pattern matching).

When both are active, the defense is layered:

1. Escalation gates fire during the session, before any git operation.
2. ai-guardian fires at `git commit` / `git push`, catching anything the session gates missed.
3. If either layer trips at `high` risk, the operator must explicitly approve before the change lands.

The planned integration path:

- Escalation gate results (which gates tripped, at what values) will be passed to ai-guardian as context via environment variables or a status file.
- ai-guardian can then adjust its own strictness based on the session risk level declared via `--risk`.
- Both systems log to `~/.securetty/cost/` for audit and cost tracking.

## Escalation Action Behavior

| Action | Session continues? | Operator notified? | Git operations blocked? |
|--------|-------------------|-------------------|------------------------|
| `warn` | Yes | Console warning printed | No |
| `pause` | Halted until operator confirms | Yes (interactive prompt) | Yes, until confirmed |
| `abort` | Terminated immediately | Yes (exit message) | Yes (session killed) |

## Design Rationale

Escalation gates follow the same principle as securetty's egress filtering: default-deny with explicit allowlisting. Rather than trusting agents to self-limit, the system enforces boundaries. The operator can relax constraints per-session (`--max-turns`, `--risk low`) but the defaults are conservative.

This aligns with the securetty trust model (see [docs/trust-model.md](trust-model.md)): AI agent processes are classified as **semi-trusted**. Escalation gates are one more control applied to semi-trusted workloads, alongside container isolation, capability dropping, and egress filtering.
