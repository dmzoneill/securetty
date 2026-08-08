# Skill Marketplace and Cross-Team Skill Sharing

How securetty MCP skills work, how to create and share them, and how the skill manager integrates with the ai-marketplace-internal working group standard.

## How Skills Work

A securetty skill is a self-contained MCP server that provides tools to AI agents running inside the sandbox. Each skill lives in its own directory with a `SKILL.md` manifest and a Python MCP server implementation.

### SKILL.md Spec

Every skill must include a `SKILL.md` file at its root. This file serves as both the machine-readable manifest (via YAML frontmatter) and human-readable documentation (via markdown body).

**Required frontmatter fields:**

```yaml
---
name: my-skill-query
description: One-line summary of what this skill does
version: "1.0.0"
tags: [keyword1, keyword2, keyword3]
triggers:
  - natural language trigger phrase
  - another trigger phrase
---
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique skill identifier, lowercase with hyphens |
| `description` | Yes | One-line plain-text summary |
| `version` | Yes | Semver string (quoted to avoid YAML float parsing) |
| `tags` | Yes | YAML list of searchable keywords |
| `triggers` | Yes | Phrases that activate the skill in agent conversations |

The markdown body below the frontmatter documents available tools, authentication requirements, and usage examples.

### MCP Servers

Each skill implements a Python MCP server using the FastMCP framework. The server exposes tools via the MCP protocol. A minimal server looks like:

```python
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("my-skill")

@mcp.tool()
def my_tool(param: str) -> str:
    """Tool description shown to agents."""
    return do_work(param)
```

Agents discover and invoke tools through the MCP protocol. The skill's `SKILL.md` triggers determine when an agent's skill router activates the skill.

### ThickMCP Containers

In securetty, skills that require secrets (API tokens, session cookies) run as **ThickMCP** containers -- isolated sibling containers on the securetty podman bridge network (172.30.100.0/24). Each ThickMCP container:

- Mounts the skill directory read-only at `/mcp`
- Receives its secrets via a dedicated `.env.mcp-<name>` file (generated from GNU pass)
- Serves MCP over HTTPS with per-skill TLS certificates
- Runs with dropped capabilities, `no-new-privileges`, and read-only root filesystem
- Has resource limits (CPU/memory) enforced by podman

This architecture means secrets never enter the main agent container. The agent communicates with the skill's MCP server over the internal network using HTTPS.

## Built-in vs User-Installed Skills

Skills come from two locations:

| Type | Path | Managed by |
|------|------|------------|
| Built-in | `~/src/agent-mcp-skills/<name>/` | Repository maintainer |
| User-installed | `~/.securetty/skills/<name>/` | `securetty-skill-manager.sh` |

### Built-in Skills

The following skills ship with the securetty agent-mcp-skills repository:

| Skill | Description |
|-------|-------------|
| `billing-query` | Query AAP billing reports from GABI database proxy |
| `gabi-query` | Query GABI PostgreSQL instances for billing and swatch data |
| `github-query` | Track GitHub PRs, reviews, CI status, and manage gists |
| `gitlab-query` | Track GitLab MRs, reviews, pipelines, and manage snippets |
| `gmail-query` | Search, list, and read Gmail messages and threads |
| `gworkspace-query` | Interact with Google Workspace (Drive, Docs, Sheets, Calendar) |
| `jira-query` | Search, view, create, and manage Jira issues |
| `konflux-query` | Query Konflux/Tekton pipeline status and logs |
| `slack-query` | Search, read, and send messages on Slack |
| `wordpress-query` | Create, manage, and query WordPress content |

Built-in skills cannot be removed via the skill manager. They are updated by pulling the `agent-mcp-skills` repository directly.

### User-Installed Skills

User-installed skills live in `~/.securetty/skills/` and are managed with `securetty-skill-manager.sh`:

```bash
# List all skills (built-in + user-installed)
securetty-skill-manager.sh list

# Search by name, tag, or description
securetty-skill-manager.sh search kubernetes

# Show full SKILL.md for a skill
securetty-skill-manager.sh info slack-query

# Install a skill from a git repository
securetty-skill-manager.sh install https://github.com/example/my-mcp-skill.git

# Update all user-installed skills (git pull)
securetty-skill-manager.sh update

# Remove a user-installed skill
securetty-skill-manager.sh remove my-mcp-skill
```

## Creating a New Skill

### Directory Structure

A minimal skill requires this layout:

```
my-skill/
  SKILL.md          # Manifest and documentation (required)
  server.py         # MCP server implementation
  pyproject.toml    # Python dependencies
  README.md         # Optional additional docs
```

### SKILL.md Template

```yaml
---
name: my-skill-query
description: Brief description of what this skill provides
version: "0.1.0"
tags: [relevant, searchable, keywords]
triggers:
  - natural language phrase that activates this skill
  - another activation phrase
---

# My Skill

Description of the skill and its purpose.

## Available Tools

### Category
- **tool_name** -- What the tool does

## Authentication

Describe any required credentials or environment variables.
```

### Frontmatter Requirements

The `SKILL.md` frontmatter is validated by [skillsaw](https://github.com/stbenjam/skillsaw) with the following rules enabled in securetty:

- **agentskill-valid** -- Frontmatter must be syntactically valid YAML between `---` delimiters
- **agentskill-name** -- The `name` field must be present and follow the lowercase-hyphenated format
- **agentskill-description** -- The `description` field should be a concise, informative summary
- **content-embedded-secrets** -- No hardcoded secrets or tokens in the file (severity: error)
- **content-weak-language** -- Avoid hedging language ("might", "probably", "should work")
- **content-placeholder-text** -- No lorem ipsum or TODO placeholders

Run skillsaw locally to validate before publishing:

```bash
skillsaw lint path/to/my-skill/SKILL.md
```

### Server Implementation

The MCP server uses `mcp.server.fastmcp.FastMCP`. Each tool function becomes an MCP tool that agents can invoke:

```python
from mcp.server.fastmcp import FastMCP
import os

mcp = FastMCP("my-skill")

@mcp.tool()
def query_data(search_term: str, limit: int = 10) -> str:
    """Search the data source for matching records.

    Args:
        search_term: Text to search for
        limit: Maximum results to return (default 10)
    """
    # Implementation here
    return results
```

## Sharing Skills

### Publishing to Git

Any git repository with a valid `SKILL.md` at its root can be installed as a securetty skill:

```bash
securetty-skill-manager.sh install https://github.com/your-org/your-skill.git
```

To make a skill shareable:

1. Ensure `SKILL.md` has complete frontmatter (name, description, version, tags, triggers)
2. Include a `pyproject.toml` with dependencies
3. Pass `skillsaw lint` validation
4. Tag releases with semver (e.g. `v1.0.0`)
5. Document authentication requirements in the SKILL.md body

### AgentSkills.io Compliance

Skills published to [AgentSkills.io](https://agentskills.io) must follow the AgentSkill specification:

- The `SKILL.md` frontmatter is the canonical metadata format
- Skill names must be globally unique within the registry namespace
- The `triggers` field enables discovery and routing by agent skill routers
- Tags should use established vocabulary from the AgentSkills.io taxonomy
- The repository must include a LICENSE file

Skills that pass `skillsaw lint` with `agentskill-valid` and `agentskill-name` rules are compliant with the AgentSkills.io minimum requirements.

## Skill Versioning

Skills use [Semantic Versioning](https://semver.org/) (semver):

| Version component | When to increment | Example |
|-------------------|-------------------|---------|
| **Major** (X.0.0) | Breaking changes to tool signatures or behavior | Renaming a tool, changing required parameters |
| **Minor** (0.X.0) | New tools or backward-compatible feature additions | Adding a new MCP tool, new optional parameters |
| **Patch** (0.0.X) | Bug fixes, documentation updates | Fixing a query parser, updating help text |

Version is declared in the `SKILL.md` frontmatter `version` field. Quote the value to prevent YAML from interpreting it as a float:

```yaml
version: "1.2.3"    # correct
version: 1.2.3      # may be parsed as float
```

When updating a skill, bump the version in `SKILL.md` and tag the git commit:

```bash
git tag v1.2.3
git push origin v1.2.3
```

Users running `securetty-skill-manager.sh update` will receive the latest changes via `git pull --ff-only`. The version field in `SKILL.md` serves as the human-readable record; git tags provide the machine-checkable release history.

## Integration with ai-marketplace-internal

The ai-marketplace-internal working group defines a standard for sharing AI agent skills across teams within an organization. securetty's skill system aligns with this standard:

### Compatibility

| WG Standard | securetty Implementation |
|-------------|--------------------------|
| Skill manifest format | `SKILL.md` YAML frontmatter (AgentSkill spec) |
| Skill discovery | `securetty-skill-manager.sh search` reads frontmatter tags and descriptions |
| Skill installation | Git-based: `securetty-skill-manager.sh install <url>` |
| Skill isolation | ThickMCP containers with per-skill secrets and TLS |
| Skill validation | skillsaw linting with `agentskill-valid` rules |
| Skill versioning | Semver in frontmatter + git tags |

### Cross-Team Sharing Workflow

1. **Author** creates a skill following the SKILL.md spec and validates with skillsaw
2. **Author** publishes to a git repository (GitHub, GitLab, or internal hosting)
3. **Author** registers the skill in the ai-marketplace-internal catalog (optional)
4. **Consumer** discovers the skill via the catalog or direct URL
5. **Consumer** installs with `securetty-skill-manager.sh install <url>`
6. **Consumer** configures any required credentials in their pass store
7. **Consumer** adds a ThickMCP container entry in `podman-compose.yml` if the skill needs secrets

### Galaxy Collection Metadata

securetty is packaged as an Ansible Galaxy collection (`dmzoneill.securetty`). The `galaxy.yml` at the repository root defines the collection metadata. Skills distributed as part of the collection inherit the collection's versioning and are included in the built-in skill set. Third-party skills installed via the skill manager are independent of the Galaxy collection lifecycle.
