# Threat Model: securetty

## 1. System context

securetty is a sandboxed AI development environment running on Fedora 45 with rootless podman containers. The system hosts 17 AI CLI agents (Claude Code, Codex, Gemini CLI, Cursor, Cline, OpenCode, Amp, Kilo, Aider, OpenHands, Goose, Grok, Forge, Kiro, Pi AI, Kimi, JCode) inside ephemeral containers with credential isolation and delayed package ingestion.

**Key components:**

- **Rootless podman** -- all containers run unprivileged under UID 1000, no daemon, no root
- **pasta networking** -- userspace TCP/UDP/ICMP forwarding, no veth pairs, no bridge requiring root
- **nftables egress whitelist** -- `inet securetty_egress` table loaded in the rootless-netns namespace; default-drop policy for container subnet 172.30.100.0/24 with explicit allowed_ipv4 set populated by DNS resolution of ~50 approved domains
- **OmniRoute** -- AI provider router (port 4000) that centralizes API key usage across all agents
- **aardvark DNS** -- podman's built-in DNS server for container name resolution, forwards external queries to host DNS via pasta forwarder (169.254.1.1); VPN domains resolve automatically when VPN is connected
- **Delayed ingestion** -- packages installed only from versions published >= 7 days ago (configurable via `securetty_quarantine_days`)

## 2. Assets

| asset | description | sensitivity | location |
|---|---|---|---|
| SSH private keys | Socket forwarded read-only via restricted agent | critical | Host `~/.ssh/`, never in container |
| GPG private keys | Extra-socket forwarded read-only, no export capability | critical | Host `~/.gnupg/`, never in container |
| kubeconfig | OpenShift/K8s cluster credentials | critical | `~/.kube/` bind-mounted RW |
| AI provider API keys | OpenAI, Anthropic, Gemini, Mistral, etc. | high | GNU pass store, injected via `.env` |
| GitLab PAT | Internal Red Hat GitLab access | high | GNU pass, `.env` |
| Jira PAT | Issue tracker access | high | GNU pass, `.env` |
| Slack session cookies | XOXC token + d cookie; extracted from Chrome at container start | high | Extracted from Chrome at container start |
| WordPress credentials | Blog publishing access | high | GNU pass, `.env` |
| Source code repositories | Personal and work repos | medium | `~/src/` bind-mounted RW |
| Agent config directories | Session history, preferences, cached auth | medium | `~/.<agent>/` bind-mounted RW |
| Container images | Rebuilt from Containerfile, reproducible | low | podman local storage |
| DNS cache | Ephemeral, no persistence | low | In-memory, aardvark process |

## 3. Entry points & trust boundaries

| entry_point | description | trust_boundary | reachable_assets |
|---|---|---|---|
| Container process (npm/pip packages) | Semi-trusted process execution; quarantine mitigates but does not eliminate supply chain risk; npm `ignore-scripts=true` set | Host ↔ Container: rootless podman, `no-new-privileges`, all caps dropped, read-only root FS, private PID/IPC namespaces | AI provider API keys, GitLab PAT, Jira PAT, Slack session cookies, source code repos, agent config dirs |
| MCP stdio servers | Semi-trusted stdin/stdout JSON-RPC (headroom, tokensave, custom skills); run as same UID | Host ↔ Container: same UID, no privilege escalation boundary | Source code repositories, Agent config directories |
| Egress network | Untrusted HTTPS (443); filtered by nftables allowlist + domain resolution | Container ↔ internet: nftables egress whitelist in rootless-netns, only resolved IPs from approved domain list | AI provider API keys, GitLab PAT, Jira PAT |
| Bind-mounted host dirs | Trusted filesystem access: `~/src/` RW, `~/bin/` RO, `~/.ssh/config` RO | Host ↔ Container: rootless podman bind mounts, read-only for sensitive paths | Source code repositories, SSH private keys, Agent config directories |
| aardvark DNS | Trusted UDP/53 to gateway; container-internal, forwards to host resolver | Container ↔ internet: DNS forwarding via pasta forwarder (169.254.1.1) | DNS cache |
| OmniRoute API | Trusted HTTP (4000); internal network only, 127.0.0.1 on host | Container ↔ Container: podman bridge network (securetty 172.30.100.0/24) | AI provider API keys |
| Ollama API | Trusted HTTP (11434); internal network only, local LLM inference | Container ↔ Container: podman bridge network (securetty 172.30.100.0/24) | — |

**Trust boundary details:**

1. **Host ↔ Container**: rootless podman, `no-new-privileges`, all capabilities dropped except `no capabilities added`, read-only root filesystem, private PID/IPC namespaces
2. **Container ↔ internet**: nftables egress whitelist in rootless-netns, only resolved IPs from approved domain list
3. **Container ↔ Host secrets**: SSH/GPG sockets forwarded read-only (private keys never enter container); API keys injected via `.env` files regenerated at each start
4. **Container ↔ Container**: podman bridge network (securetty 172.30.100.0/24), inter-container traffic allowed

## 4. Threats

| ID | threat | actor | surface | asset | impact | likelihood | status | controls | evidence |
|---|---|---|---|---|---|---|---|---|---|
| T1 | Malicious package exfiltrates secrets via network | supply_chain | npm/pip dependency in agent | AI provider API keys, GitLab PAT, Jira PAT, Slack session cookies | critical | possible | mitigated | Egress whitelist (nftables default-drop), 7-day quarantine, `npm ignore-scripts=true`, per-service `.env` least privilege | — |
| T2 | `curl \| sh` supply chain compromise during build | supply_chain | Binary agent installers (goose, grok, forge, kiro, cursor, jcode) | Container images | critical | possible | partially_mitigated | Quarantine checks GitHub release age before install; pinned repos; but installer scripts themselves are not hash-verified | — |
| T3 | RW bind mount poisoning | local_user | `~/src/` mount (read-write) | Source code repositories | high | possible | risk_accepted | Agent containers are ephemeral (`--rm`); `~/bin/` is read-only; git history provides audit trail; but `~/src/` is RW by design | — |
| T4 | DNS leak bypasses egress whitelist | local_user | DNS queries via aardvark to host resolver | AI provider API keys | high | rare | unmitigated | aardvark forwards to host DNS which resolves normally; no DNS query filtering or logging currently in place | — |
| T5 | Stale egress rules allow unintended destinations | insider | nftables allowed_ipv4 set after domain IP changes | AI provider API keys | medium | rare | mitigated | `make egress` re-resolves all domains; CIDR ranges cover cloud providers; but no automatic refresh schedule | — |
| T6 | `/proc/self/environ` readable exposes injected secrets | local_user | procfs inside container | AI provider API keys, GitLab PAT, Jira PAT | critical | possible | mitigated | procfs masking applied (`mask=/proc/mounts:...:/sys/class/dmi`); but `/proc/self/environ` is readable by same-UID processes by design in Linux | — |
| T7 | MCP server compromise | local_user | stdio JSON-RPC channel | Source code repositories, Agent config directories | high | rare | mitigated | MCP servers run as same UID (no privilege escalation); read-only root filesystem limits persistence; ephemeral containers | — |
| T8 | Agent config injection | local_user | Bind-mounted config directories (RW) | Agent config directories | medium | rare | risk_accepted | Config dirs are user-owned on host; host compromise is out of scope; container has same access as host user | — |
| T9 | Shared package cache poisoning | supply_chain | Named volumes (npm-cache, pip-cache, uv-cache, cargo-cache) | Container images | high | rare | partially_mitigated | Quarantine applies at install time not cache time; `make nuke` removes volumes; no cache integrity verification | — |
| T10 | Container escape via kernel vulnerability | remote_unauth | Linux kernel, podman runtime | SSH private keys, GPG private keys | critical | very_rare | mitigated | Rootless podman (user namespace), all caps dropped, `no-new-privileges`, private PID/IPC, read-only root; kernel updates via Fedora | — |

## 5. Deprioritized

| threat | reason |
|---|---|
| SELinux bypass | Fedora SELinux is enforcing on host but `label=disable` is set on containers for bind-mount compatibility; SELinux inside container is not a relied-upon control |
| GPU-based attacks | GPU passthrough (`/dev/dri`, `/dev/accel/accel0`) is for Ollama inference and mutter compositor only; GPU removed from dev workflow; side-channel attacks on GPU memory are out of scope for this threat model |

## 6. Open questions

- **Zero-secret environment feasibility**: Can we eliminate `.env` injection entirely and use a secrets broker (e.g., Vault agent, SPIFFE) that provides short-lived tokens with automatic rotation? Current model has all secrets readable in `/proc/self/environ`.
- **Hash verification for packages**: Binary agent installers (`curl | sh`) have no integrity verification beyond quarantine age. Can we pin SHA256 hashes for installer scripts and verify before execution?
- **DNS query filtering**: Should we add DNS-layer filtering (e.g., dnscrypt-proxy, CoreDNS with policy) to prevent DNS tunneling exfiltration?
- **Egress refresh automation**: Should `make egress` run on a cron schedule to keep nftables rules current as cloud provider IPs rotate?
- **Cache volume integrity**: Can we add content-addressable verification for shared package caches to detect poisoning?

## 7. Provenance

- mode: bootstrap
- date: 2026-08-06
- target: ~/src/securetty
- inputs: SECURITY.md, compose configuration, nftables rules, Containerfile, Ansible group_vars, WG 8-section threat model template
- owner: securetty maintainers

Review cadence: quarterly or after significant architecture changes.

## 8. Recommended mitigations

| mitigation | threat_ids | closes_class | effort |
|---|---|---|---|
| Delay package ingestion by >= 7 days (`install-delayed.sh`: npm versions via `npm view time`; pip via `uv --exclude-newer`; binaries via GitHub release API date check) | T1, T2, T9 | partial | M |
| Enforce nftables egress whitelist with default-drop (`securetty-egress.nft` table in rootless-netns; `resolve-egress.sh` populates allowed_ipv4 set from ~50 approved domains + cloud CIDR ranges) | T1, T4, T5 | partial | M |
| Forward SSH agent socket read-only with restricted key set (`ssh-agent-restricted.sh`: dedicated agent with only configured keys loaded; private key material never enters container) | T1, T6 | yes | S |
| Enable read-only root filesystem (`read_only: true` in compose; writable paths limited to tmpfs `/tmp`, `~/.local/bin` and explicit bind mounts) | T3, T7 | partial | S |
| Mask sensitive procfs paths (`security_opt` masks `/proc/mounts`, `/proc/self/mounts`, `/proc/self/mountinfo`, `/proc/cmdline`, `/proc/partitions`, `/proc/diskstats`, `/proc/version`, `/sys/class/dmi`) | T6 | partial | S |
| Generate per-service `.env` files with least-privilege credential sets (`generate-env.sh` creates `.env.omniroute` for provider keys only, `.env.cloudcli` for Vertex only; dev container gets full set) | T1, T6 | partial | S |
| Drop all capabilities (`cap_drop: ALL` + `no-new-privileges:true` on all containers; only `no capabilities added` added for mutter scheduling) | T10 | partial | S |
| Disable npm install scripts (`npm_config_ignore_scripts=true` set in container environment and `.npmrc`) | T1 | partial | S |
| Isolate PID and IPC namespaces (`pid: private`, `ipc: private` on dev container) | T6, T7 | partial | S |
| Regenerate container machine-id at build time (`/etc/machine-id` regenerated with `dbus-uuidgen`) | T6 | yes | S |
| Scan AI conversation history for leaked credentials (`scan-secrets.sh` scans for API key patterns: Anthropic, OpenAI, AWS, GitHub, GitLab, Slack, Google) | T1 | partial | S |
| Forward GPG extra-socket read-only (GPG agent extra socket forwarded; no key export capability from container) | T1, T6 | yes | S |
