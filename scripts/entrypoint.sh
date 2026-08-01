#!/bin/bash
# Container entrypoint — prints age banner to /dev/tty then exec's command.
# Banner only shows when TTY attached. Never touches stdout/stdin.

show_banner() {
    local manifest="/etc/securetty-manifest.json"
    [ -f "$manifest" ] || return 0

    local build_date quarantine_days agent_count now_epoch build_epoch age_seconds age_days
    build_date=$(jq -r '.build_date' "$manifest" 2>/dev/null || echo "")
    [ -z "$build_date" ] && return 0

    quarantine_days=$(jq -r '.quarantine_days' "$manifest" 2>/dev/null || echo "7")
    agent_count=$(jq '.agents | length' "$manifest" 2>/dev/null || echo "0")

    now_epoch=$(date -u +%s)
    build_epoch=$(date -u -d "$build_date" +%s 2>/dev/null || echo "$now_epoch")
    age_seconds=$((now_epoch - build_epoch))
    age_days=$((age_seconds / 86400))

    # Find oldest and newest agent by published date
    local oldest newest
    oldest=$(jq -r '
        .agents
        | map(select(.published != "unknown" and .published != "none" and (.published | startswith("skipped") | not)))
        | sort_by(.published)
        | .[0]
        | "\(.name) \(.version)"
    ' "$manifest" 2>/dev/null || echo "")
    newest=$(jq -r '
        .agents
        | map(select(.published != "unknown" and .published != "none" and (.published | startswith("skipped") | not)))
        | sort_by(.published)
        | reverse
        | .[0]
        | "\(.name) \(.version)"
    ' "$manifest" 2>/dev/null || echo "")

    # Banner
    local stale_warn=""
    if [ "$age_days" -ge 14 ]; then
        stale_warn=" | \033[1;31mSTALE (${age_days}d) -- rebuild recommended\033[0m"
    fi

    echo -e "\033[0;36msecuretty\033[0m | built ${age_days}d ago | ${agent_count} agents | quarantine: ${quarantine_days}d${stale_warn}" > /dev/tty
    [ -n "$oldest" ] && echo -e "\033[0;36msecuretty\033[0m | oldest: ${oldest} | newest: ${newest}" > /dev/tty
}

# Merge SSH configs: host config (mounted ro) + securetty proxy routing
if [ -f "$HOME/.ssh/config.securetty" ]; then
    # Prepend securetty proxy config so it takes priority
    cat "$HOME/.ssh/config.securetty" > /tmp/ssh_config 2>/dev/null
    [ -f "$HOME/.ssh/config" ] && cat "$HOME/.ssh/config" >> /tmp/ssh_config 2>/dev/null
    cp /tmp/ssh_config "$HOME/.ssh/config" 2>/dev/null || true
    rm -f /tmp/ssh_config
    chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
fi

# Only show banner when TTY attached
if [ -t 0 ] && [ -e /dev/tty ]; then
    show_banner 2>/dev/null || true
fi

exec "$@"
