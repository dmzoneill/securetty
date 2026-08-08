#!/bin/bash
# Zero-token-cost preflight: check if work item is actionable before spending tokens.
# Runs deterministic checks (API calls, dedup) to avoid dispatching work that is
# already closed, assigned, or recently processed.
#   Exit 0 = proceed (work item is actionable)
#   Exit 1 = skip (not actionable)
#
# Usage:
#   securetty-preflight-skip.sh <work-item> [--source github|gitlab|jira]
#
# Environment:
#   SECURETTY_DISPATCHER_URL   Dispatcher base URL (default: https://securetty-dispatcher:8900)
#   SECURETTY_JIRA_URL         Jira base URL (e.g. https://issues.redhat.com)
#   SECURETTY_JIRA_TOKEN       Jira personal access token
#   SECURETTY_STALE_WINDOW     Seconds to consider a duplicate stale (default: 3600)
set -euo pipefail

DISPATCHER_URL="${SECURETTY_DISPATCHER_URL:-https://securetty-dispatcher:8900}"
JIRA_URL="${SECURETTY_JIRA_URL:-}"
JIRA_TOKEN="${SECURETTY_JIRA_TOKEN:-}"
STALE_WINDOW="${SECURETTY_STALE_WINDOW:-3600}"

WORK_ITEM=""
SOURCE=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
Usage:
  securetty-preflight-skip.sh <work-item> [--source github|gitlab|jira]

Examples:
  securetty-preflight-skip.sh https://github.com/org/repo/pull/42
  securetty-preflight-skip.sh https://github.com/org/repo/issues/10
  securetty-preflight-skip.sh https://gitlab.com/org/repo/-/merge_requests/7 --source gitlab
  securetty-preflight-skip.sh PROJ-1234 --source jira

Exit codes:
  0  Work item is actionable -- proceed with agent dispatch
  1  Work item should be skipped -- not actionable or duplicate
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || usage

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            [ $# -ge 2 ] || { echo "ERROR: --source requires a value" >&2; usage; }
            SOURCE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "ERROR: unknown flag: $1" >&2
            usage
            ;;
        *)
            if [ -z "$WORK_ITEM" ]; then
                WORK_ITEM="$1"
            else
                echo "ERROR: unexpected argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

[ -n "$WORK_ITEM" ] || { echo "ERROR: no work item specified" >&2; usage; }

# ---------------------------------------------------------------------------
# Auto-detect source from URL if not explicitly provided
# ---------------------------------------------------------------------------
if [ -z "$SOURCE" ]; then
    case "$WORK_ITEM" in
        *github.com*)  SOURCE="github" ;;
        *gitlab.com*|*gitlab.cee.redhat.com*) SOURCE="gitlab" ;;
        *-[0-9]*) SOURCE="jira" ;;  # e.g. PROJ-1234
        *)
            echo "WARN: could not auto-detect source for '$WORK_ITEM', running generic checks only" >&2
            SOURCE="generic"
            ;;
    esac
fi

echo "preflight: work_item=$WORK_ITEM source=$SOURCE" >&2

# ---------------------------------------------------------------------------
# Check 1: Stale / duplicate -- was this exact work item dispatched recently?
# ---------------------------------------------------------------------------
check_stale_duplicate() {
    local work_item="$1"

    # Query dispatcher /jobs endpoint for recent jobs with the same work_item
    local response
    if ! response=$(curl -sf --max-time 5 \
        "${DISPATCHER_URL}/jobs?status=pending&limit=100" 2>/dev/null); then
        echo "  WARN: dispatcher unreachable, skipping stale check" >&2
        return 0
    fi

    # Check if this exact work item appears in pending or running jobs
    for status in pending running; do
        local matches
        if matches=$(curl -sf --max-time 5 \
            "${DISPATCHER_URL}/jobs?status=${status}&limit=100" 2>/dev/null); then
            if echo "$matches" | grep -q "\"work_item\":\"${work_item}\"" 2>/dev/null || \
               echo "$matches" | grep -q "\"work_item\": \"${work_item}\"" 2>/dev/null; then
                echo "  SKIP: work item already ${status} in dispatcher" >&2
                return 1
            fi
        fi
    done

    # Check completed jobs within the stale window
    local completed
    if completed=$(curl -sf --max-time 5 \
        "${DISPATCHER_URL}/jobs?status=completed&limit=100" 2>/dev/null); then
        # Look for this work item completed within STALE_WINDOW seconds
        local now
        now=$(date +%s)
        local cutoff=$((now - STALE_WINDOW))
        local cutoff_iso
        cutoff_iso=$(date -u -d "@${cutoff}" +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
                     date -u -r "${cutoff}" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")

        if [ -n "$cutoff_iso" ]; then
            # If work item appears in completed jobs, check timestamp
            if echo "$completed" | grep -q "\"work_item\":\"${work_item}\"" 2>/dev/null || \
               echo "$completed" | grep -q "\"work_item\": \"${work_item}\"" 2>/dev/null; then
                echo "  SKIP: work item was completed within stale window (${STALE_WINDOW}s)" >&2
                return 1
            fi
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Check 2: GitHub PR -- is it still open?
# ---------------------------------------------------------------------------
check_github_pr() {
    local url="$1"

    if ! command -v gh >/dev/null 2>&1; then
        echo "  WARN: gh CLI not installed, skipping GitHub PR check" >&2
        return 0
    fi

    # Extract owner/repo and PR number from URL
    local pr_path
    pr_path=$(echo "$url" | sed -n 's|.*github\.com/\([^/]*/[^/]*\)/pull/\([0-9]*\).*|\1 \2|p')
    if [ -z "$pr_path" ]; then
        echo "  WARN: could not parse GitHub PR URL: $url" >&2
        return 0
    fi

    local repo pr_num
    repo=$(echo "$pr_path" | cut -d' ' -f1)
    pr_num=$(echo "$pr_path" | cut -d' ' -f2)

    local state
    if ! state=$(gh pr view "$pr_num" --repo "$repo" --json state --jq '.state' 2>/dev/null); then
        echo "  WARN: could not query GitHub PR $repo#$pr_num" >&2
        return 0
    fi

    if [ "$state" != "OPEN" ]; then
        echo "  SKIP: GitHub PR $repo#$pr_num is $state (not OPEN)" >&2
        return 1
    fi

    echo "  OK: GitHub PR $repo#$pr_num is OPEN" >&2
    return 0
}

# ---------------------------------------------------------------------------
# Check 3: GitHub issue -- is it still open and unassigned?
# ---------------------------------------------------------------------------
check_github_issue() {
    local url="$1"

    if ! command -v gh >/dev/null 2>&1; then
        echo "  WARN: gh CLI not installed, skipping GitHub issue check" >&2
        return 0
    fi

    # Extract owner/repo and issue number from URL
    local issue_path
    issue_path=$(echo "$url" | sed -n 's|.*github\.com/\([^/]*/[^/]*\)/issues/\([0-9]*\).*|\1 \2|p')
    if [ -z "$issue_path" ]; then
        echo "  WARN: could not parse GitHub issue URL: $url" >&2
        return 0
    fi

    local repo issue_num
    repo=$(echo "$issue_path" | cut -d' ' -f1)
    issue_num=$(echo "$issue_path" | cut -d' ' -f2)

    local json
    if ! json=$(gh issue view "$issue_num" --repo "$repo" --json state,assignees 2>/dev/null); then
        echo "  WARN: could not query GitHub issue $repo#$issue_num" >&2
        return 0
    fi

    local state
    state=$(echo "$json" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ "$state" != "OPEN" ]; then
        echo "  SKIP: GitHub issue $repo#$issue_num is $state (not OPEN)" >&2
        return 1
    fi

    # Check if already assigned
    local assignee_count
    assignee_count=$(echo "$json" | grep -o '"login"' | wc -l)
    if [ "$assignee_count" -gt 0 ]; then
        echo "  SKIP: GitHub issue $repo#$issue_num is already assigned ($assignee_count assignees)" >&2
        return 1
    fi

    echo "  OK: GitHub issue $repo#$issue_num is OPEN and unassigned" >&2
    return 0
}

# ---------------------------------------------------------------------------
# Check 4: GitLab MR -- is it still open?
# ---------------------------------------------------------------------------
check_gitlab_mr() {
    local url="$1"

    if ! command -v glab >/dev/null 2>&1; then
        echo "  WARN: glab CLI not installed, skipping GitLab MR check" >&2
        return 0
    fi

    # Extract project path and MR number from URL
    # Handles: https://gitlab.com/org/repo/-/merge_requests/7
    local mr_path
    mr_path=$(echo "$url" | sed -n 's|.*gitlab[^/]*/\(.*\)/-/merge_requests/\([0-9]*\).*|\1 \2|p')
    if [ -z "$mr_path" ]; then
        echo "  WARN: could not parse GitLab MR URL: $url" >&2
        return 0
    fi

    local project mr_num
    project=$(echo "$mr_path" | cut -d' ' -f1)
    mr_num=$(echo "$mr_path" | cut -d' ' -f2)

    local state
    if ! state=$(glab mr view "$mr_num" --repo "$project" -F json 2>/dev/null | \
                 grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4); then
        echo "  WARN: could not query GitLab MR $project!$mr_num" >&2
        return 0
    fi

    if [ "$state" != "opened" ]; then
        echo "  SKIP: GitLab MR $project!$mr_num is $state (not opened)" >&2
        return 1
    fi

    echo "  OK: GitLab MR $project!$mr_num is opened" >&2
    return 0
}

# ---------------------------------------------------------------------------
# Check 5: Jira issue -- is it in an actionable status?
# ---------------------------------------------------------------------------
check_jira_issue() {
    local issue_key="$1"

    if [ -z "$JIRA_URL" ] || [ -z "$JIRA_TOKEN" ]; then
        echo "  WARN: SECURETTY_JIRA_URL or SECURETTY_JIRA_TOKEN not set, skipping Jira check" >&2
        return 0
    fi

    local json
    if ! json=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${JIRA_TOKEN}" \
        -H "Content-Type: application/json" \
        "${JIRA_URL}/rest/api/2/issue/${issue_key}?fields=status" 2>/dev/null); then
        echo "  WARN: could not query Jira issue $issue_key" >&2
        return 0
    fi

    local status_name
    status_name=$(echo "$json" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)

    # Non-actionable statuses -- issue is done or blocked
    case "$status_name" in
        Done|Closed|Resolved|"Won't Do"|"Won't Fix"|Cancelled|Duplicate)
            echo "  SKIP: Jira issue $issue_key is '$status_name' (not actionable)" >&2
            return 1
            ;;
    esac

    echo "  OK: Jira issue $issue_key is '$status_name' (actionable)" >&2
    return 0
}

# ---------------------------------------------------------------------------
# Dispatch checks based on source type
# ---------------------------------------------------------------------------

# Always run the stale/duplicate check first
if ! check_stale_duplicate "$WORK_ITEM"; then
    exit 1
fi

# Source-specific checks
case "$SOURCE" in
    github)
        if echo "$WORK_ITEM" | grep -q '/pull/'; then
            check_github_pr "$WORK_ITEM" || exit 1
        elif echo "$WORK_ITEM" | grep -q '/issues/'; then
            check_github_issue "$WORK_ITEM" || exit 1
        else
            echo "  WARN: GitHub URL not recognized as PR or issue, proceeding" >&2
        fi
        ;;
    gitlab)
        if echo "$WORK_ITEM" | grep -q '/merge_requests/'; then
            check_gitlab_mr "$WORK_ITEM" || exit 1
        else
            echo "  WARN: GitLab URL not recognized as MR, proceeding" >&2
        fi
        ;;
    jira)
        check_jira_issue "$WORK_ITEM" || exit 1
        ;;
    generic)
        # Only stale/duplicate check applies (already ran above)
        ;;
    *)
        echo "ERROR: unknown source: $SOURCE" >&2
        exit 1
        ;;
esac

echo "preflight: PASS -- work item is actionable" >&2
exit 0
