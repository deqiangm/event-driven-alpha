#!/usr/bin/env bash
# tests/run_all_tests.sh — Master Test Runner (All Phases)
# Extensible: Just add new test files to unit/ or integration/ directories

set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ESAD_ROOT="$(cd "${TEST_ROOT}/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           ESAD — Event-Driven Structural Alpha Detector      ║"
echo "║                  INTEGRATION TEST SUITE v1.0                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo "  Project Root: $ESAD_ROOT"
echo "  Test Root:    $TEST_ROOT"
echo "  Date:         $(date -I)"
echo ""

# Ensure scripts are executable
chmod +x "${TEST_ROOT}"/unit/*.sh 2>/dev/null || true
chmod +x "${TEST_ROOT}"/integration/*.sh 2>/dev/null || true
chmod +x "${TEST_ROOT}"/lib/*.sh 2>/dev/null || true

# ── Phase Selector ──
PHASE="${1:-all}"

if [[ "$PHASE" == "list" ]]; then
    echo "Available test phases:"
    echo "  batch2    — Batch 2 tests only (Force System Completion)"
    echo "  phase1    — Phase 1 tests only (Event Calendar + IPO Force)"
    echo "  all       — Run all tests (default)"
    echo ""
    echo "Usage: $0 [phase]"
    exit 0
fi

# ── Run Tests ──
FAILED=0

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🧪 RUNNING UNIT TESTS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

for test_file in "${TEST_ROOT}"/unit/test_*.sh; do
    if [[ ! -f "$test_file" ]]; then
        continue
    fi

    # Phase filtering
    if [[ "$PHASE" == "batch2" ]]; then
        # Batch2 tests: infrastructure and force-related
        if [[ "$test_file" != *"infrastructure"* && "$test_file" != *"force"* ]]; then
            continue
        fi
    elif [[ "$PHASE" == "phase1" ]]; then
        # Phase1 tests: event calendar, IPO related
        if [[ "$test_file" != *"event"* && "$test_file" != *"ipo"* ]]; then
            continue
        fi
    fi

    echo ""
    echo "  → Running: $(basename "$test_file")"
    if ! bash "$test_file"; then
        FAILED=$((FAILED + 1))
        echo -e "  ${RED}✗ Test suite failed: $(basename "$test_file")${NC}"
    else
        echo -e "  ${GREEN}✓ Test suite passed: $(basename "$test_file")${NC}"
    fi
done

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🧪 RUNNING INTEGRATION TESTS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

for test_file in "${TEST_ROOT}"/integration/test_*.sh; do
    if [[ ! -f "$test_file" ]]; then
        continue
    fi

    # Phase filtering
    if [[ "$PHASE" == "batch2" ]]; then
        if [[ "$test_file" != *"pipeline"* && "$test_file" != *"force"* ]]; then
            continue
        fi
    elif [[ "$PHASE" == "phase1" ]]; then
        if [[ "$test_file" != *"event"* && "$test_file" != *"ipo"* ]]; then
            continue
        fi
    fi

    echo ""
    echo "  → Running: $(basename "$test_file")"
    if ! bash "$test_file"; then
        FAILED=$((FAILED + 1))
        echo -e "  ${RED}✗ Test suite failed: $(basename "$test_file")${NC}"
    else
        echo -e "  ${GREEN}✓ Test suite passed: $(basename "$test_file")${NC}"
    fi
done

# ── Final Summary ──
echo ""
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Project: ESAD (Event-Driven Structural Alpha Detector)"
    echo "  Phase:   $PHASE"
    echo "  Status:  Ready for production deployment"
    echo ""
    exit 0
else
    echo -e "${RED}❌ $FAILED TEST SUITE(S) FAILED${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Please fix failing tests before deployment."
    echo ""
    exit 1
fi
