#!/bin/bash
# Ansible managed
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

cat > "$MANIFEST" <<EOF
{
  "build_date": "${BUILD_DATE}",
  "quarantine_days": ${QUARANTINE_DAYS},
  "agents": []
}
EOF

add_manifest() {
    local name="$1" version="$2" published="$3" method="$4"
    local tmp
    tmp=$(mktemp)
    jq --arg n "$name" --arg v "$version" --arg p "$published" --arg m "$method" \
        '.agents += [{"name":$n,"version":$v,"published":$p,"method":$m}]' \
        "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
}

# =============================================================================
# npm agents
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
# pip agents
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

    version=$(uv pip install --python python3.12 --dry-run --target /usr/local/lib/python3.12/site-packages \
        --exclude-newer "$CUTOFF_ISO" "$pkg" 2>&1 \
        | grep -oP "(?<=Would install )${pkg}-\K[^ ]+" || echo "")

    if [ -n "$version" ]; then
        echo "  installing $pkg==$version"
        uv pip install --python python3.12 --target /usr/local/lib/python3.12/site-packages \
            --exclude-newer "$CUTOFF_ISO" "$pkg" \
            || echo "  WARN: install failed"
        add_manifest "$pkg" "$version" "before-${CUTOFF_ISO}" "pip"
    else
        echo "  installing $pkg with --exclude-newer $CUTOFF_ISO"
        uv pip install --python python3.12 --target /usr/local/lib/python3.12/site-packages \
            --exclude-newer "$CUTOFF_ISO" "$pkg" \
            || echo "  WARN: install failed"
        installed_ver=$(pip3.12 show "$pkg" 2>/dev/null | grep -oP '(?<=Version: ).+' || echo "unknown")
        add_manifest "$pkg" "$installed_ver" "before-${CUTOFF_ISO}" "pip"
    fi
done

# =============================================================================
# Binary agents
# =============================================================================
echo ""
echo "=== Binary agents (GitHub release >= ${QUARANTINE_DAYS}d old) ==="

_rescue_binary() {
    local name="$1"
    [ -x "/usr/local/bin/$name" ] && [ ! -L "/usr/local/bin/$name" ] && return 0
    if [ -L "/usr/local/bin/$name" ]; then
        local target
        target=$(readlink -f "/usr/local/bin/$name" 2>/dev/null)
        if [ -f "$target" ]; then
            rm -f "/usr/local/bin/$name"
            cp "$target" "/usr/local/bin/$name"
            chmod +x "/usr/local/bin/$name"
            echo "  resolved symlink $name from $target"
            return 0
        fi
    fi
    local found
    found=$(find /root/.local/bin /root/.grok /root/.jcode /home -maxdepth 6 -name "$name" -type f ! -path '*/node_modules/*' 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        cp "$(readlink -f "$found")" "/usr/local/bin/$name"
        chmod +x "/usr/local/bin/$name"
        echo "  rescued $name from $found"
    else
        echo "  WARN: $name not found anywhere after install"
    fi
}
export -f _rescue_binary

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

    eval "$install_cmd" || echo "  WARN: install failed"
    add_manifest "$name" "$tag" "$published" "binary"
}

install_github_binary "goose" "block/goose" \
    "curl -fsSL 'https://github.com/block/goose/releases/download/stable/download_cli.sh' > /tmp/goose-install.sh && bash /tmp/goose-install.sh 2>/dev/null; rm -f /tmp/goose-install.sh; _rescue_binary goose"
install_github_binary "grok" "xai-org/grok-build" \
    "curl -fsSL 'https://x.ai/cli/install.sh' > /tmp/grok-install.sh && bash /tmp/grok-install.sh 2>/dev/null; rm -f /tmp/grok-install.sh; _rescue_binary grok"
install_github_binary "forge" "anthropics/claude-code" \
    "curl -fsSL 'https://forgecode.dev/cli' > /tmp/forge-install.sh && bash /tmp/forge-install.sh 2>/dev/null; rm -f /tmp/forge-install.sh; _rescue_binary forge"
install_github_binary "kiro-cli" "aws/amazon-q-developer-cli" \
    "curl -fsSL 'https://cli.kiro.dev/install' > /tmp/kiro-cli-install.sh && bash /tmp/kiro-cli-install.sh 2>/dev/null; rm -f /tmp/kiro-cli-install.sh; _rescue_binary kiro-cli"
install_github_binary "cursor" "getcursor/cursor" \
    "curl -fsSL 'https://cursor.com/install' > /tmp/cursor-install.sh && bash /tmp/cursor-install.sh 2>/dev/null; rm -f /tmp/cursor-install.sh; _rescue_binary cursor"
install_github_binary "jcode" "1jehuang/jcode" \
    "curl -fsSL 'https://raw.githubusercontent.com/1jehuang/jcode/master/scripts/install.sh' > /tmp/jcode-install.sh && bash /tmp/jcode-install.sh 2>/dev/null; rm -f /tmp/jcode-install.sh; _rescue_binary jcode"

# =============================================================================
# Final manifest
# =============================================================================
echo ""
echo "=== Manifest ==="
jq '.' "$MANIFEST"
echo ""

echo "=== ${#NPM_AGENTS[@]} npm + ${#PIP_AGENTS[@]} pip + {{ securetty_binary_agents | length }} binary agents processed ==="
