#!/bin/bash
# securetty-review-manager — poll Jira issues with agent:in-review label and
# manage MR/PR review lifecycle (feedback, approval, merge).
#
# Subcommands:
#   start   — launch as background daemon
#   stop    — stop the running daemon
#   status  — show daemon status and recent activity
#
# Environment:
#   SECURETTY_JIRA_URL            — Jira base URL (required)
#   SECURETTY_JIRA_USER           — Jira username (basic auth)
#   JIRA_API_TOKEN                — Jira API token
#   SECURETTY_DISPATCHER_URL      — dispatcher API base URL
#   SECURETTY_REVIEW_POLL_INTERVAL — poll interval in seconds (default 120)
#   SECURETTY_REVIEW_STALE_HOURS  — hours before nudging reviewer (default 24)
#   SECURETTY_AUTO_MERGE          — set to "true" to auto-merge approved PRs
set -euo pipefail

if [ -d "/tmp/securetty-state" ]; then
    DAEMON_DIR="/tmp/securetty-state"
else
    DAEMON_DIR="$HOME/.securetty"
fi
LOG_FILE="$DAEMON_DIR/review-manager.log"
PID_FILE="$DAEMON_DIR/review-manager.pid"

JIRA_URL="${SECURETTY_JIRA_URL:-}"
JIRA_USER="${SECURETTY_JIRA_USER:-}"
JIRA_TOKEN="${JIRA_API_TOKEN:-}"
DISPATCHER_URL="${SECURETTY_DISPATCHER_URL:-}"
POLL_INTERVAL="${SECURETTY_REVIEW_POLL_INTERVAL:-120}"
STALE_HOURS="${SECURETTY_REVIEW_STALE_HOURS:-24}"
AUTO_MERGE="${SECURETTY_AUTO_MERGE:-false}"

# Try creds proxy if no token is set directly
if [ -z "$JIRA_TOKEN" ]; then
    JIRA_TOKEN=$(curl -sf http://localhost:9401/creds/jira_api_token 2>/dev/null || true)
fi

# =============================================================================
# Logging
# =============================================================================

_log() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts $*" >> "$LOG_FILE"
}

_log_stdout() {
    local ts
    ts=$(date -u +%FT%TZ)
    echo "$ts $*" | tee -a "$LOG_FILE"
}

# =============================================================================
# Jira REST helpers
# =============================================================================

_jira_auth_header() {
    if [ -n "$JIRA_USER" ] && [ -n "$JIRA_TOKEN" ]; then
        echo "-u ${JIRA_USER}:${JIRA_TOKEN}"
    elif [ -n "$JIRA_TOKEN" ]; then
        echo "-H Authorization: Bearer ${JIRA_TOKEN}"
    else
        echo ""
    fi
}

_jira_get() {
    local path="$1"
    local auth
    auth=$(_jira_auth_header)
    # shellcheck disable=SC2086
    curl $auth -sf -H "Content-Type: application/json" \
        "${JIRA_URL}${path}" 2>/dev/null || echo ""
}

_jira_put() {
    local path="$1"
    local body="$2"
    local auth
    auth=$(_jira_auth_header)
    # shellcheck disable=SC2086
    curl $auth -sf -X PUT -H "Content-Type: application/json" \
        -d "$body" "${JIRA_URL}${path}" 2>/dev/null || echo ""
}

_jira_post() {
    local path="$1"
    local body="$2"
    local auth
    auth=$(_jira_auth_header)
    # shellcheck disable=SC2086
    curl $auth -sf -X POST -H "Content-Type: application/json" \
        -d "$body" "${JIRA_URL}${path}" 2>/dev/null || echo ""
}

# =============================================================================
# Label operations
# =============================================================================

_add_label() {
    local key="$1"
    local label="$2"
    local body
    body=$(printf '{"update":{"labels":[{"add":"%s"}]}}' "$label")
    _jira_put "/rest/api/2/issue/${key}" "$body"
    _log "label added: ${key} <- ${label}"
}

_remove_label() {
    local key="$1"
    local label="$2"
    local body
    body=$(printf '{"update":{"labels":[{"remove":"%s"}]}}' "$label")
    _jira_put "/rest/api/2/issue/${key}" "$body"
    _log "label removed: ${key} <- ${label}"
}

# =============================================================================
# Jira transition helper
# =============================================================================

_transition_to_done() {
    local key="$1"
    # Find the "Done" transition id
    local transitions_json
    transitions_json=$(_jira_get "/rest/api/2/issue/${key}/transitions")
    if [ -z "$transitions_json" ]; then
        _log "WARNING: could not fetch transitions for ${key}"
        return 1
    fi

    local done_id
    done_id=$(echo "$transitions_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('transitions', []):
    name = t.get('to', {}).get('name', '').lower()
    if name in ('done', 'closed', 'resolved'):
        print(t['id'])
        sys.exit(0)
print('')
" 2>/dev/null)

    if [ -n "$done_id" ]; then
        local body
        body=$(printf '{"transition":{"id":"%s"}}' "$done_id")
        _jira_post "/rest/api/2/issue/${key}/transitions" "$body"
        _log "transitioned ${key} to Done (id=${done_id})"
    else
        _log "WARNING: no Done transition found for ${key}"
    fi
}

# =============================================================================
# MR/PR status checking
# =============================================================================

_extract_pr_url() {
    # Extract PR/MR URL from triage_history metadata or Jira issue comments
    local key="$1"

    # Try dispatcher triage_history first
    if [ -n "$DISPATCHER_URL" ]; then
        local triage_json
        triage_json=$(curl -sf "${DISPATCHER_URL}/triage/${key}" 2>/dev/null || echo "")
        if [ -n "$triage_json" ] && [ "$triage_json" != "[]" ]; then
            local url
            url=$(echo "$triage_json" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
for e in entries:
    pr = e.get('pr_url', '')
    if pr:
        print(pr)
        sys.exit(0)
print('')
" 2>/dev/null)
            if [ -n "$url" ]; then
                echo "$url"
                return 0
            fi
        fi
    fi

    # Fall back to scanning Jira comments for PR/MR URLs
    local comments_json
    comments_json=$(_jira_get "/rest/api/2/issue/${key}/comment?maxResults=20&orderBy=-created")
    if [ -n "$comments_json" ]; then
        local url
        url=$(echo "$comments_json" | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
for c in data.get('comments', []):
    body = c.get('body', '')
    # Match GitHub PR or GitLab MR URLs
    m = re.search(r'(https?://[^\s]+/pull/\d+|https?://[^\s]+/-/merge_requests/\d+)', body)
    if m:
        print(m.group(1))
        sys.exit(0)
print('')
" 2>/dev/null)
        if [ -n "$url" ]; then
            echo "$url"
            return 0
        fi
    fi

    echo ""
}

_check_github_pr() {
    local pr_url="$1"
    # gh pr view accepts a URL directly
    local pr_json
    pr_json=$(gh pr view "$pr_url" --json state,reviewDecision,reviews 2>/dev/null || echo "")
    if [ -z "$pr_json" ]; then
        echo "error"
        return 1
    fi

    echo "$pr_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
state = data.get('state', '').upper()
decision = data.get('reviewDecision', '').upper()

if state == 'MERGED':
    print('merged')
elif state == 'CLOSED':
    print('closed')
elif decision == 'APPROVED':
    print('approved')
elif decision == 'CHANGES_REQUESTED':
    # Collect review comments
    reviews = data.get('reviews', [])
    comments = []
    for r in reviews:
        if r.get('state') == 'CHANGES_REQUESTED' and r.get('body'):
            comments.append(r['body'])
    if comments:
        print('changes_requested:' + '|'.join(comments))
    else:
        print('changes_requested')
elif decision == 'REVIEW_REQUIRED' or decision == '':
    print('pending')
else:
    print('pending')
" 2>/dev/null
}

_check_gitlab_mr() {
    local mr_url="$1"
    # Extract project path and MR iid from URL
    local mr_info
    mr_info=$(echo "$mr_url" | python3 -c "
import re, sys
url = sys.stdin.read().strip()
m = re.match(r'https?://([^/]+)/(.+)/-/merge_requests/(\d+)', url)
if m:
    print(m.group(2) + ' ' + m.group(3))
else:
    print('')
" 2>/dev/null)

    if [ -z "$mr_info" ]; then
        echo "error"
        return 1
    fi

    local project_path mr_iid
    project_path=$(echo "$mr_info" | cut -d' ' -f1)
    mr_iid=$(echo "$mr_info" | cut -d' ' -f2)

    local mr_json
    mr_json=$(glab mr view "$mr_iid" -R "$project_path" --output json 2>/dev/null || echo "")
    if [ -z "$mr_json" ]; then
        echo "error"
        return 1
    fi

    echo "$mr_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
state = data.get('state', '').lower()

if state == 'merged':
    print('merged')
elif state == 'closed':
    print('closed')
else:
    # Check approvals
    approved_by = data.get('approved_by', data.get('approvals', {}).get('approved_by', []))
    if isinstance(approved_by, list) and len(approved_by) > 0:
        print('approved')
    else:
        # Check for unresolved discussions (change requests)
        notes = data.get('notes', [])
        unresolved = [n for n in notes if n.get('resolvable') and not n.get('resolved')]
        if unresolved:
            bodies = [n.get('body', '') for n in unresolved if n.get('body')]
            if bodies:
                print('changes_requested:' + '|'.join(bodies[:5]))
            else:
                print('changes_requested')
        else:
            print('pending')
" 2>/dev/null
}

_check_pr_status() {
    local pr_url="$1"
    if echo "$pr_url" | grep -qE 'github\.com.*pull/'; then
        _check_github_pr "$pr_url"
    elif echo "$pr_url" | grep -qE 'merge_requests/'; then
        _check_gitlab_mr "$pr_url"
    else
        _log "WARNING: unrecognized PR/MR URL format: ${pr_url}"
        echo "error"
    fi
}

# =============================================================================
# Review feedback handling
# =============================================================================

_handle_changes_requested() {
    local key="$1"
    local pr_url="$2"
    local review_comments="$3"

    _log "changes requested for ${key}, dispatching agent to address feedback"

    # Update triage history
    if [ -n "$DISPATCHER_URL" ]; then
        curl -sf -X PUT "${DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"changes_requested"}' >> "$LOG_FILE" 2>&1 || true
    fi

    # Transition label: in-review -> in-progress -> (agent works) -> in-review
    _remove_label "$key" "agent:in-review"
    _add_label "$key" "agent:in-progress"

    # Dispatch agent to address review feedback, preserving original work_dir
    if [ -n "$DISPATCHER_URL" ]; then
        local feedback_text
        feedback_text=$(echo "$review_comments" | tr '|' '\n' | head -c 2000)

        # Retrieve work_dir from triage history
        local orig_work_dir=""
        local orig_branch=""
        local triage_json
        triage_json=$(curl -sf "${DISPATCHER_URL}/triage/${key}" 2>/dev/null || echo "")
        if [ -n "$triage_json" ] && [ "$triage_json" != "[]" ]; then
            orig_work_dir=$(echo "$triage_json" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
for e in entries:
    meta = json.loads(e.get('metadata', '{}') or '{}')
    wd = meta.get('work_dir', '')
    if wd:
        print(wd)
        sys.exit(0)
print('')
" 2>/dev/null)
            orig_branch=$(echo "$triage_json" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
for e in entries:
    meta = json.loads(e.get('metadata', '{}') or '{}')
    br = meta.get('branch', '')
    if br:
        print(br)
        sys.exit(0)
print('')
" 2>/dev/null)
        fi

        local work_dir_env="${SECURETTY_WORK_DIR:-$HOME/src/work}"
        local repo_dir=""
        [ -n "$orig_work_dir" ] && repo_dir="${work_dir_env}/${orig_work_dir}"

        local body
        body=$(python3 -c "
import json
print(json.dumps({
    'work_item': 'Address review feedback for Jira issue $key: ' + '''$feedback_text''',
    'source': 'review-manager',
    'metadata': {
        'jira_key': '$key',
        'pr_url': '$pr_url',
        'action': 'address_review_feedback',
        'work_dir': '$orig_work_dir',
        'repo_dir': '$repo_dir',
        'branch': '$orig_branch'
    }
}))
" 2>/dev/null)
        curl -sf -X POST "${DISPATCHER_URL}/dispatch" \
            -H "Content-Type: application/json" -d "$body" >> "$LOG_FILE" 2>&1 || true
    fi

    # Post Jira comment about addressing feedback
    local comment_body
    comment_body=$(python3 -c "
import json
lines = [
    'Review feedback received on the merge/pull request.',
    '',
    '* Status: addressing reviewer comments',
    '* Label updated: {{agent:in-progress}}',
    '',
    'The agent is working on the requested changes and will force-push an update.',
]
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"

    # After dispatch, set back to in-review (agent will push changes)
    _remove_label "$key" "agent:in-progress"
    _add_label "$key" "agent:in-review"

    # Update triage history back to awaiting_review
    if [ -n "$DISPATCHER_URL" ]; then
        curl -sf -X PUT "${DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"awaiting_review"}' >> "$LOG_FILE" 2>&1 || true
    fi

    _log_stdout "review-manager: ${key} -- changes requested, agent re-dispatched"
}

_handle_approved() {
    local key="$1"
    local pr_url="$2"

    _log "PR approved for ${key}"

    # Update triage history
    if [ -n "$DISPATCHER_URL" ]; then
        curl -sf -X PUT "${DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"approved","outcome":"approved"}' >> "$LOG_FILE" 2>&1 || true
    fi

    # Auto-merge if enabled
    local merge_result="auto-merge not enabled"
    if [ "$AUTO_MERGE" = "true" ]; then
        if echo "$pr_url" | grep -qE 'github\.com.*pull/'; then
            merge_result=$(gh pr merge "$pr_url" --merge 2>&1 || echo "merge failed")
        elif echo "$pr_url" | grep -qE 'merge_requests/'; then
            local mr_info
            mr_info=$(echo "$pr_url" | python3 -c "
import re, sys
url = sys.stdin.read().strip()
m = re.match(r'https?://([^/]+)/(.+)/-/merge_requests/(\d+)', url)
if m:
    print(m.group(2) + ' ' + m.group(3))
" 2>/dev/null)
            if [ -n "$mr_info" ]; then
                local project_path mr_iid
                project_path=$(echo "$mr_info" | cut -d' ' -f1)
                mr_iid=$(echo "$mr_info" | cut -d' ' -f2)
                merge_result=$(glab mr merge "$mr_iid" -R "$project_path" --yes 2>&1 || echo "merge failed")
            fi
        fi
        _log "merge result for ${key}: ${merge_result}"
    fi

    # Update labels
    _remove_label "$key" "agent:in-review"
    _add_label "$key" "agent:completed"

    # Transition Jira to Done
    _transition_to_done "$key"

    # Post Jira comment
    local comment_body
    comment_body=$(python3 -c "
import json
lines = [
    'The merge/pull request has been approved by a reviewer.',
    '',
    '* PR/MR: $pr_url',
    '* Auto-merge: $merge_result',
    '* Label updated: {{agent:completed}}',
    '',
    'This issue has been transitioned to Done.',
]
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"

    _log_stdout "review-manager: ${key} -- approved and completed"
}

_handle_merged() {
    local key="$1"
    local pr_url="$2"

    _log "PR merged for ${key}"

    # Update triage history
    if [ -n "$DISPATCHER_URL" ]; then
        curl -sf -X PUT "${DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"merged","outcome":"merged"}' >> "$LOG_FILE" 2>&1 || true
    fi

    # Update labels
    _remove_label "$key" "agent:in-review"
    _add_label "$key" "agent:completed"

    # Transition Jira to Done
    _transition_to_done "$key"

    # Post Jira comment with merge details
    local merge_details=""
    if echo "$pr_url" | grep -qE 'github\.com.*pull/'; then
        merge_details=$(gh pr view "$pr_url" --json mergedAt,mergedBy,mergeCommit --jq '
            "Merged by: " + (.mergedBy.login // "unknown") +
            " at " + (.mergedAt // "unknown") +
            " (commit: " + (.mergeCommit.oid // "unknown")[0:8] + ")"
        ' 2>/dev/null || echo "")
    fi

    local comment_body
    comment_body=$(python3 -c "
import json
lines = [
    'The merge/pull request has been merged.',
    '',
    '* PR/MR: $pr_url',
]
details = '''$merge_details'''
if details:
    lines.append('* ' + details)
lines.extend([
    '* Label updated: {{agent:completed}}',
    '',
    'This issue has been transitioned to Done.',
])
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"

    _log_stdout "review-manager: ${key} -- merged and completed"
}

_handle_stale() {
    local key="$1"
    local pr_url="$2"

    _log "review stale for ${key} (no activity in ${STALE_HOURS}h)"

    # Post Jira comment nudging reviewer
    local comment_body
    comment_body=$(python3 -c "
import json
lines = [
    'This issue has an open merge/pull request awaiting review for more than ${STALE_HOURS} hours.',
    '',
    '* PR/MR: $pr_url',
    '* Status: awaiting review',
    '',
    'Please review the changes when you have a moment. The agent-generated code change is ready for feedback.',
]
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"

    _log_stdout "review-manager: ${key} -- nudged reviewer (stale ${STALE_HOURS}h)"
}

# =============================================================================
# Staleness check
# =============================================================================

_is_stale() {
    local key="$1"

    # Check when the agent:in-review label was added by looking at triage_history
    if [ -n "$DISPATCHER_URL" ]; then
        local triage_json
        triage_json=$(curl -sf "${DISPATCHER_URL}/triage/${key}" 2>/dev/null || echo "")
        if [ -n "$triage_json" ] && [ "$triage_json" != "[]" ]; then
            local is_stale
            is_stale=$(echo "$triage_json" | python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta

entries = json.load(sys.stdin)
stale_hours = int('${STALE_HOURS}')
now = datetime.now(timezone.utc)
threshold = now - timedelta(hours=stale_hours)

for e in entries:
    updated = e.get('updated_at', e.get('created_at', ''))
    if updated:
        try:
            dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
            if dt < threshold:
                print('true')
                sys.exit(0)
        except ValueError:
            pass
print('false')
" 2>/dev/null)
            if [ "$is_stale" = "true" ]; then
                return 0
            fi
        fi
    fi

    return 1
}

# =============================================================================
# Main poll loop
# =============================================================================

_poll_once() {
    _log "polling for issues with agent:in-review label"

    # Search Jira for issues with agent:in-review label
    local jql="labels = \"agent:in-review\""
    local encoded_jql
    encoded_jql=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$jql', safe=''))" 2>/dev/null)

    local search_json
    search_json=$(_jira_get "/rest/api/2/search?jql=${encoded_jql}&maxResults=50&fields=key,summary,labels,updated")

    if [ -z "$search_json" ]; then
        _log "WARNING: Jira search returned empty response"
        return
    fi

    local issue_keys
    issue_keys=$(echo "$search_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
issues = data.get('issues', [])
for issue in issues:
    print(issue.get('key', ''))
" 2>/dev/null)

    if [ -z "$issue_keys" ]; then
        _log "no issues with agent:in-review label found"
        return
    fi

    local count=0
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        count=$((count + 1))
        _log "checking review status for ${key}"

        # Find the PR/MR URL
        local pr_url
        pr_url=$(_extract_pr_url "$key")

        if [ -z "$pr_url" ]; then
            _log "WARNING: no PR/MR URL found for ${key}, skipping"
            continue
        fi

        # Check PR/MR status
        local status
        status=$(_check_pr_status "$pr_url")

        case "$status" in
            merged)
                _handle_merged "$key" "$pr_url"
                ;;
            approved)
                _handle_approved "$key" "$pr_url"
                ;;
            changes_requested*)
                local comments="${status#changes_requested:}"
                _handle_changes_requested "$key" "$pr_url" "$comments"
                ;;
            closed)
                _log "PR/MR closed for ${key}, removing in-review label"
                _remove_label "$key" "agent:in-review"
                _add_label "$key" "agent:skipped"
                if [ -n "$DISPATCHER_URL" ]; then
                    curl -sf -X PUT "${DISPATCHER_URL}/triage/${key}" \
                        -H "Content-Type: application/json" \
                        -d '{"feedback_status":"closed","outcome":"closed"}' >> "$LOG_FILE" 2>&1 || true
                fi
                ;;
            pending)
                # Check if stale
                if _is_stale "$key"; then
                    _handle_stale "$key" "$pr_url"
                else
                    _log "review pending for ${key}, no action needed"
                fi
                ;;
            error|*)
                _log "WARNING: could not determine PR status for ${key}"
                ;;
        esac
    done <<< "$issue_keys"

    _log "poll complete: checked ${count} issue(s)"
}

_run_daemon() {
    _log_stdout "review-manager daemon started (poll interval: ${POLL_INTERVAL}s)"

    while true; do
        _poll_once || _log "WARNING: poll cycle had errors"
        sleep "$POLL_INTERVAL"
    done
}

# =============================================================================
# Daemon management (start / stop / status)
# =============================================================================

cmd_start() {
    if [ -z "$JIRA_URL" ]; then
        echo "ERROR: SECURETTY_JIRA_URL is not set" >&2
        exit 1
    fi

    mkdir -p "$DAEMON_DIR"

    # Check if already running
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "review-manager is already running (PID ${old_pid})" >&2
            exit 1
        fi
        rm -f "$PID_FILE"
    fi

    local foreground=0
    for arg in "$@"; do
        [ "$arg" = "--foreground" ] && foreground=1
    done

    if [ "$foreground" -eq 1 ]; then
        echo $$ > "$PID_FILE" 2>/dev/null || true
        _run_daemon
    else
        echo "Starting review-manager daemon..."
        _run_daemon &
        local pid=$!
        echo "$pid" > "$PID_FILE"
        echo "review-manager started (PID ${pid})"
        echo "  Log: ${LOG_FILE}"
        echo "  PID file: ${PID_FILE}"
        echo "  Poll interval: ${POLL_INTERVAL}s"
        disown "$pid"
    fi
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "review-manager is not running (no PID file)" >&2
        exit 1
    fi

    local pid
    pid=$(cat "$PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping review-manager (PID ${pid})..."
        kill "$pid"
        # Wait for process to exit
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ $waited -lt 10 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force-killing review-manager (PID ${pid})..."
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
        echo "review-manager stopped"
    else
        echo "review-manager is not running (stale PID file)"
        rm -f "$PID_FILE"
    fi
}

cmd_status() {
    echo "=== securetty review-manager status ==="
    echo ""

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "State:         running (PID ${pid})"
        else
            echo "State:         stopped (stale PID file)"
        fi
    else
        echo "State:         stopped"
    fi

    echo "Log file:      ${LOG_FILE}"
    echo "PID file:      ${PID_FILE}"
    echo "Poll interval: ${POLL_INTERVAL}s"
    echo "Stale after:   ${STALE_HOURS}h"
    echo "Auto-merge:    ${AUTO_MERGE}"
    echo ""

    # Show recent activity from log
    if [ -f "$LOG_FILE" ]; then
        echo "--- Recent activity (last 10 entries) ---"
        tail -n 10 "$LOG_FILE"
    else
        echo "No log file found."
    fi

    # Show current in-review issues if dispatcher is available
    if [ -n "$DISPATCHER_URL" ]; then
        echo ""
        echo "--- Triage entries awaiting review ---"
        local triage_json
        triage_json=$(curl -sf "${DISPATCHER_URL}/triage?status=awaiting_review" 2>/dev/null || echo "[]")
        echo "$triage_json" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
if not entries:
    print('  (none)')
else:
    for e in entries:
        key = e.get('issue_key', '?')
        pr = e.get('pr_url', 'no PR')
        updated = e.get('updated_at', '?')
        print(f'  {key}  pr={pr}  updated={updated}')
" 2>/dev/null
    fi
}

# =============================================================================
# Entrypoint
# =============================================================================

main() {
    local subcmd="${1:-}"

    case "$subcmd" in
        start)
            shift; cmd_start "$@"
            ;;
        stop)
            cmd_stop
            ;;
        status)
            cmd_status
            ;;
        *)
            echo "Usage: securetty-review-manager {start|stop|status}" >&2
            echo "" >&2
            echo "Manage MR/PR review lifecycle for agent-triaged Jira issues." >&2
            echo "" >&2
            echo "Subcommands:" >&2
            echo "  start   Start the review-manager daemon" >&2
            echo "  stop    Stop the running daemon" >&2
            echo "  status  Show daemon status and recent activity" >&2
            echo "" >&2
            echo "Environment:" >&2
            echo "  SECURETTY_JIRA_URL               Jira base URL (required)" >&2
            echo "  SECURETTY_DISPATCHER_URL          Dispatcher API URL" >&2
            echo "  SECURETTY_REVIEW_POLL_INTERVAL    Poll interval seconds (default: 120)" >&2
            echo "  SECURETTY_REVIEW_STALE_HOURS      Hours before nudge (default: 24)" >&2
            echo "  SECURETTY_AUTO_MERGE              Auto-merge approved PRs (default: false)" >&2
            exit 1
            ;;
    esac
}

main "$@"
