#!/bin/bash
# Host-side URL relay daemon.
# Listens on a unix socket for URL requests from the container.
# Validates URLs (https/http only) and opens them on the host desktop.
# Started by: ./securetty up
# Stopped by: ./securetty down
set -euo pipefail

SOCKET_PATH="/run/user/$(id -u)/securetty-open.sock"
PID_FILE="/run/user/$(id -u)/securetty-open.pid"

start() {
    # Clean up stale socket
    rm -f "$SOCKET_PATH"

    echo "[+] URL relay listening on $SOCKET_PATH"
    echo "$$" > "$PID_FILE"

    # Listen loop — socat creates unix socket, accepts connections
    while true; do
        url=$(socat -u UNIX-LISTEN:"$SOCKET_PATH",fork,mode=0666 - 2>/dev/null | head -1)

        # Skip empty
        [ -z "${url:-}" ] && continue

        # Strip whitespace/newlines
        url=$(echo "$url" | tr -d '\r\n' | xargs)

        # Validate: only http:// and https:// URLs allowed
        if echo "$url" | grep -qE '^https?://[a-zA-Z0-9]'; then
            echo "[open-relay] Opening: $url"
            xdg-open "$url" 2>/dev/null &
        else
            echo "[open-relay] BLOCKED (not http/https): $url" >&2
        fi
    done
}

stop() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE" "$SOCKET_PATH"
        echo "[+] URL relay stopped"
    fi
}

case "${1:-start}" in
    start) start ;;
    stop)  stop ;;
    *)     echo "Usage: $0 {start|stop}" ;;
esac
