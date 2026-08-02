# securetty

Sandboxed AI development environment. All AI CLI agents run inside ephemeral containers with egress filtering, credential isolation, and delayed package ingestion.

## Architecture

```mermaid
graph TD
    Internet["🌐 Internet + VPN"]

    subgraph external["External Network"]
        DNS["dns-relay<br/>dnsmasq → host DNS + VPN"]
        Egress["egress-proxy<br/>Envoy SNI allowlist"]
    end

    subgraph internal["Internal Network (no gateway)"]
        OmniRoute["omniroute :4000<br/>AI provider router"]
        Headroom["headroom :8787<br/>Token compression MCP"]
        CloudCLI["cloudcli :3001<br/>Claude Code Web UI"]
        Ollama["ollama :11434<br/>Local LLM (GPU)"]
        Dev["dev (ephemeral)<br/>AI agent containers"]
    end

    Internet <--> DNS
    Internet <--> Egress
    Egress <--> OmniRoute
    Egress <--> Headroom
    Egress <--> CloudCLI
    Egress <--> Dev
    Dev --> OmniRoute
    Dev --> Headroom
    Dev --> Ollama
    Dev --> CloudCLI

    style external fill:#1a1a2e,stroke:#e94560,color:#fff
    style internal fill:#0f3460,stroke:#e94560,color:#fff
    style Internet fill:#533483,stroke:#e94560,color:#fff
```

## Security Model

```mermaid
graph LR
    subgraph Host["❌ Host (before)"]
        H1["39 secret env vars"]
        H2["npm ignore-scripts=false"]
        H3["505 pip packages globally"]
        H4["20 credential files readable"]
        H5["4 SSH keys in agent"]
        H6["No egress filtering"]
        H7["No resource limits"]
    end

    subgraph Container["✅ Container (after)"]
        C1["Only agent-specific keys via .env"]
        C2["npm_config_ignore_scripts=true"]
        C3["Fresh image, 7d quarantine"]
        C4["Selective mounts only"]
        C5["Restricted agent (1 key)"]
        C6["Envoy SNI allowlist"]
        C7["CPU + memory capped"]
    end

    H1 --> C1
    H2 --> C2
    H3 --> C3
    H4 --> C4
    H5 --> C5
    H6 --> C6
    H7 --> C7

    style Host fill:#8B0000,stroke:#ff0000,color:#fff
    style Container fill:#006400,stroke:#00ff00,color:#fff
```

### Egress Policy

```mermaid
flowchart LR
    Process["Container process"] --> Envoy{"Envoy proxy<br/>(SNI inspect)"}
    Envoy -->|"✅ allowlisted"| Internet["Internet"]
    Envoy -->|"❌ not in list"| Block["DENIED"]

    subgraph Allowed["Allowed domains"]
        A1["*.anthropic.com"]
        A2["*.openai.com"]
        A3["*.googleapis.com"]
        A4["*.github.com"]
        A5["*.npmjs.org"]
        A6["+ 30 more"]
    end

    Envoy -.-> Allowed

    style Block fill:#8B0000,stroke:#ff0000,color:#fff
    style Allowed fill:#006400,stroke:#00ff00,color:#fff
```

All containers on `internal` network — no direct internet gateway. Traffic routes through Envoy on `external` network. Only allowlisted domains pass (SNI inspection for TLS, HTTP CONNECT for proxied traffic). Malicious postinstall scripts cannot exfiltrate.

### SSH

```mermaid
flowchart LR
    Host["Host SSH agent<br/>(restricted)"] -->|"socket (ro)"| Container["Container"]
    Key["dmzoneill-2024<br/>(only key loaded)"] --> Host
    Other["ecdsa, rsa, automation<br/>keys"] -.-x|"not loaded"| Host

    style Other fill:#8B0000,stroke:#ff0000,color:#fff
    style Key fill:#006400,stroke:#00ff00,color:#fff
```

Dedicated ssh-agent on host with only one key loaded. Socket forwarded read-only. Private key never enters container.

### Delayed Ingestion

```mermaid
flowchart LR
    Registry["npm / PyPI"] --> Check{"Published<br/>>= 7 days ago?"}
    Check -->|"✅ yes"| Install["Install in image"]
    Check -->|"❌ too new"| Skip["Skip version"]
    Install --> Manifest["/etc/securetty-manifest.json"]
    Manifest --> Banner["TTY age banner<br/>on container start"]

    style Skip fill:#8B0000,stroke:#ff0000,color:#fff
    style Install fill:#006400,stroke:#00ff00,color:#fff
```

AI agents installed from versions published >= 7 days ago. npm: queries `npm view <pkg> time` for version dates. pip: uses `uv --exclude-newer`. Binary agents: GitHub release date filtering.

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
| `securetty-omniroute` | omniroute | AI provider router (736 models) | 4000 (host 127.0.0.2) |
| `securetty-headroom` | headroom | Token compression MCP | 8787 (internal) |
| `securetty-cloudcli` | cloudcli | Claude Code Web UI | 3001 (host 127.0.0.2) |
| `securetty-ollama` | ollama | Local LLM server (GPU) | 11434 (host 127.0.0.2) |
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
