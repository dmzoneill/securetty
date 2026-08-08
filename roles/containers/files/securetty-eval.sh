#!/bin/bash
# securetty-eval.sh — evaluation runner for promptfoo-based quality benchmarks.
# Runs LLM-as-judge and deterministic assertion evals against securetty MCP
# skills and instruction files.
#
# Usage:
#   securetty-eval.sh run [config]        Run evals (default: all configs in evals/)
#   securetty-eval.sh list                List available eval configs
#   securetty-eval.sh report              Show last eval results summary
#
# Options:
#   --threshold <0.0-1.0>   Minimum pass rate (default: 0.8)
#   --output-dir <path>     Override results directory
#   --json                  Machine-readable JSON output for report
#   --help                  Show this help
set -euo pipefail

SECURETTY_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALS_DIR="${SECURETTY_DIR}/evals"
RESULTS_BASE="${HOME}/.securetty/evals"
THRESHOLD=0.8
JSON_OUTPUT=0
OUTPUT_DIR=""
PROMPTFOO_CMD="npx promptfoo@latest"

# =============================================================================
# Usage
# =============================================================================

usage() {
    cat <<'USAGE'
securetty-eval.sh — evaluation runner for promptfoo-based quality benchmarks

Usage:
  securetty-eval.sh run [config]        Run evals (default: all configs in evals/)
  securetty-eval.sh list                List available eval configs
  securetty-eval.sh report              Show last eval results summary

Options:
  --threshold <0.0-1.0>   Minimum pass rate (default: 0.8)
  --output-dir <path>     Override results directory
  --json                  Machine-readable JSON output for report
  --help                  Show this help

Examples:
  securetty-eval.sh run                          # Run all eval configs
  securetty-eval.sh run evals/skill-quality.yaml # Run a specific config
  securetty-eval.sh run --threshold 0.9          # Stricter pass rate
  securetty-eval.sh report --json                # Last results as JSON
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

ensure_evals_dir() {
    if [[ ! -d "$EVALS_DIR" ]]; then
        log_error "Evals directory not found: $EVALS_DIR"
        exit 1
    fi
}

get_results_dir() {
    local date_dir
    date_dir=$(date +%Y-%m-%d)
    local dir="${OUTPUT_DIR:-${RESULTS_BASE}/${date_dir}}"
    mkdir -p "$dir"
    echo "$dir"
}

find_latest_results_dir() {
    if [[ ! -d "$RESULTS_BASE" ]]; then
        log_error "No eval results found. Run 'securetty-eval.sh run' first."
        exit 1
    fi
    local latest
    latest=$(find "$RESULTS_BASE" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)
    if [[ -z "$latest" ]]; then
        log_error "No eval results found in $RESULTS_BASE"
        exit 1
    fi
    echo "$latest"
}

find_configs() {
    local config="$1"
    if [[ -n "$config" ]]; then
        if [[ -f "$config" ]]; then
            echo "$config"
        elif [[ -f "${EVALS_DIR}/${config}" ]]; then
            echo "${EVALS_DIR}/${config}"
        else
            log_error "Config not found: $config"
            exit 1
        fi
    else
        # All YAML files in evals/ except promptfooconfig.yaml (infrastructure tests)
        find "$EVALS_DIR" -maxdepth 1 -name "*.yaml" -o -name "*.yml" | \
            grep -v promptfooconfig.yaml | sort
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
    ensure_evals_dir
    log_info "Available eval configs in ${EVALS_DIR}:"
    echo ""
    local count=0
    while IFS= read -r config; do
        local name
        name=$(basename "$config")
        local desc
        desc=$(grep -m1 '^description:' "$config" 2>/dev/null | sed 's/^description: *//' || echo "(no description)")
        printf "  %-30s %s\n" "$name" "$desc"
        count=$((count + 1))
    done < <(find "$EVALS_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) | sort)
    echo ""
    echo "Total: ${count} config(s)"
}

cmd_run() {
    local config_arg="$1"
    ensure_evals_dir

    local results_dir
    results_dir=$(get_results_dir)
    local run_timestamp
    run_timestamp=$(date +%Y-%m-%dT%H:%M:%S)

    local configs
    configs=$(find_configs "$config_arg")

    if [[ -z "$configs" ]]; then
        log_error "No eval configs found"
        exit 1
    fi

    local total_pass=0
    local total_fail=0
    local total_tests=0
    local failed_configs=()
    local summary_file="${results_dir}/summary.json"

    log_info "Eval run started at ${run_timestamp}"
    log_info "Results directory: ${results_dir}"
    log_info "Pass threshold: ${THRESHOLD}"
    echo ""

    while IFS= read -r config; do
        local config_name
        config_name=$(basename "$config" .yaml)
        config_name=$(basename "$config_name" .yml)
        local output_file="${results_dir}/${config_name}.json"

        log_info "Running: ${config_name}"

        # Run promptfoo eval and capture output
        local eval_exit=0
        $PROMPTFOO_CMD eval \
            --config "$config" \
            --output "$output_file" \
            --no-cache \
            2>&1 | while IFS= read -r line; do echo "  $line"; done || eval_exit=$?

        if [[ $eval_exit -ne 0 ]]; then
            log_error "Eval failed for ${config_name} (exit code: ${eval_exit})"
            failed_configs+=("$config_name")
            continue
        fi

        # Parse results from output file
        if [[ -f "$output_file" ]]; then
            local pass fail total
            pass=$(python3 -c "
import json, sys
try:
    data = json.load(open('$output_file'))
    results = data.get('results', data.get('evalResults', []))
    if isinstance(results, dict):
        results = results.get('results', [])
    passed = sum(1 for r in results if r.get('success', False))
    print(passed)
except Exception:
    print(0)
" 2>/dev/null || echo "0")
            total=$(python3 -c "
import json, sys
try:
    data = json.load(open('$output_file'))
    results = data.get('results', data.get('evalResults', []))
    if isinstance(results, dict):
        results = results.get('results', [])
    print(len(results))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
            fail=$((total - pass))

            total_pass=$((total_pass + pass))
            total_fail=$((total_fail + fail))
            total_tests=$((total_tests + total))

            local rate="0.0"
            if [[ $total -gt 0 ]]; then
                rate=$(python3 -c "print(f'{${pass}/${total}*100:.1f}')" 2>/dev/null || echo "0.0")
            fi
            echo "  Results: ${pass}/${total} passed (${rate}%)"

            # Check per-config threshold
            local pass_rate
            pass_rate=$(python3 -c "print(${pass}/${total} if ${total} > 0 else 0)" 2>/dev/null || echo "0")
            local below
            below=$(python3 -c "print('yes' if ${pass_rate} < ${THRESHOLD} else 'no')" 2>/dev/null || echo "no")
            if [[ "$below" == "yes" ]]; then
                failed_configs+=("$config_name")
                echo "  BELOW THRESHOLD (${rate}% < $(python3 -c "print(f'{${THRESHOLD}*100:.0f}')")%)"
            fi
        fi
        echo ""
    done <<< "$configs"

    # Write summary
    local overall_rate
    overall_rate=$(python3 -c "print(${total_pass}/${total_tests} if ${total_tests} > 0 else 0)" 2>/dev/null || echo "0")
    local overall_pct
    overall_pct=$(python3 -c "print(f'{${total_pass}/${total_tests}*100:.1f}' if ${total_tests} > 0 else '0.0')" 2>/dev/null || echo "0.0")

    python3 -c "
import json
summary = {
    'timestamp': '${run_timestamp}',
    'threshold': ${THRESHOLD},
    'total_tests': ${total_tests},
    'passed': ${total_pass},
    'failed': ${total_fail},
    'pass_rate': round(${total_pass}/${total_tests}, 4) if ${total_tests} > 0 else 0,
    'below_threshold': $(python3 -c "print('True' if ${overall_rate} < ${THRESHOLD} else 'False')" 2>/dev/null || echo "False"),
    'failed_configs': $(python3 -c "import json; print(json.dumps('${failed_configs[*]:-}'.split() if '${failed_configs[*]:-}' else []))" 2>/dev/null || echo "[]"),
    'results_dir': '${results_dir}',
}
with open('${summary_file}', 'w') as f:
    json.dump(summary, f, indent=2)
" 2>/dev/null

    # Print summary
    echo "================================================================"
    echo "Eval Summary"
    echo "================================================================"
    echo "Total tests:   ${total_tests}"
    echo "Passed:        ${total_pass}"
    echo "Failed:        ${total_fail}"
    echo "Pass rate:     ${overall_pct}%"
    echo "Threshold:     $(python3 -c "print(f'{${THRESHOLD}*100:.0f}')")%"
    echo "Results:       ${results_dir}"

    if [[ ${#failed_configs[@]} -gt 0 ]]; then
        echo ""
        echo "Configs below threshold:"
        for fc in "${failed_configs[@]}"; do
            echo "  - ${fc}"
        done
    fi
    echo "================================================================"

    # Exit code for CI gates
    local gate_fail
    gate_fail=$(python3 -c "print(1 if ${overall_rate} < ${THRESHOLD} else 0)" 2>/dev/null || echo "0")
    if [[ "$gate_fail" == "1" ]]; then
        log_error "Pass rate ${overall_pct}% is below threshold $(python3 -c "print(f'{${THRESHOLD}*100:.0f}')")%"
        exit 1
    fi
}

cmd_report() {
    local results_dir
    results_dir=$(find_latest_results_dir)
    local summary_file="${results_dir}/summary.json"

    if [[ ! -f "$summary_file" ]]; then
        log_error "No summary found in ${results_dir}"
        exit 1
    fi

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        cat "$summary_file"
        return
    fi

    python3 -c "
import json

with open('${summary_file}') as f:
    s = json.load(f)

print('=' * 60)
print('Last Eval Report')
print('=' * 60)
print(f'Run:           {s[\"timestamp\"]}')
print(f'Total tests:   {s[\"total_tests\"]}')
print(f'Passed:        {s[\"passed\"]}')
print(f'Failed:        {s[\"failed\"]}')
print(f'Pass rate:     {s[\"pass_rate\"]*100:.1f}%')
print(f'Threshold:     {s[\"threshold\"]*100:.0f}%')
print(f'Status:        {\"FAIL\" if s[\"below_threshold\"] else \"PASS\"}')
print(f'Results dir:   {s[\"results_dir\"]}')

if s.get('failed_configs'):
    print()
    print('Configs below threshold:')
    for fc in s['failed_configs']:
        print(f'  - {fc}')

print('=' * 60)

# Show per-config results if available
import os, glob
result_files = sorted(glob.glob(os.path.join(s['results_dir'], '*.json')))
for rf in result_files:
    if rf.endswith('summary.json'):
        continue
    name = os.path.basename(rf).replace('.json', '')
    try:
        with open(rf) as cf:
            data = json.load(cf)
        results = data.get('results', data.get('evalResults', []))
        if isinstance(results, dict):
            results = results.get('results', [])
        total = len(results)
        passed = sum(1 for r in results if r.get('success', False))
        rate = passed / total * 100 if total > 0 else 0
        print(f'  {name:<30} {passed}/{total} ({rate:.1f}%)')
    except Exception:
        print(f'  {name:<30} (error reading results)')
print()
" 2>/dev/null
}

# =============================================================================
# Argument parsing
# =============================================================================

COMMAND=""
CONFIG_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        run|list|report)
            COMMAND="$1"
            shift
            # Capture optional config arg for run
            if [[ "$COMMAND" == "run" && $# -gt 0 && ! "$1" =~ ^-- ]]; then
                CONFIG_ARG="$1"
                shift
            fi
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=1
            shift
            ;;
        --help|-h)
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
    run)    cmd_run "$CONFIG_ARG" ;;
    list)   cmd_list ;;
    report) cmd_report ;;
esac
