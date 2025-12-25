#!/bin/bash
# Builder Examples Test Runner
# Tests all example projects to ensure Builder works correctly

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Get the project root (parent of examples directory)
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

# Arrays to track results
declare -a FAILED_EXAMPLES
declare -a SKIPPED_EXAMPLES

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              BUILDER EXAMPLES TEST SUITE                       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if bldr binary exists
if [ ! -f "${PROJECT_ROOT}/bin/bldr" ]; then
    echo -e "${YELLOW}[WARNING]${NC} Builder binary not found. Building..."
    (cd "${PROJECT_ROOT}" && make) || {
        echo -e "${RED}[ERROR]${NC} Failed to build Builder"
        exit 1
    }
fi

BUILDER="${PROJECT_ROOT}/bin/bldr"

# Function to test an example
test_example() {
    local example_path="$1"
    local example_name="$2"
    
    TOTAL=$((TOTAL + 1))
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[${TOTAL}] Testing:${NC} ${example_name}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Check if Builderfile exists
    if [ ! -f "${example_path}/Builderfile" ]; then
        echo -e "${YELLOW}[SKIP]${NC} No Builderfile found in ${example_name}"
        SKIPPED=$((SKIPPED + 1))
        SKIPPED_EXAMPLES+=("${example_name}")
        echo ""
        return
    fi
    
    # Save current directory
    pushd "${example_path}" > /dev/null
    
    # Clean any previous builds (optional, comment out if you want to preserve builds)
    # rm -rf bin/ 2>/dev/null || true
    
    # Run builder
    if $BUILDER build --verbose 2>&1; then
        echo -e "${GREEN}✓ PASSED${NC} ${example_name}"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED${NC} ${example_name}"
        FAILED=$((FAILED + 1))
        FAILED_EXAMPLES+=("${example_name}")
    fi
    
    popd > /dev/null
    echo ""
}

# Test all top-level example projects
echo -e "${CYAN}[INFO]${NC} Scanning examples directory..."
echo ""

# Change to examples directory
cd "${SCRIPT_DIR}"

# Standard examples (single directory)
for dir in */; do
    # Skip if not a directory
    [ ! -d "$dir" ] && continue
    
    dir_name="${dir%/}"
    
    # Skip special directories
    if [ "$dir_name" = "javascript" ] || [ "$dir_name" = "observability" ]; then
        continue
    fi
    
    test_example "$dir_name" "$dir_name"
done

# Handle JavaScript subdirectories
if [ -d "javascript" ]; then
    for js_dir in javascript/*/; do
        [ ! -d "$js_dir" ] && continue
        js_dir_name="${js_dir%/}"
        js_base_name=$(basename "$js_dir_name")
        test_example "$js_dir_name" "javascript/${js_base_name}"
    done
fi

# Handle observability examples (if they have Builderfiles)
if [ -d "observability" ]; then
    if [ -f "observability/Builderfile" ]; then
        test_example "observability" "observability"
    else
        echo -e "${YELLOW}[SKIP]${NC} observability (no Builderfile)"
        SKIPPED=$((SKIPPED + 1))
        SKIPPED_EXAMPLES+=("observability")
    fi
fi

# Print summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}                        SUMMARY                                 ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "Total Examples: ${TOTAL}"
echo -e "${GREEN}Passed: ${PASSED}${NC}"
echo -e "${RED}Failed: ${FAILED}${NC}"
echo -e "${YELLOW}Skipped: ${SKIPPED}${NC}"
echo ""

# List failed examples if any
if [ ${FAILED} -gt 0 ]; then
    echo -e "${RED}Failed Examples:${NC}"
    for example in "${FAILED_EXAMPLES[@]}"; do
        echo -e "  ${RED}✗${NC} ${example}"
    done
    echo ""
fi

# List skipped examples if any
if [ ${SKIPPED} -gt 0 ]; then
    echo -e "${YELLOW}Skipped Examples:${NC}"
    for example in "${SKIPPED_EXAMPLES[@]}"; do
        echo -e "  ${YELLOW}⊘${NC} ${example}"
    done
    echo ""
fi

# Final result
if [ ${FAILED} -eq 0 ] && [ ${PASSED} -gt 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✓ ALL EXAMPLES PASSED!                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 0
elif [ ${FAILED} -eq 0 ] && [ ${PASSED} -eq 0 ]; then
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║              ⚠ NO EXAMPLES TESTED                              ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              ✗ SOME EXAMPLES FAILED                            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

