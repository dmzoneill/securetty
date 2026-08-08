# CI Eval Gates

How securetty enforces quality gates on instruction files and skill descriptions via automated evals in CI.

## What Triggers Eval Runs

The eval workflow (`.github/workflows/eval.yml`) runs on pull requests that touch any of the following paths:

- `AGENTS.md` -- the primary agent instruction file
- `CLAUDE.md` -- Claude-specific configuration
- `evals/**` -- eval configs, assertions, and budget settings
- `roles/containers/files/workflows.toon` -- workflow definitions that feed into agent behavior

Other changes (Ansible roles, Containerfiles, scripts) do not trigger evals. This keeps eval costs proportional to instruction-surface changes only.

## Pass Rate Thresholds

The CI gate requires an 80% overall pass rate across all assertions in the eval suite. If the pass rate falls below this threshold, the workflow exits with a non-zero status and the PR check fails.

### Adjusting the threshold

The threshold is set in `.github/workflows/eval.yml` in the "Check pass rate" step:

```bash
if (( $(echo "$pass_rate < 0.8" | bc -l) )); then
```

Change `0.8` to your desired minimum (e.g. `0.9` for a stricter gate). For local runs, the `securetty-eval.sh` runner accepts `--threshold`:

```bash
securetty-eval.sh run --threshold 0.9
```

### Recommended thresholds by context

| Context | Threshold | Rationale |
|---------|-----------|-----------|
| Development PRs | 0.8 | Catch regressions without blocking iteration |
| Pre-release | 0.9 | Higher bar for instruction quality before tagging |
| Infrastructure evals | 1.0 | Health checks are deterministic and must all pass |

## Cross-Skill Regression Detection

The eval suite tests quality dimensions that span multiple skills and instruction sections. When a change to AGENTS.md improves one area (e.g. adding a new agent workflow) but degrades another (e.g. making the document exceed the 150-line budget), the cross-cutting assertions catch the regression.

Key cross-skill assertions include:

- **Consistency** -- terminology must remain uniform across all sections
- **Conciseness** -- the document must stay within its line budget even after additions
- **Onboarding** -- the overall newcomer experience must not degrade
- **Cross-references** -- links to design documents must remain intact
- **Error format consistency** -- all MCP skills must follow the same error response pattern

Because these assertions use LLM-as-judge rubrics, they evaluate semantic quality rather than just keyword presence. A change that technically adds the right keywords but introduces contradictions or unclear language will still fail the rubric.

## Adding Evals for New Skills

### Adding a skill quality test

Edit `evals/skill-quality.yaml` and append a new test case:

```yaml
- description: Short description of the quality dimension
  vars:
    question: >
      A question the LLM evaluator answers about AGENTS.md.
  assert:
    - type: llm-rubric
      value: >
        Rubric describing what a good answer looks like.
        Be specific about what earns full marks.
    - type: contains
      value: "expected keyword"
```

### Adding an MCP functionality test

Edit `evals/mcp-functionality.yaml` and append a new test case:

```yaml
- description: Short description of expected behavior
  vars:
    skill_name: new-skill-name
    skill_description: >
      What the skill does, its API surface, and authentication.
    question: >
      Question about expected response format or behavior.
  assert:
    - type: llm-rubric
      value: >
        Rubric for evaluating the response.
    - type: contains
      value: "expected field name"
```

### Verifying locally before pushing

Run the eval suite locally to confirm new tests pass before opening a PR:

```bash
securetty-eval.sh run evals/skill-quality.yaml
securetty-eval.sh run evals/mcp-functionality.yaml
```

## Eval Results as PR Artifacts

Every eval run uploads `evals/results.json` as a GitHub Actions artifact named `eval-results`, regardless of whether the eval passed or failed (the upload step uses `if: always()`).

To download results from a completed workflow run:

```bash
gh run download <run-id> -n eval-results
```

The results file contains per-assertion pass/fail data, the overall pass rate, and the LLM-judge reasoning for rubric assertions. This is useful for debugging why a specific assertion failed and for tracking quality trends across PRs.

## Budget Controls

Eval budgets are configured in `evals/budget.yaml` following Working Group best practices for cost containment:

```yaml
max_eval_cost_per_pr: 1.00          # Maximum USD spend per PR eval run
max_eval_duration_minutes: 10       # Hard timeout for the entire eval suite
provider_limits:
  anthropic: 0.50                   # Max spend on Anthropic models per run
  openai: 0.50                      # Max spend on OpenAI models per run
skip_expensive_evals_on_draft: true  # Skip LLM-rubric evals on draft PRs
```

These limits prevent runaway costs from large eval suites or misconfigured test cases. The `skip_expensive_evals_on_draft` flag allows draft PRs to run only deterministic assertions (contains, equals), skipping LLM-as-judge rubrics that incur API costs.

To adjust limits, edit `evals/budget.yaml` directly. The eval runner and CI workflow reference this file for cost decisions.

## Eval Gates and Escalation

Failed evals integrate with securetty's escalation model (see [escalation-gates.md](escalation-gates.md)):

1. **Eval failure signals high risk.** A PR that fails the eval gate has demonstrably degraded instruction quality or skill descriptions. This is treated as a high-risk change.
2. **High risk triggers human review.** Per the escalation gate configuration, high-risk changes require explicit operator approval before merging. A failed eval check prevents auto-merge and surfaces in the PR checks summary.
3. **Eval results inform review scope.** Reviewers can download the eval artifact to see exactly which quality dimensions regressed, focusing review effort on the affected areas rather than re-reading the entire instruction file.

The flow is:

```
PR opened → eval runs → pass rate checked
  ├─ >= 80%: check passes, normal review process
  └─ < 80%: check fails → high risk → human review required
```

This ensures that instruction quality regressions are caught before merge, and that the operator always has visibility into what degraded and why.
