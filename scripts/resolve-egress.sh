#!/bin/bash
# Resolve securetty allowed domains to IPs and load into nftables set.
set -euo pipefail

NETNS_CMD="podman unshare nsenter --net=/run/user/1000/containers/networks/rootless-netns/rootless-netns"

DOMAINS=(
    "anthropic.com"
    "claude.ai"
    "claude.com"
    "claudeusercontent.com"
    "openai.com"
    "chatgpt.com"
    "oaistatic.com"
    "googleapis.com"
    "google.com"
    "aistudio.google.com"
    "cursor.sh"
    "cursor.com"
    "cursorapi.com"
    "cursor-cdn.com"
    "todesktop.com"
    "kiro.dev"
    "amazonaws.com"
    "x.ai"
    "sourcegraph.com"
    "ampcode.com"
    "cline.bot"
    "openrouter.ai"
    "moonshot.cn"
    "kimi.com"
    "moonshotai.com"
    "github.com"
    "githubusercontent.com"
    "github.io"
    "githubcopilot.com"
    "gitlab.com"
    "gitlab.cee.redhat.com"
    "npmjs.org"
    "npmjs.com"
    "yarnpkg.com"
    "pypi.org"
    "pythonhosted.org"
    "crates.io"
    "astral.sh"
    "quay.io"
    "docker.io"
    "docker.com"
    "registry.fedoraproject.org"
    "ghcr.io"
    "redhat.com"
    "cloud.google.com"
    "sigstore.dev"
    "ollama.com"
    "ollama.ai"
    "atlassian.net"
    "atlassian.com"
    "stripe.com"
)


IPS=""
for domain in "${DOMAINS[@]}"; do
    resolved=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
    IPS+=" $resolved"
done

UNIQUE=$(echo "$IPS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
COUNT=$(echo "$UNIQUE" | grep -c . || true)

echo "Resolved $COUNT IPs from ${#DOMAINS[@]} domains"

# Flush and repopulate the set
$NETNS_CMD nft flush set inet securetty_egress allowed_ipv4 2>/dev/null || true

for ip in $UNIQUE; do
    $NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ $ip }" 2>/dev/null || true
done

echo "Loaded $COUNT IPs into securetty_egress allowed_ipv4 set"
