#!/bin/bash
# Disconnect the container from the network after dependencies are installed.
# Prevents any exfiltration from malicious packages at runtime.
set -euo pipefail

CONTAINER="securetty"

if ! podman container exists "$CONTAINER" 2>/dev/null; then
    echo "Container '$CONTAINER' not running. Start it first."
    exit 1
fi

# Get the network name
NETWORK=$(podman inspect "$CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)

if [ -z "$NETWORK" ] || [ "$NETWORK" = "none" ]; then
    echo "[+] Container already has no network."
    exit 0
fi

podman network disconnect "$NETWORK" "$CONTAINER"
echo "[+] Network disconnected from container '$CONTAINER'."
echo "    Container is now air-gapped. No egress possible."
echo ""
echo "    To restore network (for more installs):"
echo "    podman network connect $NETWORK $CONTAINER"
