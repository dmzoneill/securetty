#!/bin/bash
# Classify the risk level of a git diff for graduated security tier routing.
# Outputs one word to stdout: high, medium, or low.
#
# Usage:
#   securetty-risk-classifier.sh <workdir>          # staged or last commit
#   securetty-risk-classifier.sh --diff <file>      # classify a specific diff file
#
# Risk patterns can be extended via SECURETTY_HIGH_RISK_PATTERNS (colon-separated
# glob patterns, e.g. "*/secrets/*:*.cert"). These are merged with the built-in
# high-risk patterns from roles/escalation/defaults/main.yml.
set -euo pipefail

# --- Built-in patterns --------------------------------------------------------
# Aligned with securetty_escalation.high_risk_patterns in
# roles/escalation/defaults/main.yml and extended for CI and container configs.

HIGH_RISK_PATTERNS=(
    "auth/"
    "security/"
    "crypto/"
    "\.key$"
    "\.pem$"
    "Dockerfile"
    "Containerfile"
    "\.github/workflows/"
    "\.gitlab-ci"
    "Jenkinsfile"
    "\.circleci/"
)

MEDIUM_RISK_PATTERNS=(
    "routes/"
    "api/"
    "endpoints/"
    "handlers/"
    "controllers/"
    "migrations/"
    "migrate/"
    "schema/"
    "\.env"
    "config/"
    "settings/"
    "\.yml$"
    "\.yaml$"
    "\.toml$"
    "\.ini$"
    "\.cfg$"
    "\.conf$"
)

LOW_RISK_PATTERNS=(
    "docs/"
    "doc/"
    "README"
    "CHANGELOG"
    "LICENSE"
    "\.md$"
    "\.txt$"
    "\.rst$"
    "test/"
    "tests/"
    "spec/"
    "__tests__/"
    "_test\."
    "_spec\."
    "\.test\."
    "\.spec\."
)

# --- Merge env-supplied high-risk patterns ------------------------------------
# The env var accepts glob-style patterns (e.g. "*/secrets/*:*.cert") for
# compatibility with securetty_escalation.high_risk_patterns in Ansible config.
# Convert globs to regex: * -> .*, ? -> .  ,  . -> \.
glob_to_regex() {
    local glob="$1"
    local regex=""
    local i char
    for (( i=0; i<${#glob}; i++ )); do
        char="${glob:$i:1}"
        case "$char" in
            '*') regex+=".*" ;;
            '?') regex+="." ;;
            '.') regex+="\\." ;;
            *) regex+="$char" ;;
        esac
    done
    printf '%s' "$regex"
}

if [[ -n "${SECURETTY_HIGH_RISK_PATTERNS:-}" ]]; then
    IFS=':' read -ra extra_patterns <<< "$SECURETTY_HIGH_RISK_PATTERNS"
    for pat in "${extra_patterns[@]}"; do
        if [[ -n "$pat" ]]; then
            HIGH_RISK_PATTERNS+=("$(glob_to_regex "$pat")")
        fi
    done
fi

# --- Helpers ------------------------------------------------------------------

usage() {
    printf 'Usage: %s <workdir>\n' "$(basename "$0")" >&2
    printf '       %s --diff <file>\n' "$(basename "$0")" >&2
    exit 1
}

# Given a list of changed file paths on stdin, count how many match each tier.
classify_paths() {
    local high=0 medium=0 low=0 total=0

    while IFS= read -r filepath; do
        [[ -z "$filepath" ]] && continue
        total=$((total + 1))

        local matched=0

        for pat in "${HIGH_RISK_PATTERNS[@]}"; do
            if [[ "$filepath" =~ $pat ]]; then
                high=$((high + 1))
                matched=1
                break
            fi
        done
        [[ $matched -eq 1 ]] && continue

        for pat in "${MEDIUM_RISK_PATTERNS[@]}"; do
            if [[ "$filepath" =~ $pat ]]; then
                medium=$((medium + 1))
                matched=1
                break
            fi
        done
        [[ $matched -eq 1 ]] && continue

        for pat in "${LOW_RISK_PATTERNS[@]}"; do
            if [[ "$filepath" =~ $pat ]]; then
                low=$((low + 1))
                matched=1
                break
            fi
        done

        # Unclassified files default to medium -- err on the side of caution.
        if [[ $matched -eq 0 ]]; then
            medium=$((medium + 1))
        fi
    done

    # Decision: any high-risk file promotes the entire diff to high.
    # If no high-risk files exist, majority rules between medium and low.
    # On tie or empty diff, default to medium.
    if [[ $high -gt 0 ]]; then
        printf 'high\n'
    elif [[ $total -eq 0 ]]; then
        printf 'low\n'
    elif [[ $medium -ge $low ]]; then
        printf 'medium\n'
    else
        printf 'low\n'
    fi
}

# Extract changed file paths from a unified diff (git diff output).
paths_from_diff() {
    grep -E '^\+\+\+ b/' | sed 's|^+++ b/||' || true
}

# --- Main ---------------------------------------------------------------------

main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    # Mode: classify a specific diff file
    if [[ "$1" == "--diff" ]]; then
        local diff_file="${2:?--diff requires a file argument}"
        if [[ ! -f "$diff_file" ]]; then
            printf 'error: diff file not found: %s\n' "$diff_file" >&2
            exit 1
        fi
        paths_from_diff < "$diff_file" | classify_paths
        return
    fi

    # Mode: classify from workdir git state
    local workdir="$1"
    if [[ ! -d "$workdir" ]]; then
        printf 'error: workdir not found: %s\n' "$workdir" >&2
        exit 1
    fi

    local changed_files
    changed_files=$(
        # Try staged changes first; fall back to last commit
        git -C "$workdir" diff --cached --name-only 2>/dev/null \
        || git -C "$workdir" diff HEAD~1 --name-only 2>/dev/null \
        || true
    )

    if [[ -z "$changed_files" ]]; then
        # No changes detected -- safe to assume low risk
        printf 'low\n'
        return
    fi

    printf '%s\n' "$changed_files" | classify_paths
}

main "$@"
