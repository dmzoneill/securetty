# Security Tiers -- Graduated Risk-Adaptive Routing

securetty uses three security tiers that adapt container isolation based on the risk profile of the work being done. A risk classifier inspects the git diff before a session starts and selects the appropriate tier automatically. The operator can override this with `--risk`.

## Tiers

### Tier 1 -- Low Risk

For documentation, tests, and formatting changes where the blast radius of a compromised agent is minimal.

| Control | Setting |
|---------|---------|
| Credentials | Full credentials available (all `.env` files mounted) |
| Network | Full egress whitelist (all approved domains) |
| Filesystem | Read-write mounts on `~/src/` and agent config dirs |
| Escalation | Default gate thresholds; `escalation_action` as configured |
| Use case | Docs updates, test additions, comment edits, linting |

### Tier 2 -- Medium Risk (Current Default)

The standard securetty posture. This is what every session gets today and what the existing documentation in [security-levels.md](security-levels.md) describes.

| Control | Setting |
|---------|---------|
| Credentials | Credential proxy via OmniRoute; per-service `.env` files (least-privilege) |
| Network | nftables egress whitelist with default-drop; ~50 approved domains |
| Filesystem | Read-only root filesystem; explicit writable tmpfs for `/tmp`, `/run`, caches |
| Capabilities | `cap_drop: ALL` (only `SYS_NICE` for compositor); `no-new-privileges` |
| Escalation | High-risk file patterns enforced; diff limit halved; `warn` promoted to `pause` |
| Use case | Feature development, bug fixes, config changes, API work |

### Tier 3 -- High Risk

Maximum lockdown for changes touching authentication, cryptographic material, security logic, CI pipelines, or container definitions.

| Control | Setting |
|---------|---------|
| Credentials | Zero credentials in container; no `.env` files mounted; no SSH/GPG agent forwarding |
| Network | No network except AI provider endpoint (OmniRoute on localhost only) |
| Filesystem | All mounts read-only, including `~/src/` (agent produces a patch file instead of direct writes) |
| Capabilities | Same as Tier 2 plus additional procfs restrictions |
| Escalation | All gates at reduced thresholds; `escalation_action` forced to `pause`; any high-risk pattern match forces `abort` |
| Use case | Auth logic, crypto changes, key rotation, Dockerfile/CI edits |

## CLI Usage

### Explicit risk declaration

```bash
# High-risk session -- Tier 3 lockdown
securetty run claude --risk high

# Medium-risk session -- standard securetty (Tier 2)
securetty run claude --risk medium

# Low-risk documentation pass -- Tier 1
securetty run-work gemini --risk low
```

### Automatic risk classification

When `--risk` is not provided, securetty runs the risk classifier (`securetty-risk-classifier.sh`) against the git state of the target workdir. The classifier inspects staged changes (or the last commit if nothing is staged) and categorizes each changed file path.

```bash
# Auto-classify: the classifier inspects ~/src/myproject and selects the tier
securetty run claude ~/src/myproject

# Equivalent to running the classifier directly:
securetty-risk-classifier.sh ~/src/myproject
# Output: high, medium, or low
```

### Classifying a specific diff

The classifier also accepts a pre-generated diff file:

```bash
git diff --cached > /tmp/my.diff
securetty-risk-classifier.sh --diff /tmp/my.diff
```

## Risk Classification Rules

The classifier uses path-based pattern matching against the list of changed files.

### High risk (any match promotes entire diff to high)

| Pattern | What it catches |
|---------|----------------|
| `auth/` | Authentication and authorization logic |
| `security/` | Security configuration and policies |
| `crypto/` | Cryptographic implementations |
| `*.key`, `*.pem` | Key material and certificates |
| `Dockerfile*`, `Containerfile*` | Container image definitions |
| `.github/workflows/`, `.gitlab-ci*`, `Jenkinsfile`, `.circleci/` | CI/CD pipeline configuration |

These patterns are aligned with `securetty_escalation.high_risk_patterns` in `roles/escalation/defaults/main.yml`.

### Medium risk

| Pattern | What it catches |
|---------|----------------|
| `routes/`, `api/`, `endpoints/`, `handlers/`, `controllers/` | API route definitions |
| `migrations/`, `migrate/`, `schema/` | Database schema changes |
| `config/`, `settings/`, `*.yml`, `*.yaml`, `*.toml`, `*.ini`, `*.cfg`, `*.conf` | Configuration files |
| `.env*` | Environment variable files |

Unclassified files (those matching no pattern) default to medium risk.

### Low risk

| Pattern | What it catches |
|---------|----------------|
| `docs/`, `doc/`, `README*`, `CHANGELOG*`, `LICENSE*`, `*.md`, `*.txt`, `*.rst` | Documentation |
| `test/`, `tests/`, `spec/`, `__tests__/`, `*_test.*`, `*_spec.*`, `*.test.*`, `*.spec.*` | Test files |

### Decision logic

1. If any file matches a high-risk pattern, the entire diff is classified as **high**.
2. If no high-risk matches exist, the majority between medium and low wins.
3. Ties default to **medium** (err on the side of caution).
4. Empty diffs (no changes detected) are classified as **low**.

### Extending patterns

Set the `SECURETTY_HIGH_RISK_PATTERNS` environment variable with colon-separated patterns to add project-specific high-risk paths:

```bash
export SECURETTY_HIGH_RISK_PATTERNS="*/secrets/*:*.cert:*/iam/*"
securetty run claude ~/src/myproject
```

These are merged with the built-in patterns; they do not replace them.

## Comparison with Carbonite's 7-Tier Model

Carbonite defines seven graduated security levels. securetty consolidates these into three actionable tiers that map to container runtime configuration. The mapping below shows how each Carbonite tier relates to securetty's model.

| Carbonite Tier | Carbonite Definition | securetty Equivalent | securetty Tier |
|----------------|---------------------|---------------------|---------------|
| **1 -- Unrestricted** | No controls, full host access | Not available -- securetty was built to eliminate this | -- |
| **2 -- Basic isolation** | Separate user account or VM | Exceeded by rootless podman | Tier 1 (low) |
| **3 -- Container sandbox** | Containers, dropped caps, resource limits | Enforced at all tiers (baseline) | Tier 1 (low) |
| **4 -- Network egress control** | Allowlist-only outbound network | Tier 2 default; Tier 3 restricts further | Tier 2 (medium) |
| **5 -- Credential isolation** | Runtime secret injection, least-privilege | Tier 2 via OmniRoute proxy + per-service `.env` | Tier 2 (medium) |
| **6 -- Supply chain hardening** | Package provenance, reproducible builds | Partially enforced (7-day quarantine, `ignore-scripts`) | Tier 2 (medium) |
| **7 -- Zero trust / attestation** | Signed images, policy-as-code, runtime integrity | Partially addressed by Tier 3 (zero creds, RO mounts) | Tier 3 (high) |

### Key differences

- **Carbonite tiers 1-3** are subsumed by securetty's baseline -- even Tier 1 (low risk) runs inside rootless containers with dropped capabilities, resource limits, and `no-new-privileges`. There is no "unrestricted" mode.
- **Carbonite tiers 4-6** map to securetty's Tier 2 (medium), which is the current default posture and where most development work happens.
- **Carbonite tier 7** (zero trust) is partially addressed by securetty's Tier 3 (high risk) via zero credentials and read-only mounts, but securetty does not yet implement image signing, admission control, or runtime integrity monitoring (see [security-levels.md](security-levels.md) for the full gap analysis).
- securetty's three-tier model is deliberately simpler. Seven tiers create decision fatigue for operators who run ad-hoc AI coding sessions. Three tiers with automatic classification removes the burden of choosing.

## Integration with Escalation Gates

The risk classifier feeds into the escalation gate system documented in [escalation-gates.md](escalation-gates.md). When a tier is selected (automatically or via `--risk`), the escalation gate thresholds adjust:

| Gate | Tier 1 (low) | Tier 2 (medium) | Tier 3 (high) |
|------|-------------|-----------------|---------------|
| Max turns | 50 (default) | 50 (default) | 25 (halved) |
| Max duration | 30 min | 30 min | 15 min |
| Max diff lines | 500 | 250 (halved) | 100 |
| Test coverage | 70% | 70% | 90% |
| High-risk patterns | Logged | Enforced (pause) | Enforced (abort) |
| Escalation action | As configured | `warn` promoted to `pause` | Forced `pause`; pattern match forces `abort` |

## Related Documentation

- [security-levels.md](security-levels.md) -- What is and is not enforced today
- [escalation-gates.md](escalation-gates.md) -- Session-level escalation controls
- [trust-model.md](trust-model.md) -- Input trust classification
- `roles/escalation/defaults/main.yml` -- Escalation gate configuration
