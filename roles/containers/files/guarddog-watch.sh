#!/bin/bash
# GuardDog package scanner — periodic scan of shared volumes
# inotify doesn't work cross-container on podman volumes, so we poll
set -euo pipefail

SCAN_DIRS="/scan/usr-local /scan/pip-user /scan/npm-global /scan/npm-cache /scan/cargo /scan/go"
RESULTS_DIR="/results"
LOG="$RESULTS_DIR/guarddog.log"
HASH_FILE="$RESULTS_DIR/.guarddog-hashes"
INTERVAL="${SCAN_INTERVAL:-300}"

touch "$LOG" "$RESULTS_DIR/alerts.log" "$HASH_FILE" 2>/dev/null || true
echo "$(date -u +%FT%TZ) guarddog scanner starting (interval: ${INTERVAL}s)" | tee "$LOG"

scan_all() {
    local new_hashes
    new_hashes=$(mktemp)

    for dir in $SCAN_DIRS; do
        [ -d "$dir" ] || continue

        # Python packages
        find "$dir" -maxdepth 4 -name 'METADATA' -path '*/dist-info/*' 2>/dev/null | while read -r meta; do
            local pkg_name pkg_ver
            pkg_name=$(grep -m1 '^Name:' "$meta" 2>/dev/null | cut -d' ' -f2- || true)
            pkg_ver=$(grep -m1 '^Version:' "$meta" 2>/dev/null | cut -d' ' -f2- || true)
            [ -z "$pkg_name" ] && continue
            echo "pypi:${pkg_name}:${pkg_ver}" >> "$new_hashes"

            # Only scan if new/changed
            if ! grep -qF "pypi:${pkg_name}:${pkg_ver}" "$HASH_FILE" 2>/dev/null; then
                echo "$(date -u +%FT%TZ) scanning: $pkg_name==$pkg_ver" | tee -a "$LOG"
                result=$(guarddog pypi scan "$pkg_name" 2>&1 || true)
                if echo "$result" | grep -qiE 'suspicious|malicious|warning'; then
                    echo "$(date -u +%FT%TZ) ALERT: $pkg_name==$pkg_ver" | tee -a "$LOG"
                    echo "$result" | tee -a "$LOG"
                    echo "$(date -u +%FT%TZ) $pkg_name==$pkg_ver" >> "$RESULTS_DIR/alerts.log"
                    echo "$result" >> "$RESULTS_DIR/alerts.log"
                fi
            fi
        done

        # npm packages
        find "$dir" -maxdepth 4 -name 'package.json' ! -path '*/node_modules/.package-lock.json' 2>/dev/null | while read -r pjson; do
            local pkg_name pkg_ver
            pkg_name=$(python3.12 -c "import json;d=json.load(open('$pjson'));print(d.get('name',''))" 2>/dev/null || true)
            pkg_ver=$(python3.12 -c "import json;d=json.load(open('$pjson'));print(d.get('version',''))" 2>/dev/null || true)
            [ -z "$pkg_name" ] && continue
            echo "npm:${pkg_name}:${pkg_ver}" >> "$new_hashes"

            if ! grep -qF "npm:${pkg_name}:${pkg_ver}" "$HASH_FILE" 2>/dev/null; then
                echo "$(date -u +%FT%TZ) scanning: $pkg_name@$pkg_ver" | tee -a "$LOG"
                result=$(guarddog npm scan "$pkg_name" 2>&1 || true)
                if echo "$result" | grep -qiE 'suspicious|malicious|warning'; then
                    echo "$(date -u +%FT%TZ) ALERT: $pkg_name@$pkg_ver" | tee -a "$LOG"
                    echo "$result" | tee -a "$LOG"
                    echo "$(date -u +%FT%TZ) $pkg_name@$pkg_ver" >> "$RESULTS_DIR/alerts.log"
                    echo "$result" >> "$RESULTS_DIR/alerts.log"
                fi
            fi
        done
    done

    mv "$new_hashes" "$HASH_FILE" 2>/dev/null || true
}

# Initial scan
echo "$(date -u +%FT%TZ) initial scan" | tee -a "$LOG"
scan_all
echo "$(date -u +%FT%TZ) initial scan complete" | tee -a "$LOG"

# Poll loop
while true; do
    sleep "$INTERVAL"
    echo "$(date -u +%FT%TZ) periodic scan" | tee -a "$LOG"
    scan_all
done
