# Security Levels -- securetty vs Carbonite 7-Tier Model

Current securetty posture mapped against Carbonite's seven security tiers, from least to most restrictive.

## Tier Mapping

| Tier | Carbonite Definition | securetty Status | Notes |
|------|---------------------|-----------------|-------|
| **1 -- Unrestricted** | No controls, full host access | **Not used** | securetty was built to eliminate this; pre-securetty host state had 39 env vars, no resource limits, all SSH keys loaded |
| **2 -- Basic isolation** | Separate user account or VM, no network filtering | **Exceeded** | Rootless podman containers go beyond user-account separation |
| **3 -- Container sandbox** | Containers with dropped capabilities, resource limits | **Enforced** | `cap_drop: ALL`, `no-new-privileges`, CPU/memory limits, private PID/IPC, read-only root filesystem |
| **4 -- Network egress control** | Allowlist-only outbound network | **Enforced** | nftables `securetty_egress` table in rootless-netns with default-drop; ~50 approved domains resolved to IPs; cloud provider CIDR ranges |
| **5 -- Credential isolation** | Secrets injected at runtime, not baked in images; least-privilege per service | **Enforced** | GNU pass -> `.env` at start; per-service env files (`.env.omniroute`, `.env.cloudcli`); SSH/GPG agent forwarding (key material never enters container) |
| **6 -- Supply chain hardening** | Package provenance verification, reproducible builds | **Partially enforced** | 7-day quarantine on npm/pip/binary packages; `npm ignore-scripts=true`; but no hash pinning for binary installers (`curl \| sh`), no SBOM generation, no Sigstore verification |
| **7 -- Zero trust / attestation** | Remote attestation, signed images, policy-as-code, runtime integrity monitoring | **Not enforced** | No image signing, no admission controller, no runtime integrity monitoring, no policy engine (OPA/Gatekeeper) |

## What Is Enforced

- Rootless containers with all capabilities dropped (only `SYS_NICE` for compositor)
- `no-new-privileges` on every container
- Read-only root filesystem with explicit writable tmpfs mounts
- Private PID and IPC namespaces
- procfs masking (`/proc/mounts`, `/proc/cmdline`, `/proc/version`, `/sys/class/dmi`, etc.)
- Unique machine-id per container build (no host fingerprint leakage)
- nftables default-drop egress with domain-resolved allowlist
- SSH agent restricted to configured keys only, socket forwarded read-only
- GPG agent extra-socket forwarding, read-only, no key export
- API keys from GNU pass, regenerated at every container start
- Per-service `.env` files (OmniRoute gets provider keys only, CloudCLI gets Vertex only)
- 7-day package quarantine for npm, pip, and GitHub binary releases
- npm `ignore-scripts=true` globally
- pip `require-virtualenv=true` for project-level installs
- Secret scanner for AI conversation history (`make scan`)
- Container resource limits (CPU + memory per service)

## What Is Not Enforced

- **Image signing/verification** -- container images are built locally, not signed or verified against a trust root
- **SBOM generation** -- no software bill of materials produced at build time
- **Hash pinning for binary installers** -- `curl | sh` installers for goose, grok, forge, kiro, cursor, jcode are not hash-verified
- **DNS filtering** -- no query-level DNS filtering; DNS tunneling exfiltration is possible
- **Runtime integrity monitoring** -- no file integrity monitoring (AIDE/Tripwire) or eBPF-based runtime security (Falco/Tetragon)
- **SELinux inside containers** -- `label=disable` set for bind-mount compatibility
- **Automatic egress rule refresh** -- nftables rules are static until `make egress` is re-run
- **Secrets rotation** -- API keys are long-lived; no automatic rotation mechanism
- **Network policy between containers** -- all containers on the same bridge can communicate freely
