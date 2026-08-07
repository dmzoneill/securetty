# AGENTS.md -- securetty AI Agent Guide

## Purpose

securetty sandboxes AI CLI agents inside rootless podman containers with credential isolation, egress filtering, and delayed package ingestion. Agents never run directly on the host.

## Architecture

Three container image layers, each building on the previous:

1. **base** -- Fedora 45 minimal with system packages (dnf)
2. **devbase** -- Development tools, compilers, language runtimes, pip tools
3. **dev** -- AI agents installed via delayed ingestion (7-day quarantine), user account matching host UID/GID

Services run as sibling containers on the same podman bridge network (172.30.100.0/24):

- **OmniRoute** (port 4000) -- AI provider router, centralizes API key usage
- **Headroom** (port 8787) -- Token compression MCP server
- **CloudCLI** (port 3001) -- Claude Code Web UI
- **Ollama** (port 11434) -- Local LLM inference with GPU passthrough

**Networking**: pasta userspace networking with nftables egress whitelist in rootless-netns. Default-drop policy; only resolved IPs from approved domains allowed out. aardvark DNS handles container name resolution and forwards external queries to host DNS.

## Key Commands

| Command | What it does |
|---------|-------------|
| `make setup` | Full build + configure + aliases |
| `make rebuild` | Force rebuild all image layers |
| `securetty rebuild-agents` | Rebuild dev layer only (skip base/devbase) |
| `securetty egress` | Resolve domains and load nftables whitelist |
| `securetty env` | Regenerate .env files from pass store |
| `securetty scan` | Show package scanner results and alerts |
| `securetty status` | Dashboard — containers, network, egress, scanners |
| `securetty top` | Container resource usage (CPU, mem, net) |
| `securetty volumes` | Show volume sizes |
| `securetty clean` | Remove orphaned containers and stale files |

Makefile targets (`make setup`, `make rebuild`, etc.) are thin wrappers around the CLI.

## Rules

1. **Agent lists live in `group_vars/all.yml`** -- `securetty_npm_agents`, `securetty_pip_agents`, `securetty_binary_agents`, and `securetty_agents` (alias config). Add new agents there, not in Containerfiles.
2. **No hardcoded paths** -- Use Ansible variables (`securetty_home`, `securetty_user`, `securetty_dir`). Paths are templated from `all.yml`.
3. **Do not modify devbase for agent changes** -- Agent packages go in the dev layer via `install-delayed.sh`. The devbase layer is for system packages and language runtimes only. Use `make rebuild-agents` to iterate on agent changes without rebuilding the full stack.
4. **Secrets come from GNU pass** -- API keys are declared in `securetty_pass_keys` (all.yml) and resolved at container start by `generate-env.sh`. Never hardcode secrets.
5. **Skip-permission flags are per-agent** -- Each agent's `skip` field in `securetty_agents` controls its sandbox bypass flag. The container itself is the sandbox.
