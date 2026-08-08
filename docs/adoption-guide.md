# Adoption Guide

How to adopt securetty for your team, contribute skills, and track adoption metrics.

## Prerequisites

Before adopting securetty, ensure you have:

- **Podman** (rootless mode) -- securetty runs all AI agents inside rootless podman containers
- **GNU pass** -- secrets are stored in the password store and injected at container start
- **Ansible** -- securetty is packaged as an Ansible Galaxy collection (`dmzoneill.securetty`)
- **gh CLI** -- required for GitHub integration and adoption metrics
- **Python 3.10+** -- used by MCP skill servers and evaluation tooling
- **Node.js 18+** -- required for promptfoo evaluations and some agent CLIs

Optional:

- **skillsaw** -- linter for SKILL.md and instruction files ([github.com/stbenjam/skillsaw](https://github.com/stbenjam/skillsaw))
- **ai-guardian** -- defense-in-depth scanning for secrets, PII, and prompt injection
- **GPU passthrough** -- for local inference via Ollama

## Setup

### 1. Clone and install

```bash
git clone https://github.com/dmzoneill/securetty.git ~/src/securetty
cd ~/src/securetty
make setup
```

`make setup` builds three container image layers (base, devbase, dev), configures networking with pasta and nftables egress filtering, generates TLS certificates, and resolves secrets from your pass store.

### 2. Configure providers

Store your AI provider API keys in GNU pass and declare them in `group_vars/all.yml`:

```yaml
securetty_pass_keys:
  - name: anthropic-api-key
    path: ai/anthropic
  - name: openai-api-key
    path: ai/openai
```

Run `securetty env` to regenerate `.env` files from the pass store.

### 3. Configure agents

Agents are declared in `group_vars/all.yml`. Each agent has a name, install method, and sandbox configuration:

```yaml
securetty_agents:
  claude:
    name: claude
    skip: "--dangerously-skip-permissions"
    type: npm
```

Add new agents to `securetty_npm_agents`, `securetty_pip_agents`, or `securetty_binary_agents`, then run `securetty rebuild-agents`.

### 4. Configure egress

securetty uses a default-drop nftables policy. Only resolved IPs from approved domains are allowed through:

```yaml
securetty_allowed_domains:
  - api.anthropic.com
  - api.openai.com
  - github.com
```

Run `securetty egress` after modifying the domain list.

## securetty init -- Project Bootstrapping

Use `securetty-init.sh` to bootstrap securetty configuration in any project directory:

```bash
# Basic scaffolding
securetty-init.sh ~/projects/my-app

# Include evaluation templates
securetty-init.sh ~/projects/my-app --with-evals

# Include governance hooks
securetty-init.sh ~/projects/my-app --with-hooks

# Full setup
securetty-init.sh ~/projects/my-app --with-evals --with-hooks
```

### What init creates

| File | Purpose |
|------|---------|
| `.claude/settings.json` | MCP server config and permissions |
| `CLAUDE.md` | Agent instructions entry point (imports @AGENTS.md) |
| `AGENTS.md` | Project-specific agent guide skeleton |
| `.skillsaw.yaml` | Skill and content linting configuration |

With `--with-evals`:

| File | Purpose |
|------|---------|
| `evals/promptfooconfig.yaml` | Template promptfoo evaluation config |
| `evals/skill-quality.yaml` | Skill quality eval template |

With `--with-hooks`:

| File | Purpose |
|------|---------|
| `scripts/governance-hook.sh` | Pre-tool-use governance gate script |

### Customizing after init

1. Edit `AGENTS.md` with your project's architecture, key commands, and agent rules
2. Add project-specific permissions to `.claude/settings.json`
3. Run `skillsaw lint` to validate the configuration
4. If using evals, customize `evals/*.yaml` with project-specific test cases

## Customization

### Team-specific configuration

securetty configuration lives in `group_vars/all.yml`. Key customization areas:

| Section | What to customize |
|---------|-------------------|
| `securetty_agents` | Which AI agents to install and their sandbox flags |
| `securetty_providers` | API keys and provider endpoints |
| `securetty_allowed_domains` | Egress whitelist for your team's services |
| `securetty_pass_keys` | Secrets to pull from GNU pass |
| `securetty_pip_tools` | Additional Python packages in the dev container |

### MCP skills

Skills extend agent capabilities through the MCP protocol. securetty ships with 10 built-in skills covering GitHub, GitLab, Jira, Slack, Gmail, Google Workspace, billing, Konflux, and WordPress.

Install additional skills from git repositories:

```bash
securetty-skill-manager.sh install https://github.com/your-org/your-skill.git
```

See [docs/skill-marketplace.md](skill-marketplace.md) for full skill management documentation.

## Contributing Skills

### Fork-and-PR workflow

1. **Fork** the [agent-mcp-skills](https://github.com/dmzoneill/agent-mcp-skills) repository
2. **Create** a new skill directory with the required structure:
   ```
   my-skill/
     SKILL.md          # Manifest with YAML frontmatter (required)
     server.py         # FastMCP server implementation
     pyproject.toml    # Python dependencies
   ```
3. **Write** the SKILL.md with required frontmatter:
   ```yaml
   ---
   name: my-skill-query
   description: One-line summary of what this skill does
   version: "1.0.0"
   tags: [keyword1, keyword2]
   triggers:
     - natural language trigger phrase
   ---
   ```
4. **Validate** with skillsaw:
   ```bash
   skillsaw lint my-skill/SKILL.md
   ```
5. **Test** the MCP server locally:
   ```bash
   cd my-skill
   python server.py
   ```
6. **Submit** a pull request to the upstream repository

### SKILL.md requirements

Every skill must include a `SKILL.md` at its root. The file serves as both machine-readable manifest (YAML frontmatter) and human-readable documentation (markdown body).

Required frontmatter fields:

| Field | Format | Description |
|-------|--------|-------------|
| `name` | lowercase-hyphenated | Unique skill identifier |
| `description` | plain text | One-line summary |
| `version` | semver (quoted) | e.g. `"1.0.0"` |
| `tags` | YAML list | Searchable keywords |
| `triggers` | YAML list | Activation phrases for agent skill routing |

## Skill Certification Process

Skills submitted to the built-in collection go through a certification process:

### 1. skillsaw validation

The SKILL.md must pass all enabled skillsaw rules without errors:

```bash
skillsaw lint --strict my-skill/SKILL.md
```

Key rules enforced:

| Rule | Severity | What it checks |
|------|----------|----------------|
| `agentskill-valid` | error | Frontmatter is syntactically valid YAML |
| `agentskill-name` | error | Name follows lowercase-hyphenated format |
| `content-embedded-secrets` | error | No hardcoded secrets or tokens |
| `content-weak-language` | warning | No hedging language ("might", "probably") |
| `content-placeholder-text` | warning | No lorem ipsum or TODO placeholders |

### 2. Evaluation pass rate

Skills with evals must achieve a minimum pass rate (default: 80%) using promptfoo:

```bash
securetty-eval.sh run evals/skill-quality.yaml --threshold 0.8
```

Eval configs test that the skill's MCP tools return correct results and handle edge cases.

### 3. Code review

A maintainer reviews the PR for:

- MCP server implementation quality and error handling
- Secret handling (credentials must go through pass/ThickMCP, never hardcoded)
- Resource usage (CPU/memory limits in podman)
- Documentation completeness in the SKILL.md body

### 4. Integration test

The skill is deployed as a ThickMCP container on the securetty bridge network and tested end-to-end with an agent.

## Integration with ai-marketplace-internal

securetty's skill system aligns with the ai-marketplace-internal working group standard for cross-team skill sharing:

| WG Standard | securetty Implementation |
|-------------|--------------------------|
| Skill manifest format | `SKILL.md` YAML frontmatter (AgentSkill spec) |
| Skill discovery | `securetty-skill-manager.sh search` |
| Skill installation | Git-based: `securetty-skill-manager.sh install <url>` |
| Skill isolation | ThickMCP containers with per-skill secrets and TLS |
| Skill validation | skillsaw linting with `agentskill-valid` rules |
| Skill versioning | Semver in frontmatter + git tags |

Skills published to [AgentSkills.io](https://agentskills.io) must follow the AgentSkill specification. Skills that pass `skillsaw lint` with `agentskill-valid` and `agentskill-name` rules meet the minimum requirements.

### Cross-team sharing workflow

1. Author creates a skill following the SKILL.md spec and validates with skillsaw
2. Author publishes to a git repository (GitHub, GitLab, or internal hosting)
3. Author registers the skill in the ai-marketplace-internal catalog (optional)
4. Consumer discovers the skill via the catalog or direct URL
5. Consumer installs with `securetty-skill-manager.sh install <url>`
6. Consumer configures credentials in their pass store
7. Consumer adds a ThickMCP container entry in `podman-compose.yml` for skills needing secrets

## Adoption Metrics

Track securetty adoption using `securetty-adoption-metrics.sh`:

### GitHub repository metrics

```bash
# Interactive dashboard
securetty-adoption-metrics.sh metrics

# Machine-readable output
securetty-adoption-metrics.sh metrics --json
```

Shows: stars, forks, open issues, watchers, contributor count, and clone traffic (last 14 days).

### Skill inventory

```bash
securetty-adoption-metrics.sh skills
securetty-adoption-metrics.sh skills --json
```

Shows: total skill count, built-in vs user-installed breakdown, and skill names.

### External contributions

```bash
securetty-adoption-metrics.sh contributions
securetty-adoption-metrics.sh contributions --json
```

Lists all non-owner contributors from the git log with commit counts. Useful for tracking community engagement.

### How metrics are tracked

- **GitHub stats** (stars, forks, issues, clones) are fetched via `gh api` from the GitHub REST API. Clone traffic requires push access to the repository and covers a rolling 14-day window.
- **Skill counts** are derived from the local filesystem: built-in skills in `~/src/agent-mcp-skills/` and user-installed skills in `~/.securetty/skills/`.
- **Contributor data** comes from the local git log. External contributors are identified by filtering out commits from the repository owner.

All metrics support `--json` output for integration with dashboards, CI pipelines, or reporting tools.

## Comparison: securetty vs Carbonite

securetty and Carbonite both sandbox AI agent execution, but they target different use cases and make different trade-offs.

### When to use securetty

- You need **credential isolation** -- secrets never enter the agent container; they are served via ThickMCP sidecars over mTLS
- You want **egress filtering** -- default-drop nftables policy with domain-based allowlisting
- You run **multiple AI agents** (Claude, Copilot, Aider, etc.) and want a unified sandbox
- You need **MCP skill extensibility** -- install, manage, and share skills via the skill manager
- You want **evaluation infrastructure** -- promptfoo-based quality benchmarks with pass-rate gating
- You use **Ansible** for infrastructure and want the sandbox as a Galaxy collection
- You need **rootless containers** -- securetty uses rootless podman, no daemon or root privileges required

### When to use Carbonite

- You need **snapshot/restore** -- Carbonite provides filesystem checkpointing for reproducible agent runs
- You want **minimal configuration** -- Carbonite has a simpler setup path for single-agent use cases
- You need **Docker compatibility** -- Carbonite works with Docker; securetty requires podman
- You are running **ephemeral CI jobs** where the snapshot/restore model fits better than persistent containers

### Feature comparison

| Capability | securetty | Carbonite |
|-----------|-----------|-----------|
| Container runtime | Rootless podman | Docker |
| Credential isolation | ThickMCP sidecars with mTLS | Environment variables |
| Egress filtering | nftables default-drop | Not built-in |
| Skill/plugin system | MCP skills with SKILL.md spec | Not built-in |
| Multi-agent support | Multiple agents, unified config | Single agent focus |
| Evaluation framework | promptfoo integration | Not built-in |
| Snapshot/restore | Not built-in | Core feature |
| Packaging | Ansible Galaxy collection | Docker image |
| Governance hooks | ai-guardian + custom hooks | Not built-in |
| GPU passthrough | Ollama with GPU support | Varies |

The two tools are complementary. Teams that need both credential isolation and snapshot/restore can run Carbonite inside a securetty-managed container.
