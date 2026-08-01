#!/bin/bash
# Migrate AI agents off host machine into securetty container.
# Interactive — confirms each category before removal.
# Run AFTER securetty container is verified working.
set -euo pipefail

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

header() { echo -e "\n${CYN}${BLD}=== $1 ===${RST}"; }
warn()   { echo -e "${RED}  [!] $1${RST}"; }
info()   { echo -e "${GRN}  [+] $1${RST}"; }
skip()   { echo -e "${YEL}  [-] Skipped${RST}"; }

confirm() {
    local prompt="$1"
    echo -en "\n${BLD}$prompt [y/N]: ${RST}"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

echo -e "${CYN}${BLD}securetty host migration${RST}"
echo "This will remove AI agents from the host machine."
echo "Run this AFTER verifying securetty container works."
echo ""

# Pre-flight: check container exists
if ! podman container exists securetty 2>/dev/null; then
    warn "securetty container not running."
    warn "Start it first: ./securetty up && ./securetty shell"
    warn "Verify agents work inside, then re-run this script."
    exit 1
fi

# ============================================================
header "Step 1: Run secret scanner first"
if confirm "Run secret scanner before migration?"; then
    bash "$(dirname "$0")/scan-secrets.sh" || true
    echo ""
    if ! confirm "Continue with migration after reviewing scan results?"; then
        echo "Aborted. Fix leaked secrets first."
        exit 0
    fi
fi

# ============================================================
header "Step 2: Backup config directories"
BACKUP_FILE="$HOME/securetty-host-backup-$(date +%Y%m%d).tar.gz"
echo "  Backup target: $BACKUP_FILE"

BACKUP_DIRS=()
for d in \
    "$HOME/.claude" \
    "$HOME/.codex" \
    "$HOME/.gemini" \
    "$HOME/.cursor" \
    "$HOME/.config/cursor" \
    "$HOME/.kiro" \
    "$HOME/.omniroute" \
    "$HOME/.headroom" \
    "$HOME/.config/opencode" \
    "$HOME/.config/goose" \
    "$HOME/.grok" \
    "$HOME/.forge" \
    "$HOME/.cline" \
    "$HOME/.openhands" \
    "$HOME/.amp" \
    "$HOME/.config/kilo"; do
    [ -d "$d" ] && BACKUP_DIRS+=("$d") && echo "  Will backup: $d"
done

if confirm "Create backup archive?"; then
    tar czf "$BACKUP_FILE" "${BACKUP_DIRS[@]}" 2>/dev/null || true
    info "Backup saved: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
else
    skip
fi

# ============================================================
header "Step 3: Remove npm global packages"
NPM_PACKAGES=(
    "@anthropic-ai/claude-code"
    "@openai/codex"
    "@google/gemini-cli"
    "@cloudcli-ai/cloudcli"
    "deepseek-cli"
    "task-master-ai"
    "omniroute"
)

echo "  Packages to remove:"
for pkg in "${NPM_PACKAGES[@]}"; do
    if npm list -g "$pkg" &>/dev/null; then
        echo "    $pkg (installed)"
    else
        echo "    $pkg (not found)"
    fi
done

if confirm "Uninstall npm packages?"; then
    for pkg in "${NPM_PACKAGES[@]}"; do
        npm uninstall -g "$pkg" 2>/dev/null && info "Removed $pkg" || true
    done
else
    skip
fi

# ============================================================
header "Step 4: Remove pip packages"
PIP_PACKAGES=("headroom-ai" "aider-chat" "openhands")

echo "  Packages to remove:"
for pkg in "${PIP_PACKAGES[@]}"; do
    if pip show "$pkg" &>/dev/null; then
        echo "    $pkg (installed)"
    else
        echo "    $pkg (not found)"
    fi
done

if confirm "Uninstall pip packages?"; then
    for pkg in "${PIP_PACKAGES[@]}"; do
        pip uninstall -y "$pkg" 2>/dev/null && info "Removed $pkg" || true
    done
else
    skip
fi

# ============================================================
header "Step 5: Remove standalone binaries"
BINARIES=(
    "$HOME/bin/cursor"
    "$HOME/.local/bin/kiro-cli"
    "$HOME/.local/bin/kiro-cli-chat"
    "$HOME/.local/bin/kiro-cli-term"
    "$HOME/.local/bin/opencode-bash-wrapper"
    "$HOME/.local/bin/opencode-launcher"
    "$HOME/.local/bin/opencode-web"
    "$HOME/.local/bin/claude-auto-format.sh"
    "$HOME/.local/bin/claude-post-commit-hook.sh"
    "$HOME/.local/bin/cursor-agent"
    "$HOME/.local/bin/cursor-pre-commit-hook.sh"
    "$HOME/.local/bin/headroom"
)

echo "  Binaries to remove:"
for bin in "${BINARIES[@]}"; do
    [ -f "$bin" ] && echo "    $bin" || true
done

if confirm "Remove standalone binaries?"; then
    for bin in "${BINARIES[@]}"; do
        [ -f "$bin" ] && rm -f "$bin" && info "Removed $bin" || true
    done
else
    skip
fi

# ============================================================
header "Step 6: System packages (requires sudo)"
CURSOR_RPM=$(rpm -qa 2>/dev/null | grep -i cursor | head -1 || echo "")
if [ -n "$CURSOR_RPM" ]; then
    echo "  Found: $CURSOR_RPM"
    if confirm "Remove system cursor package (requires sudo)?"; then
        sudo dnf remove -y "$CURSOR_RPM" && info "Removed $CURSOR_RPM" || warn "Failed"
    else
        skip
    fi
else
    info "No system cursor package found"
fi

# ============================================================
header "Step 7: Systemd services"

# User services
if systemctl --user is-active cloudcli.service &>/dev/null; then
    echo "  Found: cloudcli.service (running on port 3001)"
    echo "  Replacement: securetty-cloudcli container"
    if confirm "Stop and disable cloudcli.service?"; then
        systemctl --user stop cloudcli.service
        systemctl --user disable cloudcli.service
        rm -f "$HOME/.config/systemd/user/cloudcli.service"
        systemctl --user daemon-reload
        info "cloudcli.service removed"
    else
        skip
    fi
else
    info "cloudcli.service not running"
fi

# System services (ollama)
if systemctl is-active ollama.service &>/dev/null; then
    echo "  Found: ollama.service (running on port 11434)"
    echo "  Replacement: securetty-ollama container"
    if confirm "Stop and disable ollama.service (requires sudo)?"; then
        sudo systemctl stop ollama.service
        sudo systemctl disable ollama.service
        info "ollama.service disabled"
        echo "  Note: ollama binary left in place (/usr/local/bin/ollama)"
        echo "  Remove manually if desired: sudo rm /usr/local/bin/ollama"
    else
        skip
    fi
else
    info "ollama.service not running"
fi

# ============================================================
header "Step 8: Shell profile cleanup"
echo "  Checking for AI-related env vars in shell profile..."

AI_VARS="CLAUDE|ANTHROPIC|CODEX|GEMINI|OPENAI|CURSOR|XAI|GROK|OMNIROUTE|HEADROOM|AI_AGENT|CLAUDECODE"
PROFILE_FILES=("$HOME/.bashrc")
[ -d "$HOME/.bashrc.d" ] && PROFILE_FILES+=("$HOME/.bashrc.d/"*)

for pf in "${PROFILE_FILES[@]}"; do
    [ -f "$pf" ] || continue
    matches=$(grep -cE "$AI_VARS" "$pf" 2>/dev/null || echo 0)
    if [ "$matches" -gt 0 ]; then
        warn "$pf has $matches AI-related lines"
        grep -nE "$AI_VARS" "$pf" 2>/dev/null | head -10 | sed 's/^/    /'
    fi
done

echo ""
echo "  Manual action required: review and remove AI env vars from shell profile."
echo "  Keep SSH_AUTH_SOCK and GPG_AGENT setup (needed for container forwarding)."

# ============================================================
header "Step 9: Verification"
echo ""
echo "  Checking for remaining AI agents in PATH..."

AGENTS_FOUND=0
for cmd in claude codex gemini cursor cline opencode amp kilo aider openhands goose grok forge kiro-cli omniroute headroom; do
    loc=$(which "$cmd" 2>/dev/null || echo "")
    if [ -n "$loc" ]; then
        warn "Still found: $cmd at $loc"
        AGENTS_FOUND=$((AGENTS_FOUND + 1))
    fi
done

echo ""
if [ "$AGENTS_FOUND" -eq 0 ]; then
    info "Host is clean. All AI agents removed."
    echo ""
    echo "  Next steps:"
    echo "    1. Open new shell to pick up profile changes"
    echo "    2. ./securetty shell — work from inside container"
    echo "    3. Optionally remove config dirs after confirming backup:"
    echo "       rm -rf ~/.claude ~/.codex ~/.gemini ~/.cursor ~/.kiro"
    echo "       rm -rf ~/.omniroute ~/.headroom ~/.config/opencode"
    echo "       rm -rf ~/.config/goose ~/.grok ~/.forge ~/.cline ~/.openhands"
else
    warn "$AGENTS_FOUND agent(s) still found on host."
    echo "  May need to restart shell or check PATH."
fi
echo ""
