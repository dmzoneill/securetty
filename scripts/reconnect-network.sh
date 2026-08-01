#!/bin/bash
# Reconnect network to install more dependencies.
set -euo pipefail

CONTAINER="securetty"
NETWORK="securetty_restricted"

if ! podman container exists "$CONTAINER" 2>/dev/null; then
    echo "Container '$CONTAINER' not running."
    exit 1
fi

podman network connect "$NETWORK" "$CONTAINER"
echo "[+] Network restored. Run install.sh inside container, then lockdown again."
