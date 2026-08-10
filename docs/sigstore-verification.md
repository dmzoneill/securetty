# Sigstore/Cosign Verification

How securetty uses Sigstore to verify the provenance of binary agents and (in future) container images.

## What Is Sigstore

[Sigstore](https://sigstore.dev) is an open-source project that provides cryptographic signing and verification for software artifacts. It consists of:

- **Cosign** -- CLI tool for signing and verifying container images and blobs (binary files, tarballs, checksums).
- **Fulcio** -- Certificate authority that issues short-lived certificates tied to an OIDC identity (e.g., a GitHub Actions workflow).
- **Rekor** -- Transparency log that records signing events, providing a tamper-evident audit trail.

Together these enable *keyless signing*: a CI pipeline (e.g., GitHub Actions) can sign a release artifact using its workload identity. Verifiers check the signature against Rekor without needing the signer's public key.

### Why It Matters for Supply Chain

securetty installs six binary agents via `curl | sh` (goose, grok, forge, kiro, cursor, jcode). The 7-day quarantine mitigates time-sensitive compromises, but does not prove that a release was produced by the project's CI pipeline. Sigstore verification closes this gap: if a project signs its releases, cosign can cryptographically confirm that the artifact was built by a trusted GitHub Actions workflow in the correct repository.

This moves securetty from Tier 6 ("partially enforced supply chain hardening") toward Tier 7 on the [Carbonite security model](security-tiers.md).

## How securetty Uses It

### verify-signatures.sh

The script `roles/containers/files/verify-signatures.sh` provides two verification modes:

#### Binary mode (`--binary`)

```bash
verify-signatures.sh --skip-if-missing --binary goose block/goose v1.0.0
```

1. Probes the GitHub release for a `.bundle` (Sigstore bundle) or `.sig` (detached signature) file.
2. Downloads the corresponding release artifact.
3. Runs `cosign verify-blob` with the Sigstore transparency log, checking that the signature's OIDC identity matches the expected GitHub repository.
4. Returns 0 on success, 1 on failure.

#### Image mode (`--image`)

```bash
verify-signatures.sh --skip-if-missing --image ghcr.io/org/image:tag
```

1. Runs `cosign verify` with keyless verification against the Sigstore transparency log.
2. Returns 0 on success, 1 on failure.

#### Graceful degradation (`--skip-if-missing`)

When `--skip-if-missing` is passed:

- If cosign is not installed, the script warns and exits 0.
- If no signature artifact is found for a binary release, the script warns and exits 0.
- Image verification failures still exit 0 (with a warning), since the image may not be signed.

This allows the script to be called unconditionally during builds without breaking agents that do not yet publish Sigstore signatures.

### Integration with install-delayed.sh

The verification script is designed to be called from `install-delayed.sh.j2` before or after each binary agent install. Example integration point:

```bash
# In install_github_binary(), after determining the release tag:
if [ -x /usr/local/bin/verify-signatures.sh ]; then
    /usr/local/bin/verify-signatures.sh --skip-if-missing \
        --binary "$name" "$repo" "$tag" || true
fi
```

The `|| true` ensures that verification failures do not block the build while adoption is incremental. Once all agents publish signatures, the `|| true` and `--skip-if-missing` can be removed to enforce mandatory verification.

## Installing Cosign in the Container

Cosign can be added to the devbase image layer. Two options:

### Option 1: Binary download (recommended for container builds)

Add to `Containerfile.devbase.j2`:

```dockerfile
RUN COSIGN_VERSION="v2.4.3" && \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
        -o /usr/local/bin/cosign && \
    chmod +x /usr/local/bin/cosign
```

### Option 2: Go install (if Go toolchain is already present)

```bash
go install github.com/sigstore/cosign/v2/cmd/cosign@latest
```

### Egress requirement

The egress allowlist in `group_vars/all.yml` already includes `*.sigstore.dev`, which covers Rekor (transparency log) and Fulcio (certificate authority) API calls made by cosign during verification.

## Current Limitations

| Limitation | Detail |
|-----------|--------|
| Not all agents publish signatures | Of the six binary agents, not all release Sigstore-signed artifacts. `--skip-if-missing` handles this gracefully. |
| Container images are built locally | securetty builds images with `podman build`, not pulled from a registry. Image signing/verification applies only if images are pushed to and pulled from a registry in the future. |
| No enforcement yet | `verify-signatures.sh` exists as a standalone tool. It is not yet wired into `install-delayed.sh.j2` -- that integration is a follow-up change. |
| Cosign not yet installed | The devbase image does not yet include cosign. It must be added before verification can run during builds. |
| OIDC issuer assumption | The script assumes GitHub Actions (`token.actions.githubusercontent.com`) as the OIDC issuer. Agents signed via other CI systems (GitLab, Buildkite) would need issuer configuration. |

## Related Files

- `roles/containers/files/verify-signatures.sh` -- verification script
- `roles/containers/templates/install-delayed.sh.j2` -- binary agent installer (integration target)
- `group_vars/all.yml` -- `securetty_binary_agents` list and `securetty_allowed_domains` (includes `*.sigstore.dev`)
- `docs/security-tiers.md` -- Tier 6/7 supply chain hardening status
- `docs/trust-model.md` -- binary installer trust classification
