#!/usr/bin/env bash
# tests/lib/test_common.sh — ESAD Integration Test Common Library
# Reusable across all phases, extendable as project grows

# NO set -e! We want tests to continue on failure

# ── Test Framework Constants ──
TEST_START_TIME=$(date +%s)
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ESAD_ROOT="$(cd "${TEST_ROOT}/.." && pwd)"
FIXTURE_DIR="${TEST_ROOT}/fixtures"
REPORT_DIR="${TEST_ROOT}/reports"

# Source ESAD common library
source "${ESAD_ROOT}/lib/esad_common.sh"

# Test tracking
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0
TEST_TOTAL=0

# ── Assertion Helpers ──
assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist}"
    if [[ -f "$file" ]]; then
        test_pass "$msg: $file"
    else
        test_fail "$msg: $file (not found)"
    fi
}

assert_file_not_empty() {
    local file="$1"
    local msg="${2:-File should not be empty}"
    if [[ -s "$file" ]]; then
        test_pass "$msg: $file"
    else
        test_fail "$msg: $file (empty or missing)"
    fi
}

assert_json_valid() {
    local file="$1"
    local msg="${2:-JSON should be valid}"
    if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
        test_pass "$msg"
    else
        test_fail "$msg: invalid JSON in $file"
    fi
}

assert_json_has_key() {
    local file="$1"
    local key="$2"
    local msg="${3:-JSON should have key}"
    if python3 -c "import json,sys; d=json.load(open('$file')); sys.exit(0 if '$key' in d else 1)"; then
        test_pass "$msg: $key"
    else
        test_fail "$msg: key '$key' not found in $file"
    fi
}

assert_json_value_ge() {
    local file="$1"
    local key="$2"
    local min="$3"
    local msg="${4:-Value should be >= threshold}"
    local actual
    actual=$(python3 -c "import json; print(json.load(open('$file')).get('$key', 0))" 2>/dev/null || echo "0")
    if (( $(echo "$actual >= $min" | bc -l) )); then
        test_pass "$msg: $key=$actual >= $min"
    else
        test_fail "$msg: $key=$actual < $min"
    fi
}

assert_json_value_le() {
    local file="$1"
    local key="$2"
    local max="$3"
    local msg="${4:-Value should be <= threshold}"
    local actual
    actual=$(python3 -c "import json; print(json.load(open('$file')).get('$key', 0))" 2>/dev/null || echo "0")
    if (( $(echo "$actual <= $max" | bc -l) )); then
        test_pass "$msg: $key=$actual <= $max"
    else
        test_fail "$msg: $key=$actual > $max"
    fi
}

assert_json_value_eq() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local msg="${4:-Value should equal expected}"
    local actual
    actual=$(python3 -c "import json; print(json.load(open('$file')).get('$key', ''))" 2>/dev/null || echo "")
    if [[ "$actual" == "$expected" ]]; then
        test_pass "$msg: $key=$actual"
    else
        test_fail "$msg: $key=$actual (expected: $expected)"
    fi
}

assert_command_succeeds() {
    local cmd="$1"
    local msg="${2:-Command should succeed}"
    if eval "$cmd" >/dev/null 2>&1; then
        test_pass "$msg"
    else
        test_fail "$msg: command failed"
    fi
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory should exist}"
    if [[ -d "$dir" ]]; then
        test_pass "$msg: $dir"
    else
        test_fail "$msg: $dir (not found)"
    fi
}

# ── Test Reporting ──
test_pass() {
    ((TEST_PASSED++))
    ((TEST_TOTAL++))
    echo -e "  ✅ PASS: $1" >&2
}

test_fail() {
    ((TEST_FAILED++))
    ((TEST_TOTAL++))
    echo -e "  ❌ FAIL: $1" >&2
}

test_skip() {
    ((TEST_SKIPPED++))
    ((TEST_TOTAL++))
    echo -e "  ⏭️  SKIP: $1" >&2
}

test_section() {
    echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo -e "🧪 $1" >&2
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
}

test_case() {
    echo -e "\n  📋 $1" >&2
}

# ── Fixture Management ──
setup_fixture_force() {
    local force_code="$1"
    local direction="$2"
    local confidence="$3"
    local extra="${4:-}"

    # Map force_code to file prefix (must match pipeline glob patterns)
    declare -A prefix_map=(
        ["F1"]="ipo_underwriter"
        ["F2"]="gamma_dealer"
        ["F3"]="quarter_end"
        ["F4"]="short_squeeze"
        ["F5a"]="fomc_vol"
        ["F5b"]="fed_balance_sheet"
        ["F5c"]="fomc_guidance"
        ["F6"]="index_rebalancing"
        ["F7"]="lockup_expiration"
        ["F8"]="etf_flows"
        ["F9"]="vix_term_structure"
    )

    local prefix="${prefix_map[$force_code]:-${force_code,,}}"
    local fixture_file="${FIXTURE_DIR}/${prefix}_${TODAY}.json"

    mkdir -p "$FIXTURE_DIR"
    python3 << PYEOF
import json
data = {
    'date': '$TODAY_ISO',
    'force_code': '$force_code',
    'force_name': 'Fixture_${force_code}',
    'direction': '$direction',
    'confidence': $confidence,
    'source_tag': 'fixture_${force_code,,}:$TODAY'
}
$extra
with open('$fixture_file', 'w') as f:
    json.dump(data, f, indent=2)
PYEOF
    echo "$fixture_file"
}

load_fixtures_to_cache() {
    # Copy fixtures to cache directory for pipeline testing
    if [[ -d "$FIXTURE_DIR" ]]; then
        cp "${FIXTURE_DIR}"/*.json "${CACHE_DIR}/" 2>/dev/null || true
        esad_log "Fixtures loaded to cache: $(ls -1 "${FIXTURE_DIR}"/*.json 2>/dev/null | wc -l) files"
    fi
}

clear_cache() {
    # Clear all force JSON files from cache
    if [[ -d "$CACHE_DIR" ]]; then
        find "$CACHE_DIR" -maxdepth 1 -name "*.json" -type f -delete 2>/dev/null || true
    fi
    esad_log "Cache cleared: $(find "$CACHE_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l) files remaining"
}

# ── Summary & Exit ──
print_test_summary() {
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - TEST_START_TIME))

    echo -e "\n" >&2
    echo -e "════════════════════════════════════════════" >&2
    echo -e "📊 ESAD INTEGRATION TEST SUMMARY" >&2
    echo -e "════════════════════════════════════════════" >&2
    echo -e "  Total Tests:    $TEST_TOTAL" >&2
    echo -e "  ✅ Passed:      $TEST_PASSED" >&2
    echo -e "  ❌ Failed:      $TEST_FAILED" >&2
    echo -e "  ⏭️  Skipped:    $TEST_SKIPPED" >&2
    echo -e "  ⏱️  Duration:   ${duration}s" >&2

    local pass_rate=0
    if [[ $TEST_TOTAL -gt 0 ]]; then
        pass_rate=$((TEST_PASSED * 100 / TEST_TOTAL))
    fi
    echo -e "  📈 Pass Rate:   ${pass_rate}%" >&2
    echo -e "════════════════════════════════════════════" >&2

    # Save JSON report
    local report_file="${REPORT_DIR}/test_report_${TODAY}.json"
    mkdir -p "$REPORT_DIR"
    python3 << PYEOF
import json
report = {
    'date': '$TODAY_ISO',
    'timestamp': $(date +%s),
    'duration_sec': $duration,
    'total': $TEST_TOTAL,
    'passed': $TEST_PASSED,
    'failed': $TEST_FAILED,
    'skipped': $TEST_SKIPPED,
    'pass_rate_pct': $pass_rate,
    'phase': 'Batch2_PrePhase1'
}
with open('$report_file', 'w') as f:
    json.dump(report, f, indent=2)
PYEOF
    echo -e "  📄 Report:      $report_file" >&2
    echo -e "════════════════════════════════════════════" >&2

    # Exit with failure count
    return $TEST_FAILED
}
