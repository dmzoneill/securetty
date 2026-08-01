#!/bin/bash
# One-time host setup for agent forwarding into securetty container.
# Run this on your host machine, not inside the container.
set -euo pipefail

echo "=== SSH Agent ==="
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    echo "[+] SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"
    ssh-add -l 2>/dev/null && echo "[+] Keys loaded in SSH agent" || echo "[!] No keys in SSH agent. Run: ssh-add"
else
    echo "[!] SSH agent not running. Start it:"
    echo "    eval \$(ssh-agent -s)"
    echo "    ssh-add ~/.ssh/id_ed25519"
fi

echo ""
echo "=== GPG Agent ==="
GPG_EXTRA=$(gpgconf --list-dir agent-extra-socket 2>/dev/null || echo "")
if [ -n "$GPG_EXTRA" ] && [ -S "$GPG_EXTRA" ]; then
    echo "[+] GPG extra socket: $GPG_EXTRA"
    echo "    Add to your shell profile:"
    echo "    export GPG_AGENT_EXTRA_SOCK=\"$GPG_EXTRA\""
else
    echo "[!] GPG agent extra socket not found."
    echo "    Start GPG agent: gpgconf --launch gpg-agent"
    echo "    Then re-run this script."
fi

echo ""
echo "=== Git Signing Setup ==="
SIGN_FORMAT=$(git config --global gpg.format 2>/dev/null || echo "not set")
echo "Current gpg.format: $SIGN_FORMAT"

echo ""
echo "--- Option A: SSH signing (recommended) ---"
echo "    git config --global gpg.format ssh"
echo "    git config --global user.signingkey ~/.ssh/id_ed25519.pub"
echo "    git config --global commit.gpgsign true"

echo ""
echo "--- Option B: GPG signing ---"
echo "    git config --global commit.gpgsign true"
echo "    # (uses default gpg.format=openpgp)"

echo ""
echo "=== .env file ==="
if [ ! -f .env ]; then
    cp .env.example .env 2>/dev/null || true
    echo "[!] Created .env from template. Fill in your API keys."
else
    echo "[+] .env exists"
fi

echo ""
echo "=== Shell exports needed ==="
echo "Add to ~/.bashrc or ~/.zshrc:"
echo ""
echo "  export GPG_AGENT_EXTRA_SOCK=\"$(gpgconf --list-dir agent-extra-socket 2>/dev/null || echo '/run/user/$(id -u)/gnupg/S.gpg-agent.extra')\""
echo ""
echo "Then: ./securetty build && ./securetty up && ./securetty shell"
