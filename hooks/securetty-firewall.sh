#!/bin/bash
# OCI hook firewall — runs inside container namespace at createContainer stage.
# NET_ADMIN is available here but dropped before app starts.
# Container cannot modify these rules after startup.
# Whitelist: only internal subnet and established connections allowed.

set -euo pipefail

# Default deny everything
iptables -P INPUT DROP
iptables -P OUTPUT DROP
iptables -P FORWARD DROP

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS to gateway (host resolv.conf mounted, uses host DNS)
iptables -A OUTPUT -d 10.89.100.1 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 10.89.100.1 -p tcp --dport 53 -j ACCEPT

# Allow all traffic within internal subnet (services talk to each other)
iptables -A OUTPUT -d 10.89.100.0/24 -j ACCEPT
iptables -A INPUT -s 10.89.100.0/24 -j ACCEPT

# Block everything else — no direct internet access
# All outbound must go through egress-proxy via HTTP_PROXY env vars
