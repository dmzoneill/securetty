# Trust Model

How securetty classifies inputs by trust level and the design rationale behind each decision.

## Trust Levels

| Input | Trust Level | Justification | Controls Applied |
|-------|------------|---------------|-----------------|
| Host operating system (Fedora 45) | **Trusted** | We own and maintain the host; kernel and system packages from Fedora repos with GPG-verified RPMs | Automatic dnf updates, SELinux enforcing on host |
| Ansible playbooks (`site.yml`, roles) | **Trusted** | First-party code in this repository; changes reviewed via git | Version-controlled, operator-run |
| GNU pass store (secrets) | **Trusted** | GPG-encrypted on host, decrypted only at `.env` generation time | GPG key protected by passphrase; pass store never mounted into containers |
| SSH private keys | **Trusted** | Host-only; never enter containers | Restricted agent loads only configured keys; socket forwarded read-only |
| GPG private keys | **Trusted** | Host-only; never enter containers | Extra-socket forwarding; no export capability from container |
| Bind-mounted `~/bin/` | **Trusted** | Read-only mount of operator-maintained scripts | `:ro` flag in compose |
| SSH config, known_hosts, gitconfig | **Trusted** | Read-only mounts of host configuration | `:ro` flag in compose |
| OmniRoute service | **Semi-trusted** | First-party container on internal network; but processes external API responses | Runs with dropped caps, `no-new-privileges`, read-only root; localhost-only port binding |
| Headroom MCP server | **Semi-trusted** | First-party container; receives agent requests via stdio/HTTP | Same-UID, no privilege escalation; ephemeral data |
| Ollama service | **Semi-trusted** | First-party container; but loads third-party model weights | GPU passthrough; localhost-only port binding; model downloads from ollama.com only |
| npm packages (agent dependencies) | **Semi-trusted** | Third-party code from public registry | 7-day quarantine; `ignore-scripts=true`; egress whitelist limits exfiltration |
| pip packages (agent dependencies) | **Semi-trusted** | Third-party code from PyPI | 7-day quarantine via `uv --exclude-newer`; `require-virtualenv=true` for project installs |
| Binary agent installers (`curl \| sh`) | **Semi-trusted** | Third-party install scripts from known repos | Quarantine checks GitHub release age; but scripts themselves are not hash-verified |
| AI agent processes | **Semi-trusted** | Run as container user; execute third-party code (LLM-generated) | Ephemeral containers; read-only root; egress whitelist; resource limits; procfs masking |
| Bind-mounted `~/src/` repos | **Semi-trusted** | First-party code, but agents write to it (RW mount) | Git history provides audit trail; but a compromised agent can modify any file |
| Agent config directories (`~/.<agent>/`) | **Semi-trusted** | Persist between sessions; agents read/write freely | Host-owned directories; compromised config could alter agent behavior (MCP servers, system prompts) |
| Shared package caches (named volumes) | **Semi-trusted** | Persist across ephemeral containers | Quarantine applies at install, not cache retrieval; `make nuke` clears volumes |
| External API responses (AI providers) | **Untrusted** | Third-party API responses routed through OmniRoute | Agents parse responses; no output sanitization |
| DNS responses | **Untrusted** | From host resolver via aardvark | No DNSSEC validation; used to populate egress allowlist |
| Container network traffic from other containers | **Untrusted** | Any container on the bridge can send traffic | No inter-container network policy; all containers share the securetty bridge |
| Egress network destinations | **Untrusted** | Remote servers behind approved domains | TLS-only (port 443); but no certificate pinning |
| Slack session cookies | **Untrusted** | Extracted from Chrome browser at container start | Short-lived; but if exfiltrated, provides full Slack session access |

## Intentional Design Choices

### RW source mount (`~/src/`)

Source repositories are mounted read-write because agents must be able to edit code -- that is their primary function. The risk of a compromised agent modifying code is accepted. Mitigation: git history, code review, ephemeral containers.

### All agents share the same container user

All 17 agents run as the same UID (1000) inside the same container image. This simplifies bind-mount permissions and avoids UID mapping complexity. The trade-off: one compromised agent can read another agent's config dir and environment variables. Accepted because the alternative (per-agent containers with separate UIDs) would require 17x the image storage and break shared package caches.

### API keys in environment variables

Keys are injected via `.env` files rather than a secrets broker because the setup must work offline and without additional infrastructure. The risk (`/proc/self/environ` readable by same-UID processes) is accepted as inherent to the single-user container model.

### `curl | sh` for binary agents

Six agents (goose, grok, forge, kiro, cursor, jcode) are installed via their official install scripts. This is accepted because: the scripts run only during image build (as root, inside a throwaway build layer), quarantine ensures release age >= 7 days, and the resulting binaries are captured in the image layer. The remaining risk is a compromised installer script that the quarantine window does not catch.

### No inter-container network policy

All containers on the securetty bridge (172.30.100.0/24) can communicate freely. This is by design: agents need to reach OmniRoute, Headroom, Ollama, and CloudCLI. Adding per-service network policies would add complexity without meaningful security gain since all services run as the same user and share the same trust level.

### npm `ignore-scripts` global default

Set to `true` globally via `.npmrc` and environment variable. This breaks packages that require post-install build steps (native addons). Accepted because agent packages are pre-built in the image; project-level `npm install` can override per-project if needed.
