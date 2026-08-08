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

    local C="\033[0;36m"
    local G="\033[0;32m"
    local D="\033[2m"
    local R="\033[0m"

    echo -e "" > /dev/tty
    echo -e "${C}  ___  ___  ___ _   _ _ __ ___| |_| |_ _   _ ${R}" > /dev/tty
    echo -e "${C} / __|/ _ \\/ __| | | | '__/ _ \\ __| __| | | |${R}" > /dev/tty
    echo -e "${C} \\__ \\  __/ (__| |_| | | |  __/ |_| |_| |_| |${R}" > /dev/tty
    echo -e "${C} |___/\\___|\\___|\\___|_|  \\___|\\__|\\__|\\__, |${R}" > /dev/tty
    echo -e "${C}                                      |___/ ${R}" > /dev/tty
    echo -e "${D} built ${age_days}d ago | ${agent_count} agents | quarantine: ${quarantine_days}d${stale_warn}${R}" > /dev/tty
    [ -n "$oldest" ] && echo -e "${D} oldest: ${oldest} | newest: ${newest}${R}" > /dev/tty
    echo -e "" > /dev/tty
}

# Sync /usr/local volume from image on version mismatch
_sync_usr_local() {
    local manifest="/etc/securetty-manifest.json"
    local marker="/usr/local/.securetty-build-date"
    [ -f "$manifest" ] || return 0

    local image_date
    image_date=$(jq -r '.build_date' "$manifest" 2>/dev/null || echo "")
    [ -z "$image_date" ] && return 0

    local volume_date=""
    [ -f "$marker" ] && volume_date=$(cat "$marker" 2>/dev/null)

    if [ "$image_date" != "$volume_date" ]; then
        if [ -t 0 ] && [ -e /dev/tty ]; then
            echo -e "\033[0;33msecuretty\033[0m | syncing agents to volume..." > /dev/tty
        fi
        cp -a /usr/local.image/* /usr/local/ 2>/dev/null || true
        echo "$image_date" > "$marker"
    fi
}

_setup_ai_guardian() {
    command -v ai-guardian >/dev/null 2>&1 || return 0
    [ -f "$HOME/.config/ai-guardian/ai-guardian.json" ] && return 0
    bash /usr/bin/ai-guardian-setup.sh 2>/dev/null || true
}

_sync_usr_local 2>/dev/null || true
_setup_ai_guardian 2>/dev/null || true

# Only show banner when TTY attached
if [ -t 0 ] && [ -e /dev/tty ]; then
    show_banner 2>/dev/null || true
fi

exec "$@"
