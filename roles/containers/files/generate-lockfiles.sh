#!/bin/bash
# Generate lockfiles with integrity hashes for all agent packages.
# Run on host (or in container) to produce reproducible lockfiles.
# Usage: ./generate-lockfiles.sh [npm-pkg1 npm-pkg2 ...]
set -euo pipefail

LOCK_DIR="$(dirname "$0")/../lockfiles"
mkdir -p "$LOCK_DIR"

echo "=== Generating npm lockfile ==="
cd "$LOCK_DIR"

# Create package.json with all npm agents
cat > package.json <<'EOF'
{
  "name": "securetty-agents",
  "private": true,
  "dependencies": {}
}
EOF

# Add each agent passed as argument
for pkg in "$@"; do
    npm pkg set "dependencies.$pkg=*" 2>/dev/null || true
done

npm install --package-lock-only --ignore-scripts 2>/dev/null
echo "Generated package-lock.json with $(jq '.packages | length' package-lock.json) entries"

echo ""
echo "=== Generating pip requirements with hashes ==="
for pkg in aider-chat openhands kimi-cli; do
    echo "  hashing $pkg..."
    uv pip compile --python python3.12 --generate-hashes \
        <(echo "$pkg") >> "$LOCK_DIR/requirements-agents.txt" 2>/dev/null || \
        echo "  WARN: could not generate hashes for $pkg"
done
echo "Generated requirements-agents.txt"
