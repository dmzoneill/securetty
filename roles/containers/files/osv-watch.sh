#!/bin/bash
# OSV-Scanner inotify watcher — checks packages against known vulnerability/malware DB
set -euo pipefail

SCAN_DIRS="/scan/usr-local /scan/pip-user /scan/npm-global /scan/npm-cache /scan/cargo /scan/go"
RESULTS_DIR="/results"
LOG="$RESULTS_DIR/osv-scanner.log"
DEBOUNCE=10

echo "$(date -u +%FT%TZ) osv-scanner watcher starting" | tee "$LOG"
echo "Watching: $SCAN_DIRS" | tee -a "$LOG"

# Scan lockfiles and package dirs
scan_packages() {
    local dir="$1"
    [ -d "$dir" ] || return 0

    # Find lockfiles
    find "$dir" -maxdepth 4 \( \
        -name 'package-lock.json' -o \
        -name 'yarn.lock' -o \
        -name 'pnpm-lock.yaml' -o \
        -name 'requirements.txt' -o \
        -name 'Pipfile.lock' -o \
        -name 'poetry.lock' -o \
        -name 'Cargo.lock' -o \
        -name 'go.sum' \
    \) 2>/dev/null | while read -r lockfile; do
        echo "$(date -u +%FT%TZ) scanning: $lockfile" | tee -a "$LOG"
        osv-scanner --lockfile="$lockfile" 2>&1 | tee -a "$LOG" || true
    done

    # Scan site-packages dirs for installed packages
    find "$dir" -maxdepth 3 -name 'METADATA' -path '*/dist-info/*' 2>/dev/null | head -50 | while read -r meta; do
        pkg_dir=$(dirname "$meta")
        pkg_name=$(grep -m1 '^Name:' "$meta" 2>/dev/null | cut -d' ' -f2 || true)
        pkg_ver=$(grep -m1 '^Version:' "$meta" 2>/dev/null | cut -d' ' -f2 || true)
        if [ -n "$pkg_name" ] && [ -n "$pkg_ver" ]; then
            result=$(osv-scanner --package="$pkg_name" --version="$pkg_ver" --ecosystem=PyPI 2>&1 || true)
            if echo "$result" | grep -qiE 'vulnerability|malicious|MAL-'; then
                echo "$(date -u +%FT%TZ) ALERT: $pkg_name==$pkg_ver" | tee -a "$LOG"
                echo "$result" | tee -a "$LOG"
                echo "$result" >> "$RESULTS_DIR/alerts.log"
            fi
        fi
    done
}

# Initial full scan
for dir in $SCAN_DIRS; do
    echo "$(date -u +%FT%TZ) initial scan: $dir" | tee -a "$LOG"
    scan_packages "$dir"
done
echo "$(date -u +%FT%TZ) initial scan complete" | tee -a "$LOG"

# Watch for changes
last_scan=0
inotifywait -m -r -e create,modify,moved_to \
    --format '%T %w%f' --timefmt '%s' \
    $SCAN_DIRS 2>/dev/null | while read -r epoch filepath; do

    now=$(date +%s)
    if (( now - last_scan < DEBOUNCE )); then
        continue
    fi
    last_scan=$now

    case "$filepath" in
        *dist-info/METADATA|*package.json|*requirements.txt|*Cargo.lock|*go.sum)
            echo "$(date -u +%FT%TZ) change detected: $filepath" | tee -a "$LOG"
            scan_packages "$(dirname "$filepath")"
            ;;
    esac
done
