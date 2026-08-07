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

# Initial full scan
for dir in $SCAN_DIRS; do
    [ -d "$dir" ] || continue
    echo "$(date -u +%FT%TZ) initial scan: $dir" | tee -a "$LOG"
    find "$dir" -name '*.py' -o -name '*.js' -o -name 'package.json' -o -name 'setup.py' -o -name 'setup.cfg' 2>/dev/null | head -100 | while read -r f; do
        guarddog pypi scan "$f" 2>/dev/null | grep -v "^$" >> "$LOG" || true
    done
done
echo "$(date -u +%FT%TZ) initial scan complete" | tee -a "$LOG"

# Watch for changes
last_scan=0
inotifywait -m -r -e create,modify,moved_to \
    --format '%T %w%f' --timefmt '%s' \
    $SCAN_DIRS 2>/dev/null | while read -r epoch filepath; do

    # Debounce — skip if scanned recently
    now=$(date +%s)
    if (( now - last_scan < DEBOUNCE )); then
        continue
    fi
    last_scan=$now

    # Only scan relevant files
    case "$filepath" in
        *.py|*.js|*.ts|*/package.json|*/setup.py|*/setup.cfg|*/pyproject.toml)
            echo "$(date -u +%FT%TZ) scanning: $filepath" | tee -a "$LOG"
            result=$(guarddog pypi scan "$filepath" 2>&1 || true)
            if echo "$result" | grep -qiE 'suspicious|malicious|warning'; then
                echo "$(date -u +%FT%TZ) ALERT: $filepath" | tee -a "$LOG"
                echo "$result" | tee -a "$LOG"
                echo "$result" >> "$RESULTS_DIR/alerts.log"
            fi
            ;;
    esac
done
