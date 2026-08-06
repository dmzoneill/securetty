# securetty Threat Model

## 1. System Context

securetty is a sandboxed AI development environment running on Fedora 45 with rootless podman containers. The system hosts 17 AI CLI agents (Claude Code, Codex, Gemini CLI, Cursor, Cline, OpenCode, Amp, Kilo, Aider, OpenHands, Goose, Grok, Forge, Kiro, Pi AI, Kimi, JCode) inside ephemeral containers with credential isolation and delayed package ingestion.

**Key components:**

- **Rootless podman** -- all containers run unprivileged under UID 1000, no daemon, no root
- **pasta networking** -- userspace TCP/UDP/ICMP forwarding, no veth pairs, no bridge requiring root
- **nftables egress whitelist** -- `inet securetty_egress` table loaded in the rootless-netns namespace; default-drop policy for container subnet 10.89.100.0/24 with explicit allowed_ipv4 set populated by DNS resolution of ~50 approved domains
- **OmniRoute** -- AI provider router (port 4000) that centralizes API key usage across all agents
- **aardvark DNS** -- podman's built-in DNS server for container name resolution, forwards external queries to host DNS via pasta forwarder (169.254.1.1); VPN domains resolve automatically when VPN is connected
- **Delayed ingestion** -- packages installed only from versions published >= 7 days ago (configurable via `securetty_quarantine_days`)

## 2. Assets

| Asset | Sensitivity | Location | Notes |
|-------|-------------|----------|-------|
| SSH private keys | CRITICAL | Host `~/.ssh/`, never in container | Socket forwarded read-only via restricted agent |
| GPG private keys | CRITICAL | Host `~/.gnupg/`, never in container | Extra-socket forwarded read-only, no export capability |
| kubeconfig | CRITICAL | `~/.kube/` bind-mounted RW | OpenShift/K8s cluster credentials |
| AI provider API keys | HIGH | GNU pass store, injected via `.env` | OpenAI, Anthropic, Gemini, Mistral, etc. |
| GitLab PAT | HIGH | GNU pass, `.env` | Internal Red Hat GitLab access |
| Jira PAT | HIGH | GNU pass, `.env` | Issue tracker access |
| Slack session cookies | HIGH | Extracted from Chrome at container start | XOXC token + d cookie |
| WordPress credentials | HIGH | GNU pass, `.env` | Blog publishing access |
| Source code repositories | MEDIUM | `~/src/` bind-mounted RW | Personal and work repos |
| Agent config directories | MEDIUM | `~/.<agent>/` bind-mounted RW | Session history, preferences, cached auth |
| Container images | LOW | podman local storage | Rebuilt from Containerfile, reproducible |
| DNS cache | LOW | In-memory, aardvark process | Ephemeral, no persistence |

## 3. Entry Points and Trust Boundaries

### Entry points

| Entry Point | Protocol | Trust Level | Notes |
|-------------|----------|-------------|-------|
| Container process (npm/pip packages) | Process execution | Semi-trusted | Quarantine mitigates but does not eliminate supply chain risk; npm `ignore-scripts=true` set |
| MCP stdio servers | stdin/stdout JSON-RPC | Semi-trusted | Headroom, tokensave, custom skills; run as same UID |
| Egress network | HTTPS (443) | Untrusted | Filtered by nftables allowlist + domain resolution |
| Bind-mounted host dirs | Filesystem | Trusted | `~/src/` RW, `~/bin/` RO, `~/.ssh/config` RO |
| aardvark DNS | UDP/53 to gateway | Trusted | Container-internal, forwards to host resolver |
| OmniRoute API | HTTP (4000) | Trusted | Internal network only, 127.0.0.1 on host |
| Ollama API | HTTP (11434) | Trusted | Internal network only, local LLM inference |

### Trust boundaries

1. **Host <-> Container**: rootless podman, `no-new-privileges`, all capabilities dropped except `SYS_NICE`, read-only root filesystem, private PID/IPC namespaces
2. **Container <-> Internet**: nftables egress whitelist in rootless-netns, only resolved IPs from approved domain list
3. **Container <-> Host secrets**: SSH/GPG sockets forwarded read-only (private keys never enter container); API keys injected via `.env` files regenerated at each start
4. **Container <-> Container**: podman bridge network (securetty 10.89.100.0/24), inter-container traffic allowed

## 4. Threats

| # | Threat | Actor | Attack Surface | Impact | Likelihood | Status | Controls |
|---|--------|-------|---------------|--------|------------|--------|----------|
| T1 | Malicious package exfiltrates secrets via network | Supply chain attacker | npm/pip dependency in agent | API keys, tokens sent to attacker C2 | Medium | Mitigated | Egress whitelist (nftables default-drop), 7-day quarantine, `npm ignore-scripts=true`, per-service `.env` least privilege |
| T2 | `curl \| sh` supply chain compromise during build | Supply chain attacker | Binary agent installers (goose, grok, forge, kiro, cursor, jcode) | Arbitrary code in image as root during build | Medium | Partially mitigated | Quarantine checks GitHub release age before install; pinned repos; but installer scripts themselves are not hash-verified |
| T3 | RW bind mount poisoning | Compromised agent process | `~/src/` mount (read-write) | Persistent backdoor in source repos, dotfiles | Medium | Accepted | Agent containers are ephemeral (`--rm`); `~/bin/` is read-only; git history provides audit trail; but `~/src/` is RW by design |
| T4 | DNS leak bypasses egress whitelist | Malicious package or agent | DNS queries via aardvark to host resolver | Data exfiltration via DNS tunneling (TXT/CNAME encoding) | Low | Open | aardvark forwards to host DNS which resolves normally; no DNS query filtering or logging currently in place |
| T5 | Stale egress rules allow unintended destinations | Operator error | nftables allowed_ipv4 set after domain IP changes | Container reaches IPs that no longer belong to approved services | Low | Mitigated | `make egress` re-resolves all domains; CIDR ranges cover cloud providers; but no automatic refresh schedule |
| T6 | `/proc/self/environ` readable exposes injected secrets | Compromised agent process | procfs inside container | All `.env` vars (API keys, tokens) readable by any process in container | Medium | Mitigated | procfs masking applied (`mask=/proc/mounts:...:/sys/class/dmi`); but `/proc/self/environ` is readable by same-UID processes by design in Linux |
| T7 | MCP server compromise | Compromised MCP server (headroom, tokensave) | stdio JSON-RPC channel | Arbitrary tool calls, file reads, code execution as container user | Low | Mitigated | MCP servers run as same UID (no privilege escalation); read-only root filesystem limits persistence; ephemeral containers |
| T8 | Agent config injection | Attacker modifying `~/.<agent>/` dirs on host | Bind-mounted config directories (RW) | Poisoned agent settings, malicious MCP server config, altered system prompts | Low | Accepted | Config dirs are user-owned on host; host compromise is out of scope; container has same access as host user |
| T9 | Shared package cache poisoning | Supply chain attacker | Named volumes (npm-cache, pip-cache, uv-cache, cargo-cache) | Cached malicious package served to future containers without re-download | Low | Partially mitigated | Quarantine applies at install time not cache time; `make nuke` removes volumes; no cache integrity verification |
| T10 | Container escape via kernel vulnerability | Sophisticated attacker | Linux kernel, podman runtime | Full host access | Very Low | Mitigated | Rootless podman (user namespace), all caps dropped, `no-new-privileges`, private PID/IPC, read-only root; kernel updates via Fedora |

## 5. Deprioritized Threats

| Threat | Reason |
|--------|--------|
| SELinux bypass | Fedora SELinux is enforcing on host but `label=disable` is set on containers for bind-mount compatibility; SELinux inside container is not a relied-upon control |
| GPU-based attacks | GPU passthrough (`/dev/dri`, `/dev/accel/accel0`) is for Ollama inference and mutter compositor only; GPU removed from dev workflow; side-channel attacks on GPU memory are out of scope for this threat model |

## 6. Open Questions

- **Zero-secret environment feasibility**: Can we eliminate `.env` injection entirely and use a secrets broker (e.g., Vault agent, SPIFFE) that provides short-lived tokens with automatic rotation? Current model has all secrets readable in `/proc/self/environ`.
- **Hash verification for packages**: Binary agent installers (`curl | sh`) have no integrity verification beyond quarantine age. Can we pin SHA256 hashes for installer scripts and verify before execution?
- **DNS query filtering**: Should we add DNS-layer filtering (e.g., dnscrypt-proxy, CoreDNS with policy) to prevent DNS tunneling exfiltration?
- **Egress refresh automation**: Should `make egress` run on a cron schedule to keep nftables rules current as cloud provider IPs rotate?
- **Cache volume integrity**: Can we add content-addressable verification for shared package caches to detect poisoning?

## 7. Provenance

| Field | Value |
|-------|-------|
| Bootstrap mode | Automated security audit |
| Date | 2026-08-06 |
| Authors | securetty maintainers |
| Review cadence | Quarterly or after significant architecture changes |
| Template | WG 8-section threat model |

## 8. Mitigations Summary

| Control | What It Protects | Implementation |
|---------|-----------------|----------------|
| Delayed ingestion (quarantine) | Supply chain attacks | `install-delayed.sh`: npm versions published >= 7d ago via `npm view time`; pip via `uv --exclude-newer`; binaries via GitHub release API date check |
| nftables egress whitelist | Data exfiltration | `securetty-egress.nft` table with default-drop in rootless-netns; `resolve-egress.sh` populates allowed_ipv4 set from ~50 approved domains + cloud CIDR ranges |
| Restricted SSH agent | SSH key theft | `ssh-agent-restricted.sh`: dedicated agent with only configured keys loaded; socket forwarded read-only into container; private key material never enters container |
| Read-only root filesystem | Persistent malware | `read_only: true` in compose; writable paths limited to tmpfs (`/tmp`, `~/.local/bin`) and explicit bind mounts |
| procfs masking | Host info leakage | `security_opt` masks `/proc/mounts`, `/proc/self/mounts`, `/proc/self/mountinfo`, `/proc/cmdline`, `/proc/partitions`, `/proc/diskstats`, `/proc/version`, `/sys/class/dmi` |
| Per-service .env files | Credential blast radius | `generate-env.sh` creates `.env.omniroute` (provider keys only), `.env.cloudcli` (Vertex only); dev container gets full set |
| Capability drop | Privilege escalation | `cap_drop: ALL` + `no-new-privileges:true` on all containers; only `SYS_NICE` added for mutter scheduling |
| npm ignore-scripts | Malicious install hooks | `npm_config_ignore_scripts=true` set in container environment and `.npmrc` |
| Private PID/IPC namespaces | Cross-container info leak | `pid: private`, `ipc: private` on dev container |
| Container machine-id | Host fingerprinting | `/etc/machine-id` regenerated at build time with `dbus-uuidgen` |
| Secret scanner | Leaked credential detection | `scan-secrets.sh` scans AI conversation history for API key patterns (Anthropic, OpenAI, AWS, GitHub, GitLab, Slack, Google) |
| GPG extra-socket forwarding | GPG key theft | GPG agent extra socket forwarded read-only; no key export capability from container |
