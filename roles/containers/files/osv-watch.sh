#!/bin/bash
# OSV-Scanner — periodic scan of shared volumes against known malware/vuln DB
# inotify doesn't work cross-container on podman volumes, so we poll
set -euo pipefail

SCAN_DIRS="/scan/usr-local /scan/pip-user /scan/npm-global /scan/npm-cache /scan/cargo /scan/go"
RESULTS_DIR="/results"
LOG="$RESULTS_DIR/osv-scanner.log"
HASH_FILE="$RESULTS_DIR/.osv-hashes"
INTERVAL="${SCAN_INTERVAL:-300}"

touch "$LOG" "$RESULTS_DIR/alerts.log" "$HASH_FILE" 2>/dev/null || true
echo "$(date -u +%FT%TZ) osv-scanner starting (interval: ${INTERVAL}s)" | tee "$LOG"

scan_all() {
    local new_hashes
    new_hashes=$(mktemp)

    for dir in $SCAN_DIRS; do
        [ -d "$dir" ] || continue

        # Python packages — check each against OSV DB
        find "$dir" -maxdepth 4 -name 'METADATA' -path '*/dist-info/*' 2>/dev/null | while read -r meta; do
            local pkg_name pkg_ver
            pkg_name=$(grep -m1 '^Name:' "$meta" 2>/dev/null | cut -d' ' -f2- || true)
            pkg_ver=$(grep -m1 '^Version:' "$meta" 2>/dev/null | cut -d' ' -f2- || true)
            [ -z "$pkg_name" ] || [ -z "$pkg_ver" ] && continue
            echo "pypi:${pkg_name}:${pkg_ver}" >> "$new_hashes"

            if ! grep -qF "pypi:${pkg_name}:${pkg_ver}" "$HASH_FILE" 2>/dev/null; then
                result=$(osv-scanner --package="$pkg_name" --version="$pkg_ver" --ecosystem=PyPI 2>&1 || true)
                if echo "$result" | grep -qiE 'vulnerability|malicious|MAL-|GHSA-'; then
                    echo "$(date -u +%FT%TZ) ALERT: $pkg_name==$pkg_ver" | tee -a "$LOG"
                    echo "$result" | tee -a "$LOG"
                    echo "$(date -u +%FT%TZ) $pkg_name==$pkg_ver" >> "$RESULTS_DIR/alerts.log"
                    echo "$result" >> "$RESULTS_DIR/alerts.log"
                fi
            fi
        done

        # Lockfiles
        find "$dir" -maxdepth 4 \( \
            -name 'package-lock.json' -o -name 'yarn.lock' -o \
            -name 'requirements.txt' -o -name 'Cargo.lock' -o -name 'go.sum' \
        \) 2>/dev/null | while read -r lockfile; do
            local hash
            hash=$(md5sum "$lockfile" 2>/dev/null | cut -d' ' -f1 || true)
            echo "lock:${lockfile}:${hash}" >> "$new_hashes"

            if ! grep -qF "lock:${lockfile}:${hash}" "$HASH_FILE" 2>/dev/null; then
                echo "$(date -u +%FT%TZ) scanning lockfile: $lockfile" | tee -a "$LOG"
                result=$(osv-scanner --lockfile="$lockfile" 2>&1 || true)
                if echo "$result" | grep -qiE 'vulnerability|malicious|MAL-|GHSA-'; then
                    echo "$(date -u +%FT%TZ) ALERT: $lockfile" | tee -a "$LOG"
                    echo "$result" | tee -a "$LOG"
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
