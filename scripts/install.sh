#!/bin/bash
# Install dependencies inside the container with network access.
# After install completes, run lockdown-network.sh to restrict egress.
set -euo pipefail

cd /workspace

echo "=== Installing dependencies ==="

# Python: create venv if missing, install from lockfile
if [ -f "requirements.txt" ]; then
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv
    fi
    source .venv/bin/activate
    pip install --require-hashes -r requirements.txt 2>/dev/null \
        || pip install -r requirements.txt
    echo "[+] Python dependencies installed"
fi

if [ -f "pyproject.toml" ] && command -v uv &>/dev/null; then
    if [ ! -d ".venv" ]; then
        python3 -m venv .venv
    fi
    source .venv/bin/activate
    uv sync
    echo "[+] Python dependencies installed via uv"
fi

# Node: install from lockfile, no scripts
if [ -f "package-lock.json" ]; then
    npm ci --ignore-scripts
    echo "[+] Node dependencies installed (scripts disabled)"
elif [ -f "package.json" ]; then
    npm install --ignore-scripts
    echo "[+] Node dependencies installed (scripts disabled)"
fi

echo ""
echo "=== Install complete ==="
echo "To lock down network, exit and run: ./scripts/lockdown-network.sh"
