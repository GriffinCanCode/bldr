#!/bin/bash
# Comprehensive stress test runner for Builder
# Tests system performance at scale with multiple languages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
LOG_FILE="${PROJECT_ROOT}/stress-test-$(date +%Y%m%d-%H%M%S).log"
RESULTS_FILE="${PROJECT_ROOT}/stress-test-results.txt"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Builder Multi-Language Scale Stress Test Suite        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to print section headers
print_section() {
    echo ""
    echo -e "${YELLOW}▶ $1${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Check if builder is built
if [ ! -f "${PROJECT_ROOT}/bin/builder" ]; then
    print_section "Building Builder binary"
    cd "$PROJECT_ROOT"
    dub build --build=release
fi

# System info
print_section "System Information"
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "OS: $(uname -s) $(uname -r)"
echo "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
echo "Cores: $(sysctl -n hw.ncpu 2>/dev/null || nproc)"
echo "Memory: $(( $(sysctl -n hw.memsize 2>/dev/null || grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 )) MB"
echo "Builder version: $(${PROJECT_ROOT}/bin/bldr --version 2>/dev/null || echo 'dev')"
echo ""

# Start results file
{
    echo "======================================================================"
    echo "Builder Multi-Language Stress Test Results"
    echo "Date: $(date)"
    echo "======================================================================"
    echo ""
} > "$RESULTS_FILE"

# Function to run a test category
run_test_category() {
    local test_name=$1
    local test_file=$2
    
    print_section "Running: $test_name"
    echo "Test file: $test_file"
    echo "Started: $(date +%H:%M:%S)"
    
    local start_time=$(date +%s)
    
    if dub test --build=unittest-cov -- "$test_file" 2>&1 | tee -a "$LOG_FILE"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo -e "${GREEN}✓ $test_name PASSED${NC} (${duration}s)"
        
        {
            echo "$test_name: PASSED (${duration}s)"
            echo ""
        } >> "$RESULTS_FILE"
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo -e "${RED}✗ $test_name FAILED${NC} (${duration}s)"
        
        {
            echo "$test_name: FAILED (${duration}s)"
            echo ""
        } >> "$RESULTS_FILE"
        
        return 1
    fi
}

# Track overall status
TESTS_PASSED=0
TESTS_FAILED=0
OVERALL_START=$(date +%s)

# Run test suites
echo -e "${BLUE}Starting stress test suite...${NC}"
echo ""

# 1. Multi-language stress test
if run_test_category "Multi-Language Stress Test" "tests.integration.multilang_stress"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 2. Parallel execution stress test
if run_test_category "Parallel Execution Stress Test" "tests.integration.stress_parallel"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# 3. Cache pressure test
if run_test_category "Cache Pressure Test" "tests.integration.cache_pressure"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

OVERALL_END=$(date +%s)
TOTAL_DURATION=$((OVERALL_END - OVERALL_START))

# Final summary
print_section "Test Summary"
{
    echo "======================================================================"
    echo "Final Results"
    echo "======================================================================"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"
    echo "Total Duration: ${TOTAL_DURATION}s"
    echo "Completed: $(date)"
    echo ""
    echo "Full logs: $LOG_FILE"
    echo "======================================================================"
} | tee -a "$RESULTS_FILE"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            ALL STRESS TESTS PASSED! ✓                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║         SOME STRESS TESTS FAILED! ✗                          ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

