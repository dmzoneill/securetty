#!/bin/bash
# securetty-adoption-metrics.sh — adoption tracking dashboard for external metrics.
# Pulls GitHub repository stats via gh api, counts installed skills, and
# identifies external contributors from the git log.
#
# Usage:
#   securetty-adoption-metrics.sh metrics              GitHub repo dashboard
#   securetty-adoption-metrics.sh skills               Skill install counts
#   securetty-adoption-metrics.sh contributions         External contributor list
#
# Options:
#   --json          Machine-readable JSON output
#   --repo OWNER/REPO   Override repository (default: dmzoneill/securetty)
#   --help          Show this help
set -euo pipefail

REPO="${SECURETTY_REPO:-dmzoneill/securetty}"
JSON_OUTPUT=0
BUILTIN_DIR="$HOME/src/agent-mcp-skills"
USER_DIR="$HOME/.securetty/skills"
OWNER="dmzoneill"

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat <<'USAGE'
securetty-adoption-metrics.sh -- adoption tracking dashboard

Usage:
  securetty-adoption-metrics.sh metrics              GitHub repo dashboard
  securetty-adoption-metrics.sh skills               Skill install counts
  securetty-adoption-metrics.sh contributions         External contributor list

Options:
  --json              Machine-readable JSON output
  --repo OWNER/REPO   Override repository (default: dmzoneill/securetty)
  --help              Show this help

Environment:
  SECURETTY_REPO      Override default repository (OWNER/REPO)

Examples:
  securetty-adoption-metrics.sh metrics
  securetty-adoption-metrics.sh metrics --json
  securetty-adoption-metrics.sh skills --json
  securetty-adoption-metrics.sh contributions
USAGE
    exit 0
}

# =============================================================================
# Helpers
# =============================================================================

log_info() {
    echo "==> $*"
}

log_error() {
    echo "ERROR: $*" >&2
}

require_gh() {
    if ! command -v gh &>/dev/null; then
        log_error "gh CLI is required but not found. Install from https://cli.github.com/"
        exit 1
    fi
    if ! gh auth status &>/dev/null 2>&1; then
        log_error "gh is not authenticated. Run 'gh auth login' first."
        exit 1
    fi
}

require_git() {
    if ! command -v git &>/dev/null; then
        log_error "git is required but not found."
        exit 1
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_metrics() {
    require_gh

    local repo_json
    repo_json=$(gh api "repos/${REPO}" 2>/dev/null) || {
        log_error "Failed to fetch repository data for ${REPO}"
        exit 1
    }

    local stars forks open_issues watchers
    stars=$(printf '%s' "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('stargazers_count', 0))" 2>/dev/null)
    forks=$(printf '%s' "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('forks_count', 0))" 2>/dev/null)
    open_issues=$(printf '%s' "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('open_issues_count', 0))" 2>/dev/null)
    watchers=$(printf '%s' "$repo_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('subscribers_count', 0))" 2>/dev/null)

    # Clone traffic (requires push access)
    local clones_total=0 clones_unique=0
    local clones_json
    clones_json=$(gh api "repos/${REPO}/traffic/clones" 2>/dev/null) && {
        clones_total=$(printf '%s' "$clones_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count', 0))" 2>/dev/null || echo 0)
        clones_unique=$(printf '%s' "$clones_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('uniques', 0))" 2>/dev/null || echo 0)
    }

    # Contributors count
    local contributors=0
    local contrib_json
    contrib_json=$(gh api "repos/${REPO}/contributors?per_page=1&anon=true" --include 2>/dev/null) && {
        # Parse Link header for last page number to get total count
        local last_page
        last_page=$(printf '%s' "$contrib_json" | grep -i '^link:' | grep -oP '&page=\K[0-9]+(?=>; rel="last")' 2>/dev/null || echo "")
        if [[ -n "$last_page" ]]; then
            contributors="$last_page"
        else
            # No pagination, count from the single response (body after headers)
            contributors=$(gh api "repos/${REPO}/contributors?per_page=100&anon=true" 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        fi
    }

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        python3 -c "
import json
data = {
    'repository': '${REPO}',
    'stars': ${stars:-0},
    'forks': ${forks:-0},
    'open_issues': ${open_issues:-0},
    'watchers': ${watchers:-0},
    'clones_total_14d': ${clones_total},
    'clones_unique_14d': ${clones_unique},
    'contributors': ${contributors:-0},
}
print(json.dumps(data, indent=2))
"
        return
    fi

    echo "================================================================"
    echo "securetty Adoption Dashboard"
    echo "================================================================"
    echo "Repository:     ${REPO}"
    echo ""
    printf "  %-24s %s\n" "Stars:" "${stars:-0}"
    printf "  %-24s %s\n" "Forks:" "${forks:-0}"
    printf "  %-24s %s\n" "Open issues:" "${open_issues:-0}"
    printf "  %-24s %s\n" "Watchers:" "${watchers:-0}"
    printf "  %-24s %s\n" "Contributors:" "${contributors:-0}"
    echo ""
    echo "Clone traffic (last 14 days):"
    printf "  %-24s %s\n" "Total clones:" "${clones_total}"
    printf "  %-24s %s\n" "Unique cloners:" "${clones_unique}"
    echo "================================================================"
}

cmd_skills() {
    local builtin_count=0
    local user_count=0
    local builtin_names=()
    local user_names=()

    if [[ -d "$BUILTIN_DIR" ]]; then
        for d in "$BUILTIN_DIR"/*/; do
            if [[ -f "${d}SKILL.md" ]]; then
                builtin_count=$((builtin_count + 1))
                builtin_names+=("$(basename "${d%/}")")
            fi
        done
    fi

    if [[ -d "$USER_DIR" ]]; then
        for d in "$USER_DIR"/*/; do
            if [[ -f "${d}SKILL.md" ]]; then
                user_count=$((user_count + 1))
                user_names+=("$(basename "${d%/}")")
            fi
        done
    fi

    local total=$((builtin_count + user_count))

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        python3 -c "
import json
data = {
    'total_skills': ${total},
    'builtin_count': ${builtin_count},
    'user_installed_count': ${user_count},
    'builtin_skills': $(python3 -c "import json; print(json.dumps('${builtin_names[*]:-}'.split() if '${builtin_names[*]:-}' else []))" 2>/dev/null),
    'user_installed_skills': $(python3 -c "import json; print(json.dumps('${user_names[*]:-}'.split() if '${user_names[*]:-}' else []))" 2>/dev/null),
    'builtin_path': '${BUILTIN_DIR}',
    'user_path': '${USER_DIR}',
}
print(json.dumps(data, indent=2))
"
        return
    fi

    echo "================================================================"
    echo "securetty Skill Inventory"
    echo "================================================================"
    echo ""
    printf "  %-24s %s\n" "Total skills:" "$total"
    printf "  %-24s %s\n" "Built-in:" "$builtin_count"
    printf "  %-24s %s\n" "User-installed:" "$user_count"
    echo ""

    if [[ $builtin_count -gt 0 ]]; then
        echo "Built-in skills ($BUILTIN_DIR):"
        for name in "${builtin_names[@]}"; do
            echo "  - $name"
        done
        echo ""
    fi

    if [[ $user_count -gt 0 ]]; then
        echo "User-installed skills ($USER_DIR):"
        for name in "${user_names[@]}"; do
            echo "  - $name"
        done
        echo ""
    fi

    if [[ $total -eq 0 ]]; then
        echo "No skills found."
        echo "Built-in path:  $BUILTIN_DIR"
        echo "User path:      $USER_DIR"
    fi

    echo "================================================================"
}

cmd_contributions() {
    require_git

    # Find the git repo root; fall back to known location
    local repo_dir
    repo_dir=$(git rev-parse --show-toplevel 2>/dev/null) || repo_dir="$HOME/src/securetty"

    if [[ ! -d "${repo_dir}/.git" ]]; then
        log_error "Not a git repository: ${repo_dir}"
        exit 1
    fi

    # Get the repo owner email/name patterns to identify as "owner"
    local owner_pattern="$OWNER"

    # Collect all unique contributors, excluding the owner
    local contributors_raw
    contributors_raw=$(git -C "$repo_dir" log --format='%aN|%aE' | sort -u)

    local external_contributors=()
    local external_details=()

    while IFS='|' read -r name email; do
        [[ -z "$name" ]] && continue
        # Check if this contributor matches the owner pattern (case-insensitive)
        local name_lower email_lower owner_lower
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]')
        owner_lower=$(echo "$owner_pattern" | tr '[:upper:]' '[:lower:]')

        if [[ "$name_lower" != *"$owner_lower"* && "$email_lower" != *"$owner_lower"* ]]; then
            # Count commits by this contributor
            local commit_count
            commit_count=$(git -C "$repo_dir" log --author="$email" --oneline 2>/dev/null | wc -l)
            external_contributors+=("$name")
            external_details+=("${name}|${email}|${commit_count}")
        fi
    done <<< "$contributors_raw"

    local ext_count=${#external_contributors[@]}

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        python3 -c "
import json, sys

details = '''$(printf '%s\n' "${external_details[@]+"${external_details[@]}"}")'''.strip().split('\n')
contributors = []
for line in details:
    if not line:
        continue
    parts = line.split('|')
    if len(parts) >= 3:
        contributors.append({
            'name': parts[0],
            'email': parts[1],
            'commits': int(parts[2]),
        })

data = {
    'repository': '${repo_dir}',
    'owner': '${OWNER}',
    'external_contributor_count': len(contributors),
    'external_contributors': sorted(contributors, key=lambda c: c['commits'], reverse=True),
}
print(json.dumps(data, indent=2))
"
        return
    fi

    echo "================================================================"
    echo "External Contributors"
    echo "================================================================"
    echo "Repository:     ${repo_dir}"
    echo "Owner filter:   ${OWNER}"
    echo "External count: ${ext_count}"
    echo ""

    if [[ $ext_count -gt 0 ]]; then
        printf "  %-30s %-35s %s\n" "NAME" "EMAIL" "COMMITS"
        printf "  %-30s %-35s %s\n" "----" "-----" "-------"
        for detail in "${external_details[@]}"; do
            IFS='|' read -r name email commits <<< "$detail"
            printf "  %-30s %-35s %s\n" "$name" "$email" "$commits"
        done
    else
        echo "  No external contributors found."
    fi

    echo ""
    echo "================================================================"
}

# =============================================================================
# Argument parsing
# =============================================================================

COMMAND=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        metrics|skills|contributions)
            COMMAND="$1"
            shift
            ;;
        --json)
            JSON_OUTPUT=1
            shift
            ;;
        --repo)
            REPO="${2:?--repo requires OWNER/REPO value}"
            OWNER="${REPO%%/*}"
            shift 2
            ;;
        --help|-h|help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
    esac
done

if [[ -z "$COMMAND" ]]; then
    log_error "No command specified"
    echo ""
    usage
fi

case "$COMMAND" in
    metrics)        cmd_metrics ;;
    skills)         cmd_skills ;;
    contributions)  cmd_contributions ;;
esac
