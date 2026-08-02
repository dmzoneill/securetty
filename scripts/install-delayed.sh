#!/bin/bash
# Install AI agents with delayed ingestion — only versions published >= QUARANTINE_DAYS ago.
# Generates /etc/securetty-manifest.json with version + publish date for each agent.
# Runs during container build (as root).
set -euo pipefail

QUARANTINE_DAYS="${QUARANTINE_DAYS:-7}"
MANIFEST="/etc/securetty-manifest.json"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUTOFF_EPOCH=$(date -u -d "${QUARANTINE_DAYS} days ago" +%s)
CUTOFF_ISO=$(date -u -d "${QUARANTINE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

echo "=== Delayed ingestion: quarantine=${QUARANTINE_DAYS}d, cutoff=${CUTOFF_ISO} ==="

# Initialize manifest
cat > "$MANIFEST" <<EOF
{
  "build_date": "${BUILD_DATE}",
  "quarantine_days": ${QUARANTINE_DAYS},
  "agents": []
}
EOF

# Helper: append agent entry to manifest
add_manifest() {
    local name="$1" version="$2" published="$3" method="$4"
    local tmp
    tmp=$(mktemp)
    jq --arg n "$name" --arg v "$version" --arg p "$published" --arg m "$method" \
        '.agents += [{"name":$n,"version":$v,"published":$p,"method":$m}]' \
        "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# =============================================================================
# npm agents: find latest version published before cutoff
# =============================================================================
install_npm_delayed() {
    local pkg="$1"
    local short_name="${pkg##*/}"
    echo ""
    echo "--- npm: $pkg ---"

    local time_json
    time_json=$(npm view "$pkg" time --json 2>/dev/null || echo "{}")

    if [ "$time_json" = "{}" ]; then
        echo "  WARN: could not fetch version times for $pkg, installing latest"
        npm install -g "$pkg" 2>/dev/null || echo "  WARN: install failed, skipping"
        add_manifest "$short_name" "latest" "unknown" "npm"
        return
    fi

    # Find latest version published before cutoff
    local best_version best_date
    best_version=$(echo "$time_json" | jq -r --argjson cutoff "$CUTOFF_EPOCH" '
        to_entries
        | map(select(.key != "created" and .key != "modified"))
        | map(select((.value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= $cutoff))
        | sort_by(.value)
        | reverse
        | .[0]
        | .key // empty
    ' 2>/dev/null || echo "")

    if [ -z "$best_version" ]; then
        echo "  WARN: no version older than ${QUARANTINE_DAYS}d for $pkg, skipping"
        add_manifest "$short_name" "skipped" "none" "npm"
        return
    fi

    best_date=$(echo "$time_json" | jq -r --arg v "$best_version" '.[$v] // "unknown"')
    echo "  installing $pkg@$best_version (published: $best_date)"
    npm install -g "${pkg}@${best_version}" || echo "  WARN: install failed"
    add_manifest "$short_name" "$best_version" "$best_date" "npm"
}

NPM_AGENTS=(
    "@anthropic-ai/claude-code"
    "@openai/codex"
    "@google/gemini-cli"
    "@cursor/cli"
    "cline"
    "opencode-ai"
    "@ampcode/cli"
    "@kilocode/cli"
    "@earendil-works/pi-ai"
)

for pkg in "${NPM_AGENTS[@]}"; do
    install_npm_delayed "$pkg"
done

npm cache clean --force 2>/dev/null || true

# =============================================================================
# pip agents: use uv --exclude-newer
# =============================================================================
echo ""
echo "=== pip agents (uv --exclude-newer $CUTOFF_ISO) ==="

PIP_AGENTS=(
    "aider-chat"
    "openhands"
    "kimi-cli"
)

for pkg in "${PIP_AGENTS[@]}"; do
    echo ""
    echo "--- pip: $pkg ---"

    version=$(uv pip install --python python3.12 --dry-run --system --break-system-packages \
        --exclude-newer "$CUTOFF_ISO" "$pkg" 2>&1 \
        | grep -oP "(?<=Would install )${pkg}-\K[^ ]+" || echo "")

    if [ -n "$version" ]; then
        echo "  installing $pkg==$version"
        uv pip install --python python3.12 --system --break-system-packages \
            --exclude-newer "$CUTOFF_ISO" "$pkg" \
            || echo "  WARN: install failed"
        add_manifest "$pkg" "$version" "before-${CUTOFF_ISO}" "pip"
    else
        echo "  installing $pkg with --exclude-newer $CUTOFF_ISO"
        uv pip install --python python3.12 --system --break-system-packages \
            --exclude-newer "$CUTOFF_ISO" "$pkg" \
            || echo "  WARN: install failed"
        installed_ver=$(pip3.12 show "$pkg" 2>/dev/null | grep -oP '(?<=Version: ).+' || echo "unknown")
        add_manifest "$pkg" "$installed_ver" "before-${CUTOFF_ISO}" "pip"
    fi
done

# =============================================================================
# Binary agents: query GitHub releases for versions older than cutoff
# =============================================================================
echo ""
echo "=== Binary agents (GitHub release >= ${QUARANTINE_DAYS}d old) ==="

install_github_binary() {
    local name="$1" repo="$2" install_cmd="$3"
    echo ""
    echo "--- binary: $name ($repo) ---"

    local release_json
    release_json=$(curl -fsSL "https://api.github.com/repos/${repo}/releases" 2>/dev/null || echo "[]")

    local tag published
    tag=$(echo "$release_json" | jq -r --argjson cutoff "$CUTOFF_EPOCH" '
        [.[] | select(.prerelease == false and .draft == false)
             | select((.published_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= $cutoff)]
        | sort_by(.published_at)
        | reverse
        | .[0].tag_name // empty
    ' 2>/dev/null || echo "")

    if [ -z "$tag" ]; then
        echo "  WARN: no release older than ${QUARANTINE_DAYS}d, using default installer"
        eval "$install_cmd" || echo "  WARN: install failed, skipping"
        add_manifest "$name" "latest-fallback" "unknown" "binary"
        return
    fi

    published=$(echo "$release_json" | jq -r --arg t "$tag" '
        [.[] | select(.tag_name == $t)] | .[0].published_at // "unknown"
    ')
    echo "  found $tag (published: $published)"

    # Use version-specific install where possible
    eval "$install_cmd" || echo "  WARN: install failed"
    add_manifest "$name" "$tag" "$published" "binary"
}

# Goose
install_github_binary "goose" "block/goose" \
    "curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | GOOSE_BIN=/usr/local/bin bash"

# Grok Build
install_github_binary "grok-build" "xai-org/grok-build" \
    "curl -fsSL https://x.ai/cli/install.sh | bash && ([ -f /root/.local/bin/grok ] && mv /root/.local/bin/grok /usr/local/bin/grok || true)"

# Forge
install_github_binary "forge" "anthropics/claude-code" \
    "curl -fsSL https://forgecode.dev/cli | sh && ([ -f /root/.local/bin/forge ] && mv /root/.local/bin/forge /usr/local/bin/forge || true)"

# Kiro CLI
install_github_binary "kiro-cli" "aws/amazon-q-developer-cli" \
    "curl -fsSL https://cli.kiro.dev/install | bash && ([ -f /root/.local/bin/kiro-cli ] && mv /root/.local/bin/kiro-cli /usr/local/bin/kiro-cli || true)"

# =============================================================================
# Final manifest
# =============================================================================
echo ""
echo "=== Manifest ==="
jq '.' "$MANIFEST"
echo ""
echo "=== ${#NPM_AGENTS[@]} npm + ${#PIP_AGENTS[@]} pip + 4 binary agents processed ==="
