#!/usr/bin/env bash
# tests/unit/test_infrastructure.sh — Unit Tests for C2 Infrastructure
# Phase: Batch 2 (extendable to future phases)

set +euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_DIR}/../lib/test_common.sh"
# No set -e — we want to continue running tests on failure

test_section "C2 Infrastructure Unit Tests"

# ── Test 1: Directory Structure ──
test_case "Directory structure verification"
assert_dir_exists "${ESAD_ROOT}/scripts"
assert_dir_exists "${ESAD_ROOT}/lib"
assert_dir_exists "${ESAD_ROOT}/config"
assert_dir_exists "${ESAD_ROOT}/data"
assert_dir_exists "${ESAD_ROOT}/docs"
assert_dir_exists "${ESAD_ROOT}/tests"

# ── Test 2: Script Existence ──
test_case "Script file existence"
assert_file_exists "${ESAD_ROOT}/lib/esad_common.sh"
assert_file_exists "${ESAD_ROOT}/scripts/init_databases.sh"
assert_file_exists "${ESAD_ROOT}/scripts/09_compute_structural_forces.sh"
assert_file_exists "${ESAD_ROOT}/scripts/12_fetch_etf_flows.sh"
assert_file_exists "${ESAD_ROOT}/scripts/13_fetch_vix_term_structure.sh"
assert_file_exists "${ESAD_ROOT}/scripts/14_fetch_fed_balance_sheet.sh"
assert_file_exists "${ESAD_ROOT}/scripts/15_fetch_fomc_guidance.sh"

# ── Test 3: Script Executability ──
test_case "Script executability"
for script in \
    "${ESAD_ROOT}/scripts/init_databases.sh" \
    "${ESAD_ROOT}/scripts/09_compute_structural_forces.sh" \
    "${ESAD_ROOT}/scripts/12_fetch_etf_flows.sh" \
    "${ESAD_ROOT}/scripts/13_fetch_vix_term_structure.sh" \
    "${ESAD_ROOT}/scripts/14_fetch_fed_balance_sheet.sh" \
    "${ESAD_ROOT}/scripts/15_fetch_fomc_guidance.sh"
do
    if [[ -x "$script" ]]; then
        test_pass "Executable: $(basename "$script")"
    else
        test_fail "Not executable: $(basename "$script")"
    fi
done

# ── Test 4: Bash Syntax Validation ──
test_case "Bash syntax validation"
for script in \
    "${ESAD_ROOT}/lib/esad_common.sh" \
    "${ESAD_ROOT}/scripts/init_databases.sh" \
    "${ESAD_ROOT}/scripts/09_compute_structural_forces.sh" \
    "${ESAD_ROOT}/scripts/12_fetch_etf_flows.sh" \
    "${ESAD_ROOT}/scripts/13_fetch_vix_term_structure.sh" \
    "${ESAD_ROOT}/scripts/14_fetch_fed_balance_sheet.sh" \
    "${ESAD_ROOT}/scripts/15_fetch_fomc_guidance.sh"
do
    if bash -n "$script" 2>/dev/null; then
        test_pass "Syntax OK: $(basename "$script")"
    else
        test_fail "Syntax ERROR: $(basename "$script")"
    fi
done

# ── Test 5: Config Files ──
test_case "Configuration files"
assert_file_exists "${ESAD_ROOT}/config/force_priority.json"
assert_file_exists "${ESAD_ROOT}/config/etf_sector_map.json"
assert_json_valid "${ESAD_ROOT}/config/force_priority.json"
assert_json_valid "${ESAD_ROOT}/config/etf_sector_map.json"

# ── Test 6: esad_common.sh Smoke Test ──
test_case "esad_common.sh smoke test"
if (source "${ESAD_ROOT}/lib/esad_common.sh" && [[ -n "$TODAY" && -n "$CACHE_DIR" ]]); then
    test_pass "Library loads correctly, variables initialized"
else
    test_fail "Library load failed"
fi

# ── Test 7: Database Initialization ──
test_case "Database initialization (dry run)"
# Check that init script can be sourced without errors
if bash "${ESAD_ROOT}/scripts/init_databases.sh" 2>&1 | grep -q "OK"; then
    test_pass "init_databases.sh runs and creates databases"
else
    test_fail "init_databases.sh may have issues"
fi
assert_file_exists "${DATA_DIR}/events.db"
assert_file_exists "${DATA_DIR}/signals.db"
assert_file_exists "${DATA_DIR}/event_signal_mapping.db"

print_test_summary
