#!/bin/bash
# Container entrypoint — prints age banner to /dev/tty then exec's command.
# Banner only shows when TTY attached. Never touches stdout/stdin.

show_banner() {
    local manifest="/etc/securetty-manifest.json"
    local splash_script
    splash_script="$(dirname "$0")/securetty-splash.sh"
    [ -f "$splash_script" ] || splash_script="/usr/local/bin/securetty-splash.sh"
    [ -f "$splash_script" ] || return 0
    source "$splash_script"

    [ -f "$manifest" ] || { show_splash > /dev/tty; return 0; }

    local build_date quarantine_days agent_count now_epoch build_epoch age_days
    build_date=$(jq -r '.build_date' "$manifest" 2>/dev/null || echo "")
    [ -z "$build_date" ] && { show_splash > /dev/tty; return 0; }

    quarantine_days=$(jq -r '.quarantine_days' "$manifest" 2>/dev/null || echo "7")
    agent_count=$(jq '.agents | length' "$manifest" 2>/dev/null || echo "0")
    now_epoch=$(date -u +%s)
    build_epoch=$(date -u -d "$build_date" +%s 2>/dev/null || echo "$now_epoch")
    age_days=$(( (now_epoch - build_epoch) / 86400 ))

    local agent_name="${1:-unknown}"
    local agent_version
    agent_version=$(jq -r --arg name "$agent_name" '
        .agents[] | select(.name | ascii_downcase | contains($name | ascii_downcase)) | .version
    ' "$manifest" 2>/dev/null | head -1)
    [ -z "$agent_version" ] && agent_version="installed"

    local mode="personal (OmniRoute)"
    [ "${CLAUDE_CODE_USE_VERTEX:-}" = "1" ] && mode="work (Vertex AI)"
    [ "${SECURETTY_MODE:-}" = "read" ] && mode="${mode} [read-only]"

    local image_status="healthy"
    [ "$age_days" -ge 14 ] && image_status="STALE — rebuild recommended"

    local svc_up=0 svc_total=3
    timeout 1 bash -c "echo >/dev/tcp/securetty-omniroute/4000" 2>/dev/null && svc_up=$((svc_up + 1))
    timeout 1 bash -c "echo >/dev/tcp/securetty-headroom/8787" 2>/dev/null && svc_up=$((svc_up + 1))
    timeout 1 bash -c "echo >/dev/tcp/securetty-ollama/11434" 2>/dev/null && svc_up=$((svc_up + 1))

    show_splash \
        "Agent|${agent_name} ${agent_version}" \
        "Mode|${mode}" \
        "Image|built ${age_days}d ago (${image_status})" \
        "Agents|${agent_count} installed, quarantine ${quarantine_days}d" \
        "---|" \
        "Services|${svc_up}/${svc_total} reachable" \
        "Caps|ALL dropped" \
        "Rootfs|read-only" \
        "PID limit|4096" \
        > /dev/tty
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
