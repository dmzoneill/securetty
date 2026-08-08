#!/bin/bash
# Sigstore/Cosign signature verification for binary agents and container images.
# Called during image build or at runtime to verify supply chain provenance.
# Outputs verification detail to stderr; only exit code matters to callers.
#   0 = verified (or skipped gracefully)
#   1 = verification failed
set -euo pipefail

SKIP_IF_MISSING=false
MODE=""
BINARY_NAME=""
BINARY_REPO=""
BINARY_VERSION=""
IMAGE_REF=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage:
  verify-signatures.sh [--skip-if-missing] --binary <name> <repo> <version>
  verify-signatures.sh [--skip-if-missing] --image <image-ref>

Modes:
  --binary <name> <repo> <version>
      Verify a GitHub release artifact using cosign verify-blob.
      Downloads .sig or .bundle file from the GitHub release and checks it
      against the Sigstore transparency log.

  --image <image-ref>
      Verify a container image signature using cosign verify (keyless).

Flags:
  --skip-if-missing   Don't fail if cosign is not installed (warn and exit 0).
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-if-missing)
            SKIP_IF_MISSING=true
            shift
            ;;
        --binary)
            MODE="binary"
            [ $# -ge 4 ] || { echo "ERROR: --binary requires <name> <repo> <version>" >&2; usage; }
            BINARY_NAME="$2"
            BINARY_REPO="$3"
            BINARY_VERSION="$4"
            shift 4
            ;;
        --image)
            MODE="image"
            [ $# -ge 2 ] || { echo "ERROR: --image requires <image-ref>" >&2; usage; }
            IMAGE_REF="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            ;;
    esac
done

[ -n "$MODE" ] || { echo "ERROR: no mode specified" >&2; usage; }

# ---------------------------------------------------------------------------
# Check cosign availability
# ---------------------------------------------------------------------------
if ! command -v cosign >/dev/null 2>&1; then
    if [ "$SKIP_IF_MISSING" = true ]; then
        echo "WARN: cosign not installed, skipping verification (--skip-if-missing)" >&2
        exit 0
    else
        echo "ERROR: cosign not installed and --skip-if-missing not set" >&2
        exit 1
    fi
fi

echo "cosign $(cosign version 2>/dev/null | head -1 || echo 'unknown version')" >&2

# ---------------------------------------------------------------------------
# Binary mode: verify a GitHub release artifact
# ---------------------------------------------------------------------------
verify_binary() {
    local name="$1" repo="$2" version="$3"
    local tag="$version"
    local base_url="https://github.com/${repo}/releases/download/${tag}"
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" EXIT

    echo "verify-binary: ${name} ${repo} ${tag}" >&2

    # Determine artifact filename patterns to look for.
    # Many projects use: <name>-<os>-<arch>{,.sig,.bundle,.pem}
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    # Try to find a cosign bundle first (preferred), then a detached .sig
    local bundle_url="" sig_url="" cert_url=""
    local artifact_base="${name}-${os}-${arch}"

    # Strategy: probe for common signature file patterns
    local found_method=""

    # 1. Try .bundle (Sigstore bundle — self-contained proof)
    for candidate in \
        "${base_url}/${artifact_base}.bundle" \
        "${base_url}/${name}.bundle" \
        "${base_url}/cosign.bundle" \
        "${base_url}/${artifact_base}.cosign.bundle"; do
        if curl -fsSL -o "${tmpdir}/artifact.bundle" "$candidate" 2>/dev/null; then
            bundle_url="$candidate"
            found_method="bundle"
            echo "  found bundle: $candidate" >&2
            break
        fi
    done

    # 2. Try detached .sig + optional .pem certificate
    if [ -z "$found_method" ]; then
        for candidate in \
            "${base_url}/${artifact_base}.sig" \
            "${base_url}/${name}.sig" \
            "${base_url}/SHA256SUMS.sig"; do
            if curl -fsSL -o "${tmpdir}/artifact.sig" "$candidate" 2>/dev/null; then
                sig_url="$candidate"
                found_method="sig"
                echo "  found signature: $candidate" >&2
                break
            fi
        done

        # Look for an accompanying certificate
        if [ -n "$sig_url" ]; then
            local cert_candidate="${sig_url%.sig}.pem"
            if curl -fsSL -o "${tmpdir}/artifact.pem" "$cert_candidate" 2>/dev/null; then
                cert_url="$cert_candidate"
                echo "  found certificate: $cert_candidate" >&2
            fi
        fi
    fi

    if [ -z "$found_method" ]; then
        echo "  WARN: no .sig or .bundle found for ${name} ${tag} -- agent may not publish Sigstore signatures" >&2
        if [ "$SKIP_IF_MISSING" = true ]; then
            echo "  skipping verification (no signature artifact)" >&2
            return 0
        else
            echo "  FAIL: cannot verify without signature artifact" >&2
            return 1
        fi
    fi

    # Download the actual release artifact to verify against
    local artifact_downloaded=false
    for candidate in \
        "${base_url}/${artifact_base}" \
        "${base_url}/${artifact_base}.tar.gz" \
        "${base_url}/${name}-${os}-${arch}.tar.gz" \
        "${base_url}/${name}"; do
        if curl -fsSL -o "${tmpdir}/artifact" "$candidate" 2>/dev/null; then
            artifact_downloaded=true
            echo "  downloaded artifact: $candidate" >&2
            break
        fi
    done

    if [ "$artifact_downloaded" = false ]; then
        echo "  WARN: could not download release artifact for blob verification" >&2
        if [ "$SKIP_IF_MISSING" = true ]; then
            echo "  skipping verification (artifact not downloadable)" >&2
            return 0
        fi
        return 1
    fi

    # Run cosign verify-blob
    local rc=0
    case "$found_method" in
        bundle)
            echo "  running: cosign verify-blob --bundle (Sigstore transparency log)" >&2
            cosign verify-blob \
                --bundle "${tmpdir}/artifact.bundle" \
                --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
                --certificate-identity-regexp="github\\.com/${repo}" \
                "${tmpdir}/artifact" >&2 2>&1 || rc=$?
            ;;
        sig)
            echo "  running: cosign verify-blob --signature (detached sig)" >&2
            local cert_args=()
            if [ -n "$cert_url" ]; then
                cert_args=(--cert "${tmpdir}/artifact.pem"
                           --certificate-oidc-issuer="https://token.actions.githubusercontent.com"
                           --certificate-identity-regexp="github\\.com/${repo}")
            else
                cert_args=(--certificate-oidc-issuer="https://token.actions.githubusercontent.com"
                           --certificate-identity-regexp="github\\.com/${repo}")
            fi
            cosign verify-blob \
                --signature "${tmpdir}/artifact.sig" \
                "${cert_args[@]}" \
                "${tmpdir}/artifact" >&2 2>&1 || rc=$?
            ;;
    esac

    if [ "$rc" -eq 0 ]; then
        echo "  OK: ${name} ${tag} signature verified" >&2
    else
        echo "  FAIL: ${name} ${tag} signature verification failed (rc=${rc})" >&2
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Image mode: verify a container image signature (keyless)
# ---------------------------------------------------------------------------
verify_image() {
    local image="$1"
    echo "verify-image: ${image}" >&2

    local rc=0
    cosign verify \
        --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
        --certificate-identity-regexp=".*" \
        "$image" >&2 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
        echo "  OK: ${image} image signature verified" >&2
    else
        echo "  FAIL: ${image} image verification failed (rc=${rc})" >&2
        if [ "$SKIP_IF_MISSING" = true ]; then
            echo "  continuing despite failure (--skip-if-missing)" >&2
            return 0
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$MODE" in
    binary)
        verify_binary "$BINARY_NAME" "$BINARY_REPO" "$BINARY_VERSION"
        ;;
    image)
        verify_image "$IMAGE_REF"
        ;;
esac
