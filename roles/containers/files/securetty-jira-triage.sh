#!/bin/bash
# securetty-jira-triage — classify a Jira issue and route it for action.
# Takes a Jira issue key (e.g., AAP-12345), reads issue details via REST API,
# classifies into needs-info / codeable / skip, and applies agent:* labels
# to track state.  Skips issues that already carry any agent:* label.
set -euo pipefail

SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "/tmp/securetty-state" ]; then
    DAEMON_DIR="/tmp/securetty-state"
else
    DAEMON_DIR="$HOME/.securetty"
fi
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
# Project resolution — fuzzy multi-signal discovery
# =============================================================================

WORK_DIR="${SECURETTY_WORK_DIR:-$HOME/src/work}"
PROJECT_REGISTRY="${SECURETTY_PROJECT_REGISTRY:-}"

_resolve_project() {
    local issue_json="$1"
    local result
    result=$(python3 -c "
import json, os, re, sys, subprocess

issue = json.load(sys.stdin)
fields = issue.get('fields', {})
key = issue.get('key', '')
project = key.split('-')[0] if '-' in key else ''
summary = fields.get('summary', '') or ''
description = fields.get('description', '') or ''
components = [c.get('name', '') for c in (fields.get('components', []) or [])]

work_dir = os.environ.get('SECURETTY_WORK_DIR', os.path.expanduser('~/src/work'))
registry_json = os.environ.get('SECURETTY_PROJECT_REGISTRY', '[]')

text = (summary + ' ' + description + ' ' + ' '.join(components)).lower()
candidates = []

# --- Signal 1: Registry hints (regex match against issue text) ---
try:
    registry = json.loads(registry_json) if registry_json else []
except (json.JSONDecodeError, TypeError):
    registry = []

default_work_dir = None
for entry in registry:
    if entry.get('jira_project', '').upper() != project.upper():
        continue
    default_work_dir = entry.get('default_work_dir')
    for hint in entry.get('hints', []):
        pattern = hint.get('match', '')
        wdir = hint.get('work_dir', '')
        if pattern and wdir and re.search(pattern, text):
            full = os.path.join(work_dir, wdir)
            if os.path.isdir(full):
                candidates.append({'dir': wdir, 'confidence': 0.8, 'signal': 'registry_hint', 'pattern': pattern})

# --- Signal 2: Scan issue text for repo URLs ---
url_patterns = re.findall(r'(?:github\.com|gitlab[^/]*/)[^\s)\"]+', text)
for url_match in url_patterns:
    repo_name = url_match.rstrip('/').split('/')[-1].replace('.git', '')
    full = os.path.join(work_dir, repo_name)
    if os.path.isdir(full):
        candidates.append({'dir': repo_name, 'confidence': 0.9, 'signal': 'url_in_issue'})

# --- Signal 3: Fuzzy directory name match ---
if os.path.isdir(work_dir):
    for d in os.listdir(work_dir):
        full = os.path.join(work_dir, d)
        if not os.path.isdir(os.path.join(full, '.git')):
            continue
        d_lower = d.lower().replace('-', ' ').replace('_', ' ')
        d_words = set(d_lower.split())
        text_words = set(re.findall(r'[a-z]{3,}', text))
        overlap = d_words & text_words
        if len(overlap) >= 2:
            score = len(overlap) / max(len(d_words), 1)
            candidates.append({'dir': d, 'confidence': min(0.6 * score + 0.2, 0.7), 'signal': 'dir_fuzzy', 'overlap': list(overlap)})

# --- Signal 4: Git remote URL match ---
if os.path.isdir(work_dir):
    for d in os.listdir(work_dir):
        git_dir = os.path.join(work_dir, d, '.git')
        if not os.path.isdir(git_dir):
            continue
        try:
            result = subprocess.run(['git', '-C', os.path.join(work_dir, d), 'remote', '-v'],
                                     capture_output=True, text=True, timeout=5)
            for url_match in url_patterns:
                if url_match in result.stdout.lower():
                    candidates.append({'dir': d, 'confidence': 0.95, 'signal': 'remote_match'})
        except Exception:
            pass

# --- Signal 5: Triage history (same project, previous success) ---
dispatcher_url = os.environ.get('SECURETTY_DISPATCHER_URL', '')
if dispatcher_url:
    try:
        import urllib.request
        req = urllib.request.Request(f'{dispatcher_url}/triage?limit=20')
        with urllib.request.urlopen(req, timeout=5) as resp:
            history = json.loads(resp.read())
        for entry in history:
            if entry.get('project', '').upper() == project.upper() and entry.get('outcome') in ('merged', 'approved', 'completed'):
                meta = json.loads(entry.get('metadata', '{}') or '{}')
                hist_dir = meta.get('work_dir', '')
                if hist_dir and os.path.isdir(os.path.join(work_dir, hist_dir)):
                    candidates.append({'dir': hist_dir, 'confidence': 0.5, 'signal': 'triage_history'})
    except Exception:
        pass

# Deduplicate and rank
seen = {}
for c in candidates:
    d = c['dir']
    if d not in seen or c['confidence'] > seen[d]['confidence']:
        seen[d] = c
ranked = sorted(seen.values(), key=lambda x: -x['confidence'])

if not ranked and default_work_dir:
    full = os.path.join(work_dir, default_work_dir)
    if os.path.isdir(full):
        ranked = [{'dir': default_work_dir, 'confidence': 0.3, 'signal': 'default'}]

print(json.dumps(ranked))
" <<< "$issue_json" 2>/dev/null)
    echo "$result"
}

# =============================================================================
# Git safety — dirty tree guard and branch creation
# =============================================================================

_ensure_clean_worktree() {
    local repo_dir="$1"
    local key="$2"

    if [ ! -d "$repo_dir/.git" ]; then
        _log "ERROR: ${repo_dir} is not a git repository"
        return 1
    fi

    local status
    status=$(git -C "$repo_dir" status --porcelain 2>/dev/null)

    if [ -n "$status" ]; then
        local file_count
        file_count=$(echo "$status" | wc -l)
        _log "BLOCKED: ${repo_dir} has ${file_count} uncommitted change(s)"

        _add_label "$key" "agent:blocked"
        _remove_label "$key" "agent:in-progress"

        local comment_body
        comment_body=$(python3 -c "
import json
lines = [
    'Cannot proceed — work tree is dirty.',
    '',
    '* Directory: \`${repo_dir}\`',
    '* Uncommitted changes: ${file_count} file(s)',
    '* Label: {{agent:blocked}}',
    '',
    'Please commit or stash local changes, then remove the {{agent:blocked}} label to retry.',
]
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
        _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"
        return 1
    fi

    return 0
}

_create_agent_branch() {
    local repo_dir="$1"
    local key="$2"

    git -C "$repo_dir" fetch origin 2>/dev/null || {
        _log "ERROR: git fetch failed in ${repo_dir}"
        return 1
    }

    local default_branch
    default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [ -z "$default_branch" ]; then
        for candidate in main master; do
            if git -C "$repo_dir" rev-parse --verify "origin/${candidate}" &>/dev/null; then
                default_branch="$candidate"
                break
            fi
        done
    fi

    if [ -z "$default_branch" ]; then
        _log "ERROR: cannot determine default branch in ${repo_dir}"
        return 1
    fi

    local branch_name="agent/${key}"

    if git -C "$repo_dir" rev-parse --verify "$branch_name" &>/dev/null; then
        _log "branch ${branch_name} already exists in ${repo_dir}, checking out"
        git -C "$repo_dir" checkout "$branch_name" 2>/dev/null
    else
        git -C "$repo_dir" checkout -b "$branch_name" "origin/${default_branch}" 2>/dev/null || {
            _log "ERROR: failed to create branch ${branch_name} in ${repo_dir}"
            return 1
        }
    fi

    _log "branch ${branch_name} ready in ${repo_dir} (from origin/${default_branch})"
    return 0
}

# =============================================================================
# Jira status transitions
# =============================================================================

_transition_to_in_progress() {
    local key="$1"
    local transitions_json
    transitions_json=$(_jira_get "/rest/api/2/issue/${key}/transitions")
    [ -z "$transitions_json" ] && return 1

    local target_id
    target_id=$(echo "$transitions_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('transitions', []):
    name = t.get('to', {}).get('name', '').lower()
    if name in ('in progress', 'in development', 'active'):
        print(t['id'])
        sys.exit(0)
print('')
" 2>/dev/null)

    if [ -n "$target_id" ]; then
        local body
        body=$(printf '{"transition":{"id":"%s"}}' "$target_id")
        _jira_post "/rest/api/2/issue/${key}/transitions" "$body"
        _log "transitioned ${key} to In Progress (id=${target_id})"
    else
        _log "WARNING: no In Progress transition found for ${key}"
    fi
}

_transition_to_in_review() {
    local key="$1"
    local transitions_json
    transitions_json=$(_jira_get "/rest/api/2/issue/${key}/transitions")
    [ -z "$transitions_json" ] && return 1

    local target_id
    target_id=$(echo "$transitions_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data.get('transitions', []):
    name = t.get('to', {}).get('name', '').lower()
    if name in ('in review', 'code review', 'review'):
        print(t['id'])
        sys.exit(0)
print('')
" 2>/dev/null)

    if [ -n "$target_id" ]; then
        local body
        body=$(printf '{"transition":{"id":"%s"}}' "$target_id")
        _jira_post "/rest/api/2/issue/${key}/transitions" "$body"
        _log "transitioned ${key} to In Review (id=${target_id})"
    else
        _log "WARNING: no In Review transition found for ${key}"
    fi
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
    local issue_json="$3"

    # --- Resolve target project directory ---
    local resolved_json
    resolved_json=$(_resolve_project "$issue_json")

    local top_dir top_confidence top_signal
    top_dir=$(echo "$resolved_json" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r[0]['dir'] if r else '')
" 2>/dev/null)
    top_confidence=$(echo "$resolved_json" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r[0]['confidence'] if r else '0')
" 2>/dev/null)
    top_signal=$(echo "$resolved_json" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(r[0].get('signal','') if r else '')
" 2>/dev/null)

    if [ -z "$top_dir" ]; then
        _log "cannot resolve project directory for ${key}"
        _add_label "$key" "agent:needs-info"

        local comment_body
        comment_body=$(python3 -c "
import json
lines = [
    'Cannot determine which repository to work in for this issue.',
    '',
    '* No matching directory found under the configured work directory.',
    '* Please add a component, mention the repo name, or link the repository in the description.',
    '',
    'Remove the {{agent:needs-info}} label to re-trigger triage.',
]
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
        _jira_post "/rest/api/2/issue/${key}/comment" "$comment_body"
        _log_stdout "needs-info: ${key} -- could not resolve project directory"
        return
    fi

    local repo_dir="${WORK_DIR}/${top_dir}"
    _log "resolved ${key} to ${repo_dir} (confidence=${top_confidence}, signal=${top_signal})"

    # --- Label + Jira transition: In Progress ---
    _add_label "$key" "agent:in-progress"
    _transition_to_in_progress "$key"

    # --- Git safety: check for dirty work tree ---
    if ! _ensure_clean_worktree "$repo_dir" "$key"; then
        _log_stdout "blocked: ${key} -- dirty work tree in ${repo_dir}"
        return
    fi

    # --- Create agent branch ---
    if ! _create_agent_branch "$repo_dir" "$key"; then
        _log_stdout "blocked: ${key} -- failed to create branch in ${repo_dir}"
        _add_label "$key" "agent:blocked"
        _remove_label "$key" "agent:in-progress"
        return
    fi

    # --- Dispatch ---
    local dispatch_result=""

    if command -v securetty &>/dev/null; then
        _log "dispatching ${key} via securetty CLI (work_dir=${repo_dir})"
        dispatch_result=$(securetty dispatch "Implement Jira issue ${key}" --source "jira-triage" 2>&1 || true)
        echo "$dispatch_result" >> "$LOG_FILE"
    elif [ -n "${SECURETTY_DISPATCHER_URL:-}" ]; then
        _log "dispatching ${key} via dispatcher API (work_dir=${repo_dir})"
        local body
        body=$(python3 -c "
import json
print(json.dumps({
    'work_item': 'Implement Jira issue $key',
    'source': 'jira-triage',
    'metadata': {
        'jira_key': '$key',
        'work_dir': '$top_dir',
        'repo_dir': '$repo_dir',
        'branch': 'agent/$key',
        'confidence': $top_confidence,
        'signal': '$top_signal'
    }
}))
" 2>/dev/null)
        dispatch_result=$(curl -sf -X POST "${SECURETTY_DISPATCHER_URL}/dispatch" \
            -H "Content-Type: application/json" -d "$body" 2>&1 || true)
        echo "$dispatch_result" >> "$LOG_FILE"
    else
        _log "WARNING: no dispatch mechanism available for ${key}"
    fi

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

    # Record triage history
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
    'metadata': {'reason': '''$reason''', 'work_dir': '$top_dir', 'branch': 'agent/$key', 'signal': '$top_signal'}
}))
" 2>/dev/null)
        curl -sf -X POST "${SECURETTY_DISPATCHER_URL}/triage" \
            -H "Content-Type: application/json" -d "$triage_body" >> "$LOG_FILE" 2>&1 || true
    fi

    # --- Transition to in-review ---
    _remove_label "$key" "agent:in-progress"
    _add_label "$key" "agent:in-review"
    _transition_to_in_review "$key"

    local review_comment
    review_comment=$(python3 -c "
import json
lines = [
    'The securetty agent has dispatched a code change for this issue.',
    '',
    '* Work directory: \`$top_dir\`',
    '* Branch: \`agent/$key\`',
    '* Resolution signal: $top_signal (confidence: $top_confidence)',
]
job_id = '$job_id'
if job_id:
    lines.append('* Dispatcher job: {{' + job_id + '}}')
lines.extend([
    '* Status: awaiting code review',
    '* Label: {{agent:in-review}}',
    '',
    'A merge/pull request will be created by the agent. The review-manager will track review feedback and update this issue automatically.',
])
print(json.dumps({'body': chr(10).join(lines)}))
" 2>/dev/null)
    _jira_post "/rest/api/2/issue/${key}/comment" "$review_comment"

    if [ -n "${SECURETTY_DISPATCHER_URL:-}" ]; then
        curl -sf -X PUT "${SECURETTY_DISPATCHER_URL}/triage/${key}" \
            -H "Content-Type: application/json" \
            -d '{"feedback_status":"awaiting_review"}' >> "$LOG_FILE" 2>&1 || true
    fi

    _log_stdout "codeable: ${key} -- ${reason} -> ${top_dir} (agent:in-review)"
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
            _action_codeable "$key" "$reason" "$issue_json"
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
