# Evaluation Framework

securetty uses [promptfoo](https://www.promptfoo.dev/) to run automated quality evaluations against instruction files and MCP skill descriptions. Evaluations combine deterministic assertions (exact match, substring) with LLM-as-judge rubric scoring to catch both structural and semantic regressions.

## What the Framework Tests

### Skill Quality (`evals/skill-quality.yaml`)

Tests AGENTS.md across 10 quality dimensions:

- **Clarity** -- Can a developer follow the instructions to add a new agent?
- **Completeness** -- Are all key commands and lifecycle operations documented?
- **Actionability** -- Are rules specific enough to follow without clarification?
- **Architecture** -- Does it explain container layers and service topology?
- **Security posture** -- Are credential isolation, egress, and quarantine conveyed?
- **Conciseness** -- Does it stay within the 150-line budget?
- **Cross-references** -- Are related design documents linked?
- **Common changes** -- Are the four key change workflows covered?
- **Consistency** -- Is terminology used uniformly throughout?
- **Onboarding** -- Can a newcomer get started from this document alone?

### MCP Functionality (`evals/mcp-functionality.yaml`)

Tests MCP skill descriptions for 10 capability and format expectations:

- **JIRA** -- Issue creation fields, JQL search result structure
- **GitLab** -- MR listing metadata, pipeline status representation
- **GitHub** -- PR review information, filtering capabilities
- **Slack** -- Search result context and thread representation
- **Credential proxy** -- Health endpoint format and mTLS requirements
- **Headroom** -- Token compression request/response format
- **Cross-skill** -- Consistent error response format across all skills

### Infrastructure (`evals/promptfooconfig.yaml`)

Tests securetty service health (credential proxy endpoint checks). These are
deterministic tests that do not require an LLM provider.

## Running Evals

### Locally

Run all quality evals:

```bash
securetty-eval.sh run
```

Run a specific eval config:

```bash
securetty-eval.sh run evals/skill-quality.yaml
```

Set a stricter pass threshold:

```bash
securetty-eval.sh run --threshold 0.9
```

List available configs:

```bash
securetty-eval.sh list
```

View last results:

```bash
securetty-eval.sh report
securetty-eval.sh report --json
```

### Via Make

Run the infrastructure eval (credential proxy health):

```bash
make eval
```

### In CI

Add to a CI pipeline as a quality gate:

```yaml
eval:
  stage: test
  script:
    - securetty-eval.sh run --threshold 0.8
  allow_failure: false
```

The script exits with code 1 if the overall pass rate falls below the threshold, making it suitable for CI gate checks.

## Results Storage

Results are stored under `~/.securetty/evals/YYYY-MM-DD/`:

```
~/.securetty/evals/
  2026-08-08/
    summary.json         # Overall run summary
    skill-quality.json   # Per-config results
    mcp-functionality.json
```

The `summary.json` file contains:

```json
{
  "timestamp": "2026-08-08T14:30:00",
  "threshold": 0.8,
  "total_tests": 20,
  "passed": 18,
  "failed": 2,
  "pass_rate": 0.9,
  "below_threshold": false,
  "failed_configs": [],
  "results_dir": "/home/user/.securetty/evals/2026-08-08"
}
```

## Adding New Test Cases

### Adding a skill quality test

Edit `evals/skill-quality.yaml` and add a new entry to the `tests` list:

```yaml
- description: Short description of what this tests
  vars:
    question: >
      The question the LLM evaluator will answer about AGENTS.md.
  assert:
    - type: llm-rubric
      value: >
        Rubric describing what a good answer looks like.
        Be specific about what constitutes full marks.
    - type: contains            # Optional deterministic check
      value: "expected substring"
```

### Adding an MCP functionality test

Edit `evals/mcp-functionality.yaml` and add a new entry:

```yaml
- description: Short description
  vars:
    skill_name: skill-name
    skill_description: >
      What the skill does and how it works.
    question: >
      Question about expected behavior or response format.
  assert:
    - type: llm-rubric
      value: >
        Rubric for evaluating the response.
    - type: contains
      value: "expected field or keyword"
```

## Assertion Types

### LLM-as-judge (`llm-rubric`)

Uses an LLM to evaluate whether a response meets a rubric. Best for:

- Semantic quality (is the explanation clear?)
- Completeness (are all important concepts covered?)
- Actionability (could someone follow these instructions?)

Rubrics should be specific about what earns full marks and what causes deductions. Avoid vague criteria like "good quality" -- instead describe exactly what elements must be present.

### Deterministic (`contains`, `equals`)

Exact or substring matching against response text. Best for:

- Verifying specific terms or field names appear
- Checking that required keywords are present
- Validating structured output format

These are fast, reproducible, and do not require LLM API calls. Use them as a baseline alongside LLM-rubric assertions.

### Combining both

Most test cases should use both types. Deterministic assertions catch obvious omissions (a missing keyword), while LLM-rubric assertions evaluate whether the information is coherent and well-structured. If a response contains all the right keywords but is incomprehensible, the rubric assertion will catch it.

## Quality Benchmarks and Thresholds

| Metric | Minimum | Target | Notes |
|--------|---------|--------|-------|
| Overall pass rate | 80% | 90%+ | CI gate threshold |
| Skill quality pass rate | 80% | 90%+ | AGENTS.md quality |
| MCP functionality pass rate | 80% | 90%+ | Skill description accuracy |
| Infrastructure pass rate | 100% | 100% | Health checks must pass |

The default threshold (`--threshold 0.8`) requires 80% of all assertions to pass. For production releases, consider raising to 0.9.

Thresholds can be set per-run:

```bash
# Development -- lenient
securetty-eval.sh run --threshold 0.7

# Pre-merge -- standard
securetty-eval.sh run --threshold 0.8

# Release -- strict
securetty-eval.sh run --threshold 0.9
```
