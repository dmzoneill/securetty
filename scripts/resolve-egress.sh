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
    # Resolve the base domain
    resolved=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
    IPS+=" $resolved"

    # For wildcard-origin domains, also resolve common service subdomains
    # This catches CDN/cloud providers that use different IPs per subdomain
    for prefix in www api oauth2 accounts storage; do
        sub="${prefix}.${domain}"
        resolved=$(dig +short "$sub" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
        IPS+=" $resolved"
    done
done

UNIQUE=$(echo "$IPS" | tr ' ' '\n' | sort -u | grep -v '^$' || true)
COUNT=$(echo "$UNIQUE" | grep -c . || true)

echo "Resolved $COUNT IPs from ${#DOMAINS[@]} domains"

# Flush and repopulate the set
$NETNS_CMD nft flush set inet securetty_egress allowed_ipv4 2>/dev/null || true

for ip in $UNIQUE; do
    $NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ $ip }" 2>/dev/null || true
done

# Add known cloud provider CIDR ranges that wildcard domains resolve to
# Google Cloud / googleapis (Vertex AI, OAuth, storage)
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 142.250.0.0/15 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 142.251.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 172.217.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 172.253.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 216.58.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 74.125.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 173.194.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 64.233.160.0/19 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 66.102.0.0/20 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 108.177.0.0/17 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 209.85.128.0/17 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 35.190.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 35.191.0.0/16 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 3.0.0.0/8 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 52.0.0.0/8 }" 2>/dev/null || true
$NETNS_CMD nft add element inet securetty_egress allowed_ipv4 "{ 54.0.0.0/8 }" 2>/dev/null || true


FINAL=$($NETNS_CMD nft list set inet securetty_egress allowed_ipv4 2>/dev/null | grep -c 'elements' || echo "0")
echo "Loaded $COUNT IPs + CIDRs into securetty_egress allowed_ipv4 set"
