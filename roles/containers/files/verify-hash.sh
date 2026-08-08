#!/bin/bash
# Verify SHA256 hash of a downloaded binary.
# Called after binary agent download to ensure integrity before installation.
# Outputs verification detail to stderr; only exit code matters to callers.
#   Exit 0 = hash matches (PASS)
#   Exit 1 = hash mismatch or error (FAIL)
#
# Usage:
#   verify-hash.sh <file> <expected-sha256>
#
# Example:
#   verify-hash.sh /tmp/goose-linux-amd64 \
#     e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
set -euo pipefail

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage:
  verify-hash.sh <file> <expected-sha256>

Arguments:
  file              Path to the downloaded binary to verify
  expected-sha256   Expected SHA256 hex digest (64 lowercase hex characters)

Exit codes:
  0  Hash matches -- file integrity verified
  1  Hash mismatch or error -- file may be corrupt or tampered
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------
[ $# -eq 2 ] || { echo "ERROR: expected 2 arguments, got $#" >&2; usage; }

FILE="$1"
EXPECTED="$2"

if [ ! -f "$FILE" ]; then
    echo "FAIL: file not found: $FILE" >&2
    exit 1
fi

if [ ! -r "$FILE" ]; then
    echo "FAIL: file not readable: $FILE" >&2
    exit 1
fi

# Validate expected hash format (64 hex characters)
if ! echo "$EXPECTED" | grep -qE '^[0-9a-fA-F]{64}$'; then
    echo "FAIL: expected-sha256 is not a valid SHA256 hex digest: $EXPECTED" >&2
    exit 1
fi

# Normalize to lowercase for comparison
EXPECTED=$(echo "$EXPECTED" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Compute and compare
# ---------------------------------------------------------------------------
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "FAIL: sha256sum not installed" >&2
    exit 1
fi

ACTUAL=$(sha256sum "$FILE" | cut -d' ' -f1)

if [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "PASS: $FILE sha256=$ACTUAL" >&2
    exit 0
else
    echo "FAIL: $FILE hash mismatch" >&2
    echo "  expected: $EXPECTED" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
fi
