# securetty

Sandboxed AI development environment. All AI CLI agents run inside ephemeral containers with egress filtering, credential isolation, and delayed package ingestion.

## Architecture

```
                         INTERNET + VPN (100.90.0.0/15)
                                │
                    ┌───────────┴───────────┐
                    │    external network    │
                    │                       │
                    │  dns-relay            │  dnsmasq → host DNS + VPN
                    │  egress-proxy         │  Envoy SNI allowlist
                    │                       │
                    └───────────┬───────────┘
                                │
                    ┌───────────┴───────────┐
                    │  internal network     │  NO internet gateway
                    │  10.89.100.0/24       │
                    │                       │
                    │  omniroute   (:4000)  │  AI provider router (736 models)
                    │  headroom   (:8787)  │  Token compression MCP
                    │  cloudcli   (:3001)  │  Claude Code Web UI
                    │  ollama    (:11434)  │  Local LLM (GPU)
                    │  dev        (ephemeral)│  AI agent containers
                    │                       │
                    └───────────────────────┘
```

## Security Model

```
Host                                    Container
────                                    ─────────
39 secret env vars                      Only agent-specific keys via .env
npm ignore-scripts=false                npm_config_ignore_scripts=true
505 pip packages globally               Fresh image, delayed install (7d quarantine)
20 credential files readable            None mounted (or full dir for persistence)
4 SSH keys in agent                     Restricted agent (dmzoneill-2024 only)
3 services on 0.0.0.0                   Internal network, no gateway
No egress filtering                     Envoy SNI allowlist (domains only)
No resource limits                      CPU + memory capped per container
```

### Egress Policy

All containers on `internal` network — no direct internet. Traffic routes through Envoy proxy on `external` network. Only allowlisted domains pass (SNI inspection for TLS, HTTP CONNECT for proxied traffic).

Allowed: AI provider APIs, package registries, git hosting, Red Hat services.
Blocked: everything else. Malicious postinstall scripts cannot exfiltrate.

### SSH

Dedicated ssh-agent on host with only `dmzoneill-2024` key loaded. Socket forwarded into container read-only. Private key never enters container. Other keys inaccessible.

### Delayed Ingestion

AI agents installed from versions published >= 7 days ago. npm: queries `npm view <pkg> time` for version dates. pip: uses `uv --exclude-newer`. Binary agents: GitHub release date filtering.

Manifest at `/etc/securetty-manifest.json` inside image records build date + agent versions. Entrypoint prints age banner on TTY.

## Two Modes

| Mode | Command | Provider | Use case |
|------|---------|----------|----------|
| Personal | `claude`, `c` | OmniRoute (auto-routes to best provider) | Personal projects |
| Work | `claude-work`, `cw` | Google Vertex AI (GCP) | Red Hat work |

All agents run with skip-permissions flags by default (sandbox is the container itself).

## Quick Start

```bash
# 1. Build and start services
make env                    # Generate .env from pass + shell profile
make build                  # Build all container images
make up                     # Start services + pull ollama models

# 2. Configure omniroute providers
make setup-omniroute        # Add providers (OpenAI, Groq, OpenRouter, etc.)

# 3. Install shell aliases
make install-aliases        # Installs to ~/.bashrc.d/scripts.d/99-securetty.sh

# 4. Use
claude ~/src/myproject      # Personal mode (omniroute)
claude-work ~/src/myproject # Work mode (Vertex AI)
codex "fix tests"           # Codex via omniroute
gemini-work                 # Gemini via Vertex
```

## Commands

### Makefile

| Command | Description |
|---------|-------------|
| `make env` | Generate .env from host env + pass + shell profile |
| `make build` | Build all container images |
| `make rebuild` | Force rebuild (no cache, fresh delayed versions) |
| `make up` | Start services + configure omniroute + pull models |
| `make down` | Stop all containers |
| `make shell` | Shell into persistent dev container |
| `make setup-omniroute` | Configure omniroute providers via API |
| `make install-aliases` | Install shell aliases for all agents |
| `make scan-secrets` | Scan AI history for leaked keys |
| `make migrate` | Remove AI agents from host (interactive) |
| `make lockdown` | Air-gap container network |
| `make unlock` | Reconnect network |
| `make status` | Show container/network/volume state |
| `make age` | Show image age and agent versions |
| `make nuke` | Remove containers + all volumes |

### Shell Aliases

| Personal | Work | Short | Short-work | Agent |
|----------|------|-------|------------|-------|
| `claude` | `claude-work` | `c` | `cw` | Claude Code |
| `codex` | `codex-work` | `cx` | `cxw` | Codex CLI |
| `gemini` | `gemini-work` | `gm` | `gmw` | Gemini CLI |
| `cursor` | `cursor-work` | `cr` | `crw` | Cursor CLI |
| `cline` | `cline-work` | `cl` | `clw` | Cline |
| `opencode` | `opencode-work` | `oc` | `ocw` | OpenCode |
| `aider` | `aider-work` | `ai` | `aiw` | Aider |
| `openhands` | `openhands-work` | `oh` | `ohw` | OpenHands |
| `goose` | `goose-work` | `gs` | `gsw` | Goose |
| `grok` | `grok-work` | `gr` | `grw` | Grok Build |
| `forge` | `forge-work` | `fg` | `fgw` | Forge |
| `kiro-cli` | `kiro-work` | `ki` | `kiw` | Kiro CLI |
| `pi-ai` | `pi-ai-work` | `pi` | `piw` | Pi AI |
| `kimi` | `kimi-work` | `km` | `kmw` | Kimi CLI |

## Containers

| Container | Image | Purpose | Ports |
|-----------|-------|---------|-------|
| `securetty-dns-relay` | dnsmasq | DNS forwarding (VPN + public) | 53 (internal) |
| `securetty-egress-proxy` | Envoy | SNI-filtered egress allowlist | 443, 3128, 22 (internal) |
| `securetty-omniroute` | omniroute | AI provider router (736 models) | 4000 (host 127.0.0.1) |
| `securetty-headroom` | headroom | Token compression MCP | 8787 (internal) |
| `securetty-cloudcli` | cloudcli | Claude Code Web UI | 3001 (host 127.0.0.1) |
| `securetty-ollama` | ollama | Local LLM server (GPU) | 11434 (host 127.0.0.1) |
| `securetty` | dev | Persistent dev shell (optional) | — |
| `securetty-<agent>-*` | dev | Ephemeral agent containers | — |

## OmniRoute Providers

| Provider | Priority | Type |
|----------|----------|------|
| OpenAI | 100 | Paid |
| Google AI Studio | 100 | Paid |
| Mistral | 100 | Paid |
| OpenRouter | 50 | Free tier |
| Groq | 50 | Free tier |
| Cerebras | 50 | Free tier |
| SambaNova | 50 | Free tier |
| Ollama (local) | 1 | Fallback |

Dashboard: http://localhost:4000

## File Structure

```
securetty/
├── Containerfile              # Dev container (14 AI agents + dev tools)
├── podman-compose.yml         # 7 service containers
├── Makefile                   # Build/setup/migrate commands
├── securetty                  # CLI wrapper script
├── cloudcli/Containerfile     # Claude Code Web UI
├── dns-relay/
│   ├── Containerfile
│   └── dnsmasq.conf
├── egress-proxy/
│   ├── Containerfile          # Envoy proxy
│   ├── envoy.yaml             # SNI allowlist + HTTP CONNECT
│   └── allowed-domains.txt    # Allowlisted domains
├── headroom/Containerfile     # Token compression
├── ollama/Containerfile       # Local LLM
├── omniroute/
│   ├── Containerfile
│   └── install.sh
└── scripts/
    ├── entrypoint.sh          # Container entrypoint (age banner)
    ├── generate-env.sh        # .env from pass + shell profile
    ├── install-delayed.sh     # Delayed ingestion installer
    ├── install.sh             # Project dependency installer
    ├── lockdown-network.sh    # Air-gap network
    ├── migrate-from-host.sh   # Remove agents from host
    ├── open-relay-host.sh     # xdg-open URL relay
    ├── reconnect-network.sh   # Restore network
    ├── scan-secrets.sh        # Secret scanner
    ├── securetty-aliases.sh   # Shell aliases (personal + work modes)
    ├── setup-host.sh          # Host prerequisites check
    ├── setup-omniroute.sh     # Provider configuration
    ├── ssh-agent-restricted.sh # Single-key SSH agent
    └── xdg-open               # URL relay shim
```

## Adding a New AI Agent

1. Add npm/pip package to `scripts/install-delayed.sh`
2. Add alias functions to `scripts/securetty-aliases.sh`
3. Add egress domains to `egress-proxy/envoy.yaml` (SNI allowlist)
4. Add API key to `scripts/generate-env.sh` KEYS array
5. Add `_lazy_pass` entry to `~/.bashrc.d/scripts.d/13-free-ai-providers.sh`
6. `make rebuild && make install-aliases`

## Adding a New Provider to OmniRoute

1. Get API key from provider
2. `pass insert <provider>/key`
3. Add `_lazy_pass` to `~/.bashrc.d/scripts.d/13-free-ai-providers.sh`
4. Add provider to `scripts/setup-omniroute.sh`
5. `make setup-omniroute`
