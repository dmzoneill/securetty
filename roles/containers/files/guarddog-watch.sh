#!/bin/bash
# GuardDog inotify watcher — scans new/modified packages in shared volumes
set -euo pipefail

SCAN_DIRS="/scan/usr-local /scan/pip-user /scan/npm-global /scan/npm-cache /scan/cargo /scan/go"
RESULTS_DIR="/results"
LOG="$RESULTS_DIR/guarddog.log"
DEBOUNCE=5

touch "$LOG" "$RESULTS_DIR/alerts.log" 2>/dev/null || true
echo "$(date -u +%FT%TZ) guarddog watcher starting" | tee "$LOG"
echo "Watching: $SCAN_DIRS" | tee -a "$LOG"

# Scan a directory for malicious packages
scan_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    # Scan Python site-packages dirs
    find "$dir" -maxdepth 4 -name 'METADATA' -path '*/dist-info/*' 2>/dev/null | while read -r meta; do
        local pkg_name
        pkg_name=$(grep -m1 '^Name:' "$meta" 2>/dev/null | cut -d' ' -f2- || true)
        [ -z "$pkg_name" ] && continue
        result=$(guarddog pypi scan "$pkg_name" 2>&1 || true)
        if echo "$result" | grep -qiE 'suspicious|malicious|warning'; then
            echo "$(date -u +%FT%TZ) ALERT: $pkg_name" | tee -a "$LOG"
            echo "$result" | tee -a "$LOG"
            echo "$result" >> "$RESULTS_DIR/alerts.log"
        fi
    done
    # Scan npm package.json dirs
    find "$dir" -maxdepth 4 -name 'package.json' ! -path '*/node_modules/.package-lock.json' 2>/dev/null | while read -r pjson; do
        local pkg_name
        pkg_name=$(python3.12 -c "import json,sys;d=json.load(open('$pjson'));print(d.get('name',''))" 2>/dev/null || true)
        [ -z "$pkg_name" ] && continue
        result=$(guarddog npm scan "$pkg_name" 2>&1 || true)
        if echo "$result" | grep -qiE 'suspicious|malicious|warning'; then
            echo "$(date -u +%FT%TZ) ALERT: $pkg_name" | tee -a "$LOG"
            echo "$result" | tee -a "$LOG"
            echo "$result" >> "$RESULTS_DIR/alerts.log"
        fi
    done
}

# Initial scan
for dir in $SCAN_DIRS; do
    echo "$(date -u +%FT%TZ) initial scan: $dir" | tee -a "$LOG"
    scan_dir "$dir"
done
echo "$(date -u +%FT%TZ) initial scan complete" | tee -a "$LOG"

# Watch for changes
last_scan=0
while read -r epoch filepath; do
    now=$(date +%s)
    if (( now - last_scan < DEBOUNCE )); then
        continue
    fi
    last_scan=$now

    case "$filepath" in
        *dist-info/METADATA|*/package.json|*/setup.py|*/pyproject.toml)
            echo "$(date -u +%FT%TZ) change: $filepath" | tee -a "$LOG"
            scan_dir "$(dirname "$(dirname "$filepath")")"
            ;;
    esac
done < <(inotifywait -m -r -e create,modify,moved_to \
    --format '%T %w%f' --timefmt '%s' \
    $SCAN_DIRS 2>/dev/null)
