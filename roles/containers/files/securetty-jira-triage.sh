#!/bin/bash
# securetty-jira-triage — classify a Jira issue and route it for action.
# Takes a Jira issue key (e.g., AAP-12345), reads issue details via REST API,
# classifies into needs-info / codeable / skip, and applies agent:* labels
# to track state.  Skips issues that already carry any agent:* label.
set -euo pipefail

SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_DIR="$HOME/.securetty"
LOG_FILE="$DAEMON_DIR/jira-triage.log"

JIRA_URL="${SECURETTY_JIRA_URL:-}"
JIRA_USER="${SECURETTY_JIRA_USER:-}"
JIRA_TOKEN="${JIRA_API_TOKEN:-}"

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

_has_agent_label() {
    local labels_json="$1"
    # Recognises all agent:* labels including agent:in-review
    echo "$labels_json" | python3 -c "
import json, sys
labels = json.load(sys.stdin)
agent_labels = {'agent:triaged', 'agent:needs-info', 'agent:in-progress',
                'agent:in-review', 'agent:completed', 'agent:skipped'}
for l in labels:
    if l.startswith('agent:') or l in agent_labels:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
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
# Classification logic
# =============================================================================

_classify() {
    local issue_json="$1"
    local result
    result=$(echo "$issue_json" | python3 -c "
import json, sys

issue = json.load(sys.stdin)
fields = issue.get('fields', {})

issue_type = (fields.get('issuetype', {}) or {}).get('name', '').lower()
status = (fields.get('status', {}) or {}).get('name', '').lower()
summary = fields.get('summary', '') or ''
description = fields.get('description', '') or ''
subtasks = fields.get('subtasks', []) or []
components = [c.get('name', '') for c in (fields.get('components', []) or [])]

# --- skip checks ---
if issue_type == 'epic':
    print('skip:issue is an Epic')
    sys.exit(0)

if len(subtasks) > 0:
    print('skip:issue has subtasks')
    sys.exit(0)

if status in ('done', 'closed', 'resolved'):
    print(f'skip:issue is in {status} status')
    sys.exit(0)

# Non-technical heuristic: certain component names
non_tech = {'documentation', 'docs', 'marketing', 'sales', 'legal', 'design'}
if components and all(c.lower() in non_tech for c in components):
    print('skip:non-technical issue (components: ' + ', '.join(components) + ')')
    sys.exit(0)

# --- needs-info checks ---
desc_len = len(description.strip())

if desc_len < 50:
    print('needs-info:description is too short (' + str(desc_len) + ' chars)')
    sys.exit(0)

# Bug without repro steps
if issue_type == 'bug':
    desc_lower = description.lower()
    repro_indicators = ['steps to reproduce', 'repro', 'reproduction', 'how to reproduce',
                        'steps:', '1.', '1)']
    has_repro = any(ind in desc_lower for ind in repro_indicators)
    if not has_repro:
        print('needs-info:bug report missing reproduction steps')
        sys.exit(0)

# Missing acceptance criteria for stories
if issue_type in ('story', 'user story'):
    desc_lower = description.lower()
    ac_indicators = ['acceptance criteria', 'definition of done', 'done when',
                     'expected behavior', 'expected result', 'ac:']
    has_ac = any(ind in desc_lower for ind in ac_indicators)
    if not has_ac:
        print('needs-info:story missing acceptance criteria')
        sys.exit(0)

# --- codeable: everything else that passed skip and needs-info ---
print('codeable:issue has clear requirements')
" 2>/dev/null)
    echo "$result"
}

# =============================================================================
# Action handlers
# =============================================================================

_action_needs_info() {
    local key="$1"
    local reason="$2"
    local issue_json="$3"

    _add_label "$key" "agent:needs-info"

    # Build a targeted clarification comment
    local comment_body
    comment_body=$(echo "$issue_json" | python3 -c "
import json, sys

issue = json.load(sys.stdin)
fields = issue.get('fields', {})
issue_type = (fields.get('issuetype', {}) or {}).get('name', '').lower()
reason = '''$reason'''

lines = ['This issue was reviewed by the securetty triage agent and needs additional information before it can be worked on.', '']

if 'too short' in reason:
    lines.append('* The description is very brief. Could you provide more detail about what is needed, including context and expected outcome?')
elif 'reproduction steps' in reason:
    lines.append('* This bug report is missing reproduction steps. Please add:')
    lines.append('** Steps to reproduce the issue')
    lines.append('** Expected behavior')
    lines.append('** Actual behavior')
    lines.append('** Environment details (version, OS, etc.)')
elif 'acceptance criteria' in reason:
    lines.append('* This story is missing acceptance criteria. Please add:')
    lines.append('** What conditions must be met for this to be considered done?')
    lines.append('** Any specific edge cases to handle?')
    lines.append('** Are there performance or compatibility requirements?')
else:
    lines.append('* Additional detail is needed: ' + reason)

lines.append('')
lines.append('Once updated, remove the {{agent:needs-info}} label to re-trigger triage.')

print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)

    _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"
    _log_stdout "needs-info: ${key} -- ${reason}"
}

_action_codeable() {
    local key="$1"
    local reason="$2"

    _add_label "$key" "agent:in-progress"

    local dispatch_result=""

    # Dispatch via securetty CLI if available, otherwise via dispatcher API
    if command -v securetty &>/dev/null; then
        _log "dispatching ${key} via securetty CLI"
        dispatch_result=$(securetty dispatch "Implement Jira issue ${key}" --source "jira-triage" 2>&1 || true)
        echo "$dispatch_result" >> "$LOG_FILE"
    elif [ -n "${SECURETTY_DISPATCHER_URL:-}" ]; then
        _log "dispatching ${key} via dispatcher API"
        local body
        body=$(printf '{"work_item":"Implement Jira issue %s","source":"jira-triage","metadata":{"jira_key":"%s"}}' "$key" "$key")
        dispatch_result=$(curl -sf -X POST "${SECURETTY_DISPATCHER_URL}/dispatch" \
            -H "Content-Type: application/json" -d "$body" 2>&1 || true)
        echo "$dispatch_result" >> "$LOG_FILE"
    else
        _log "WARNING: no dispatch mechanism available for ${key}"
    fi

    # Extract job_id from dispatch result if available
    local job_id=""
    if [ -n "$dispatch_result" ]; then
        job_id=$(echo "$dispatch_result" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('job_id', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    fi

    # Record triage history via dispatcher API
    if [ -n "${SECURETTY_DISPATCHER_URL:-}" ]; then
        local project
        project=$(echo "$key" | cut -d- -f1)
        local triage_body
        triage_body=$(python3 -c "
import json
print(json.dumps({
    'issue_key': '$key',
    'project': '$project',
    'classification': 'codeable',
    'action_taken': 'dispatched',
    'job_id': '$job_id',
    'feedback_status': 'none',
    'metadata': {'reason': '''$reason'''}
}))
" 2>/dev/null)
        curl -sf -X POST "${SECURETTY_DISPATCHER_URL}/triage" \
            -H "Content-Type: application/json" -d "$triage_body" >> "$LOG_FILE" 2>&1 || true
    fi

    # After dispatch, transition to in-review state
    # The dispatched job handles code changes and push; once dispatched we
    # mark the issue as awaiting review so the review-manager can pick it up.
    _remove_label "$key" "agent:in-progress"
    _add_label "$key" "agent:in-review"

    # Post Jira comment noting the dispatch and pending review
    local review_comment
    review_comment=$(python3 -c "
import json
lines = [
    'The securetty agent has dispatched a code change for this issue.',
    '',
]
job_id = '$job_id'
if job_id:
    lines.append('* Dispatcher job: {{' + job_id + '}}')
lines.append('* Status: awaiting code review')
lines.append('* Label: {{agent:in-review}}')
lines.append('')
lines.append('A merge/pull request will be created by the agent. The review-manager will track review feedback and update this issue automatically.')
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$review_comment"

    # Update triage history feedback_status to awaiting_review
    if [ -n "${SECURETTY_DISPATCHER_URL:-}" ]; then
        curl -sf -X PUT "${SECURETTY_DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"awaiting_review"}' >> "$LOG_FILE" 2>&1 || true
    fi

    _log_stdout "codeable: ${key} -- ${reason} (agent:in-review label applied)"
}

_action_skip() {
    local key="$1"
    local reason="$2"

    _add_label "$key" "agent:skipped"
    _log_stdout "skip: ${key} -- ${reason}"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local key="${1:-}"

    if [ -z "$key" ]; then
        echo "Usage: securetty-jira-triage <ISSUE-KEY>" >&2
        echo "  e.g. securetty-jira-triage AAP-12345" >&2
        exit 1
    fi

    if [ -z "$JIRA_URL" ]; then
        echo "ERROR: SECURETTY_JIRA_URL is not set" >&2
        exit 1
    fi

    mkdir -p "$DAEMON_DIR"

    _log "triaging ${key}"

    # Fetch issue details
    local issue_json
    issue_json=$(_jira_get "/rest/api/2/issue/${key}?fields=summary,description,issuetype,priority,components,labels,status,subtasks")

    if [ -z "$issue_json" ]; then
        _log_stdout "ERROR: failed to fetch issue ${key}"
        exit 1
    fi

    # Extract labels and check for existing agent:* labels
    local labels_json
    labels_json=$(echo "$issue_json" | python3 -c "
import json, sys
issue = json.load(sys.stdin)
labels = issue.get('fields', {}).get('labels', [])
json.dump(labels, sys.stdout)
" 2>/dev/null)

    if _has_agent_label "$labels_json"; then
        _log "skipping ${key}: already has agent:* label"
        return 0
    fi

    # Add agent:triaged immediately
    _add_label "$key" "agent:triaged"

    # Classify the issue
    local classification
    classification=$(_classify "$issue_json")

    if [ -z "$classification" ]; then
        _log_stdout "ERROR: classification failed for ${key}"
        _add_label "$key" "agent:skipped"
        return 1
    fi

    local action reason
    action="${classification%%:*}"
    reason="${classification#*:}"

    case "$action" in
        needs-info)
            _action_needs_info "$key" "$reason" "$issue_json"
            ;;
        codeable)
            _action_codeable "$key" "$reason"
            ;;
        skip)
            _action_skip "$key" "$reason"
            ;;
        *)
            _log_stdout "ERROR: unknown classification '${action}' for ${key}"
            _add_label "$key" "agent:skipped"
            ;;
    esac
}

main "$@"
