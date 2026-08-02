#!/bin/bash
# Scan AI conversation history files for leaked secrets.
# Run BEFORE migration to identify what needs cleaning.
# Outputs: file, line number, pattern type, REDACTED preview. Never full secrets.
set -euo pipefail

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

TOTAL_HITS=0
REPORT_FILE="${1:-/tmp/securetty-secret-scan-$(date +%Y%m%d-%H%M%S).txt}"

header() { echo -e "\n${CYN}=== $1 ===${RST}"; }
warn()   { echo -e "${RED}  [!] $1${RST}"; }
info()   { echo -e "${GRN}  [+] $1${RST}"; }

# Redact: show first 8 chars + ***
redact() {
    echo "$1" | sed -E 's/^(.{8}).*/\1***/'
}

# Scan a single file for secret patterns
scan_file() {
    local file="$1"
    [ -f "$file" ] || return 0

    local hits=0
    local patterns=(
        "sk-ant-[a-zA-Z0-9_-]{20,}:Anthropic API key:CRITICAL"
        "sk-[a-zA-Z0-9]{20,}:OpenAI API key:CRITICAL"
        "AKIA[0-9A-Z]{16}:AWS access key:CRITICAL"
        "ghp_[a-zA-Z0-9]{36}:GitHub PAT:CRITICAL"
        "gho_[a-zA-Z0-9]{36}:GitHub OAuth:CRITICAL"
        "github_pat_[a-zA-Z0-9_]{20,}:GitHub fine-grained PAT:CRITICAL"
        "glpat-[a-zA-Z0-9_-]{20,}:GitLab PAT:CRITICAL"
        "xoxb-[a-zA-Z0-9-]+:Slack bot token:CRITICAL"
        "xoxp-[a-zA-Z0-9-]+:Slack user token:CRITICAL"
        "xoxc-[a-zA-Z0-9-]+:Slack client token:CRITICAL"
        "AIza[0-9A-Za-z_-]{35}:Google API key:HIGH"
        "Bearer [a-zA-Z0-9._-]{20,}:Bearer token:HIGH"
    )

    for entry in "${patterns[@]}"; do
        IFS=':' read -r pattern desc severity <<< "$entry"

        while IFS=: read -r line_num matched; do
            [ -z "$matched" ] && continue
            local preview
            preview=$(redact "$matched")
            echo -e "  ${RED}[$severity]${RST} ${desc} at ${file}:${line_num} — ${preview}"
            echo "[$severity] $desc at $file:$line_num — $preview" >> "$REPORT_FILE"
            hits=$((hits + 1))
        done < <(grep -noPE "$pattern" "$file" 2>/dev/null | head -50 || true)
    done

    # Password assignments (lower confidence)
    local pw_count
    pw_count=$(grep -ciP 'password\s*[:=]\s*['"'"'"][^'"'"'"]{4,}' "$file" 2>/dev/null | head -1 || echo 0)
    pw_count="${pw_count//[^0-9]/}"
    pw_count="${pw_count:-0}"
    if [ "$pw_count" -gt 0 ]; then
        echo -e "  ${YEL}[MEDIUM]${RST} $pw_count password assignment(s) in $file"
        echo "[MEDIUM] $pw_count password assignment(s) in $file" >> "$REPORT_FILE"
        hits=$((hits + pw_count))
    fi

    TOTAL_HITS=$((TOTAL_HITS + hits))
    return 0
}

# Scan a directory recursively
scan_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' file; do
        scan_file "$file"
    done < <(find "$dir" -type f \( -name '*.jsonl' -o -name '*.json' -o -name '*.md' -o -name '*.txt' -o -name '*.log' \) -print0 2>/dev/null)
}

# ============================================================
echo -e "${CYN}securetty secret scanner${RST}"
echo "Report: $REPORT_FILE"
echo "" > "$REPORT_FILE"
echo "securetty secret scan — $(date)" >> "$REPORT_FILE"
echo "========================================" >> "$REPORT_FILE"

# AI conversation history
header "Claude Code history"
scan_file "$HOME/.claude/history.jsonl"
scan_dir "$HOME/.claude/sessions"

header "Codex history"
scan_file "$HOME/.codex/history.jsonl"
scan_dir "$HOME/.codex/sessions"

header "Gemini history"
scan_dir "$HOME/.gemini/history"
scan_dir "$HOME/.gemini/sessions"

header "Cline history"
scan_dir "$HOME/.cline/data/tasks"

header "OpenHands conversations"
scan_dir "$HOME/.openhands/conversations"

header "Goose sessions"
scan_dir "$HOME/.config/goose/sessions"

header "Kiro sessions"
scan_dir "$HOME/.kiro/sessions"

header "OpenCode sessions"
scan_dir "$HOME/.local/share/opencode"

# .env files in source repos
header "Committed .env files in ~/src (HIGH RISK)"
while IFS= read -r envfile; do
    [ -z "$envfile" ] && continue
    dir=$(dirname "$envfile")
    base=$(basename "$envfile")
    if (cd "$dir" && git ls-files --error-unmatch "$base" &>/dev/null); then
        warn "COMMITTED TO GIT: $envfile"
        echo "[CRITICAL] .env committed to git: $envfile" >> "$REPORT_FILE"
        scan_file "$envfile"
    fi
done < <(find "$HOME/src" -maxdepth 3 -name '.env' -not -path '*/node_modules/*' 2>/dev/null)

header "Uncommitted .env files in ~/src"
while IFS= read -r envfile; do
    [ -z "$envfile" ] && continue
    dir=$(dirname "$envfile")
    base=$(basename "$envfile")
    if ! (cd "$dir" && git ls-files --error-unmatch "$base" &>/dev/null 2>&1); then
        info "Not in git (OK): $envfile"
        scan_file "$envfile"
    fi
done < <(find "$HOME/src" -maxdepth 3 -name '.env' -not -path '*/node_modules/*' 2>/dev/null)

# AI agent config files that might contain secrets
header "AI agent config files"
for f in \
    "$HOME/.claude/.credentials.json" \
    "$HOME/.codex/auth.json" \
    "$HOME/.codex/config.toml" \
    "$HOME/.gemini/google_accounts.json" \
    "$HOME/.config/cursor/auth.json" \
    "$HOME/.omniroute/.env" \
    "$HOME/.headroom/subscription_state.json" \
    "$HOME/.config/goose/config.yaml" \
    "$HOME/.grok/config.toml" \
    "$HOME/.cline/data/secrets.json" \
    "$HOME/.openhands/settings.json"; do
    if [ -f "$f" ]; then
        warn "Contains secrets: $f"
        echo "[INFO] Secret-bearing config: $f" >> "$REPORT_FILE"
    fi
done

# Summary
header "Summary"
echo ""
if [ "$TOTAL_HITS" -eq 0 ]; then
    info "No leaked secrets found in history files."
else
    warn "$TOTAL_HITS potential secret(s) found across history files."
    echo ""
    echo "  Review: $REPORT_FILE"
    echo ""
    echo "  Actions:"
    echo "    1. Rotate any leaked keys immediately"
    echo "    2. Clean committed .env files from git history:"
    echo "       git filter-repo --path .env --invert-paths"
    echo "    3. Add .env to .gitignore in affected repos"
fi
echo ""
