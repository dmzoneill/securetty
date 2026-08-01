#!/bin/bash
set -euo pipefail

QUARANTINE_DAYS="${QUARANTINE_DAYS:-7}"
CUTOFF_EPOCH=$(date -u -d "${QUARANTINE_DAYS} days ago" +%s)
PKG="omniroute"

echo "=== Installing $PKG (>= ${QUARANTINE_DAYS}d old) ==="

time_json=$(npm view "$PKG" time --json 2>/dev/null || echo "{}")
best_version=$(echo "$time_json" | jq -r --argjson cutoff "$CUTOFF_EPOCH" '
    to_entries
    | map(select(.key != "created" and .key != "modified"))
    | map(select((.value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= $cutoff))
    | sort_by(.value) | reverse | .[0].key // empty
' 2>/dev/null || echo "")

if [ -n "$best_version" ]; then
    echo "Installing $PKG@$best_version"
    npm install -g "${PKG}@${best_version}"
else
    echo "No version older than ${QUARANTINE_DAYS}d, installing latest"
    npm install -g "$PKG"
fi

npm cache clean --force 2>/dev/null || true
