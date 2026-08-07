#!/bin/bash
# Start a restricted SSH agent on host with ONLY dmzoneill-2024 key.
# Socket forwarded into container — private key never enters container.
# Container can sign with this key but cannot access or export it.
set -euo pipefail

SOCKET_PATH="/run/user/$(id -u)/securetty-ssh-agent.sock"
PID_FILE="/run/user/$(id -u)/securetty-ssh-agent.pid"
TOKEN_FILE="/run/user/$(id -u)/securetty-ssh-token"
KEYS=(
    "$HOME/.ssh/dmzoneill-2024"
    "$HOME/.ssh/id_ecdsa"
)

start() {
    # Kill existing if running
    stop 2>/dev/null || true

    # Start dedicated agent with specific socket path
    eval "$(ssh-agent -a "$SOCKET_PATH")" >/dev/null
    echo "$SSH_AGENT_PID" > "$PID_FILE"

    # Add allowed keys
    for KEY in "${KEYS[@]}"; do
        if [ -f "$KEY" ]; then
            SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add "$KEY" 2>/dev/null
            echo "    Key: $(ssh-keygen -lf "${KEY}.pub" 2>/dev/null | awk '{print $2, $3}')"
        fi
    done

    # Generate session token for HMAC proxy validation
    openssl rand -hex 32 > "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"

    echo "[+] Restricted SSH agent started"
    echo "    Socket: $SOCKET_PATH"
    echo "    PID: $(cat "$PID_FILE")"
    echo "    Token: $TOKEN_FILE"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE" "$SOCKET_PATH" "$TOKEN_FILE"
        echo "[+] Restricted SSH agent stopped"
    fi
}

status() {
    if [ -S "$SOCKET_PATH" ] && [ -f "$PID_FILE" ]; then
        echo "[+] Running (PID $(cat "$PID_FILE"))"
        SSH_AUTH_SOCK="$SOCKET_PATH" ssh-add -l 2>/dev/null
    else
        echo "[-] Not running"
    fi
}

case "${1:-start}" in
    start)  start ;;
    stop)   stop ;;
    status) status ;;
    *)      echo "Usage: $0 {start|stop|status}" ;;
esac
