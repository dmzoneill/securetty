#!/bin/bash
# Resolve allowed domains to IPs and update nftables set
set -euo pipefail
nft flush set inet securetty_egress allowed_ipv4 2>/dev/null || true

IPS=""
for ip in $(dig +short "anthropic.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "claude.ai" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "claude.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "claudeusercontent.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "openai.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "chatgpt.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "oaistatic.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "googleapis.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "google.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "aistudio.google.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cursor.sh" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cursor.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cursorapi.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cursor-cdn.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "todesktop.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "kiro.dev" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "amazonaws.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "x.ai" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "sourcegraph.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "ampcode.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cline.bot" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "openrouter.ai" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "moonshot.cn" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "kimi.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "moonshotai.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "github.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "githubusercontent.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "github.io" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "githubcopilot.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "gitlab.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "gitlab.cee.redhat.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "npmjs.org" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "npmjs.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "yarnpkg.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "pypi.org" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "pythonhosted.org" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "crates.io" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "astral.sh" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "quay.io" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "docker.io" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "docker.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "registry.fedoraproject.org" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "ghcr.io" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "redhat.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "cloud.google.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "sigstore.dev" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "ollama.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "ollama.ai" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "atlassian.net" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "atlassian.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(dig +short "stripe.com" A 2>/dev/null); do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && IPS="$IPS $ip"
done
for ip in $(echo "$IPS" | tr ' ' '\n' | sort -u); do
    nft add element inet securetty_egress allowed_ipv4 "{ $ip }" 2>/dev/null || true
done
echo "Updated $(echo "$IPS" | tr ' ' '\n' | sort -u | wc -l) IPs in nftables set"
