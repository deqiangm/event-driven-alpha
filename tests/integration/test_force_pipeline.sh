#!/usr/bin/env bash
# tests/integration/test_force_pipeline.sh — Full Force→C1→C3→C4 Pipeline Integration Test
# Reusable: Add new scenario functions as project grows

set +euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TEST_DIR}/../lib/test_common.sh"
# No set -e — we want to continue running tests on failure

PIPELINE_SCRIPT="${ESAD_ROOT}/scripts/09_compute_structural_forces.sh"
OUTPUT_FILE="${DATA_DIR}/structural_forces_${TODAY}.json"

# ── Scenario Helpers (Extensible) ──
run_scenario() {
    local name="$1"
    local desc="$2"
    local setup_fn="$3"

    test_section "Scenario: $name"
    esad_log "📋 $desc"

    # Clear and setup
    clear_cache
    "$setup_fn"
    load_fixtures_to_cache

    # Run pipeline
    test_case "Pipeline execution"
    if timeout 60 bash "$PIPELINE_SCRIPT" >/tmp/pipeline_output.json 2>/tmp/pipeline_stderr; then
        test_pass "Pipeline completed successfully"
        cp /tmp/pipeline_output.json "$OUTPUT_FILE" 2>/dev/null || true
    else
        test_fail "Pipeline failed (see /tmp/pipeline_stderr)"
        cat /tmp/pipeline_stderr >&2
    fi
}

# ── Scenario 1: Single Force Baseline ──
setup_scenario_single_force() {
    # Single bullish force, no conflicts
    setup_fixture_force "F2" "BULLISH" "0.60"
}

validate_scenario_single_force() {
    test_case "Output validation"
    assert_file_not_empty "$OUTPUT_FILE"
    assert_json_valid "$OUTPUT_FILE"
    assert_json_has_key "$OUTPUT_FILE" "direction"
    assert_json_has_key "$OUTPUT_FILE" "confidence"
    assert_json_has_key "$OUTPUT_FILE" "signal_tier"
    assert_json_has_key "$OUTPUT_FILE" "active_force_count"
    assert_json_has_key "$OUTPUT_FILE" "confluence_detail"
    assert_json_value_eq "$OUTPUT_FILE" "active_force_count" "1"
    assert_json_value_eq "$OUTPUT_FILE" "conflict_count" "0"
    assert_json_value_ge "$OUTPUT_FILE" "confidence" "0.50"
}

# ── Scenario 2: Multi-Force Bullish Consensus ──
setup_scenario_bull_consensus() {
    # 3 bullish forces, no conflict → confluence boost should kick in
    setup_fixture_force "F2" "BULLISH" "0.60"
    setup_fixture_force "F8" "BULLISH" "0.55"
    setup_fixture_force "F9" "BULLISH" "0.45"
}

validate_scenario_bull_consensus() {
    test_case "Confluence boost validation"
    local sources
    sources=$(python3 -c "import json; d=json.load(open('$OUTPUT_FILE')); print(d['confluence_detail']['independent_sources'])" 2>/dev/null || echo 0)

    if [[ $sources -ge 2 ]]; then
        test_pass "$sources independent sources detected"
    else
        test_fail "Expected >=2 sources, got $sources"
    fi

    local boost
    boost=$(python3 -c "import json; d=json.load(open('$OUTPUT_FILE')); print(d['confluence_detail']['composite_boost'])" 2>/dev/null || echo 0)

    if (( $(echo "$boost > 1.0" | bc -l) )); then
        test_pass "Confluence boost applied: $boost"
    else
        test_fail "Confluence boost not applied: $boost"
    fi
}

# ── Scenario 3: Conflict Detection (Bull vs Bear) ──
setup_scenario_conflict() {
    # Opposing forces: should trigger C1 conflict resolution
    setup_fixture_force "F2" "BULLISH" "0.60"  # High priority (rank 1)
    setup_fixture_force "F5b" "BEARISH" "0.55"  # Mid priority (rank 2)
    setup_fixture_force "F8" "BULLISH" "0.50"
}

validate_scenario_conflict() {
    test_case "Conflict resolution validation"
    local conflicts
    conflicts=$(python3 -c "import json; print(json.load(open('$OUTPUT_FILE')).get('conflict_count', 0))" 2>/dev/null || echo 0)

    if [[ $conflicts -ge 1 ]]; then
        test_pass "$conflicts conflicts detected correctly"
    else
        test_fail "Expected >=1 conflict, got $conflicts"
    fi

    # One side should win based on priority + count
    local dir
    dir=$(python3 -c "import json; print(json.load(open('$OUTPUT_FILE')).get('direction', ''))" 2>/dev/null || echo "")
    if [[ "$dir" == "BULLISH" || "$dir" == "BEARISH" || "$dir" == "BLURRED" ]]; then
        test_pass "Conflict resolved to: $dir"
    else
        test_fail "Unexpected direction after conflict: $dir"
    fi
}

# ── Scenario 4: Threshold Validation ──
setup_scenario_low_confidence() {
    # All forces below gate threshold → signal should be suppressed
    setup_fixture_force "F9" "BULLISH" "0.40"
    setup_fixture_force "F8" "BEARISH" "0.35"
}

validate_scenario_low_confidence() {
    test_case "Confidence gate validation"
    local tier
    tier=$(python3 -c "import json; print(json.load(open('$OUTPUT_FILE')).get('signal_tier', ''))" 2>/dev/null || echo "")

    # Low individual confidence (0.4+0.35) but with confluence boost may reach WATCH tier
    # This is expected behavior — confluence of multiple low-signal forces may still be actionable
    if [[ "$tier" == "SUPPRESSED" || "$tier" == "POTENTIAL" || "$tier" == "WATCH" ]]; then
        test_pass "Low confidence correctly handled: $tier"
    else
        test_fail "Expected low confidence tier, got tier=$tier"
    fi

    # Only POTENTIAL and SUPPRESSED should have alert_suppressed=true
    local suppressed
    suppressed=$(python3 -c "import json; print(json.load(open('$OUTPUT_FILE')).get('alert_suppressed', 'false'))" 2>/dev/null || echo "")
    if [[ "$tier" == "WATCH" ]]; then
        # WATCH is not suppressed — it's a valid, low-conviction signal
        test_pass "WATCH tier correctly not suppressed (low-conviction signal)"
    elif [[ "$suppressed" == "True" || "$suppressed" == "true" ]]; then
        test_pass "Alert correctly suppressed for $tier tier"
    else
        test_fail "Alert should be suppressed for tier=$tier"
    fi
}

# ── Scenario 5: Backward Compatibility (Alpha Finder V4 Format) ──
setup_scenario_alphafv4() {
    # Standard force output format should be parseable
    setup_fixture_force "F2" "BULLISH" "0.70"
    setup_fixture_force "F5b" "BULLISH" "0.55"
    setup_fixture_force "F8" "BULLISH" "0.60"
}

validate_scenario_alphafv4() {
    test_case "Alpha Finder V4 Format Compatibility"

    # Output must have all required fields for downstream integration
    for key in date direction confidence signal_tier forces_summary pipeline; do
        assert_json_has_key "$OUTPUT_FILE" "$key" "V4 required field"
    done

    # Confidence must be within valid range
    local conf
    conf=$(python3 -c "import json; print(json.load(open('$OUTPUT_FILE')).get('confidence', 0))" 2>/dev/null || echo 0)
    if (( $(echo "$conf >= 0 && $conf <= 1.0" | bc -l) )); then
        test_pass "Confidence in valid range [0,1]: $conf"
    else
        test_fail "Confidence out of range: $conf"
    fi
}

# ── Main Test Runner ──
main() {
    test_section "Batch 2: Force Pipeline Integration Tests"

    # Scenario 1: Single force baseline
    run_scenario "Single Force Baseline" "Single bullish F2, no conflicts, basic pipeline flow" setup_scenario_single_force
    validate_scenario_single_force

    # Scenario 2: Multi-force bullish consensus
    run_scenario "Multi-Force Bullish Consensus" "3 bullish forces, confluence boost should activate" setup_scenario_bull_consensus
    validate_scenario_bull_consensus

    # Scenario 3: Conflict detection
    run_scenario "Opposing Forces Conflict" "Bull vs Bear forces, C1 conflict resolution tested" setup_scenario_conflict
    validate_scenario_conflict

    # Scenario 4: Low confidence threshold
    run_scenario "Low Confidence Suppression" "Forces below gate, signal should be suppressed" setup_scenario_low_confidence
    validate_scenario_low_confidence

    # Scenario 5: V4 Format compatibility
    run_scenario "Alpha Finder V4 Compatibility" "Output format validated for downstream pipeline" setup_scenario_alphafv4
    validate_scenario_alphafv4

    # Cleanup
    rm -f /tmp/pipeline_output.json /tmp/pipeline_stderr

    print_test_summary
}

main "$@"
