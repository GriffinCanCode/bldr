#!/bin/bash
# Builder Examples Parallel Test Runner
# Tests all example projects in parallel to measure performance

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

BUILDER="${PROJECT_ROOT}/bin/bldr"
RESULTS_DIR=$(mktemp -d)
MAX_JOBS=${MAX_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)}

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          PARALLEL BUILDER EXAMPLES TEST SUITE                  ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${CYAN}[INFO]${NC} Using ${MAX_JOBS} parallel jobs"
echo ""

# Check builder binary
if [ ! -f "$BUILDER" ]; then
    echo -e "${YELLOW}[WARNING]${NC} Builder binary not found. Building..."
    (cd "${PROJECT_ROOT}" && make) || exit 1
fi

# Get timestamp in milliseconds (works on macOS and Linux)
get_ms() {
    python3 -c 'import time; print(int(time.time()*1000))'
}

# Build a single example (called in parallel)
build_example() {
    local example_path="$1"
    local example_name="$2"
    local result_file="${RESULTS_DIR}/${example_name//\//_}.result"
    
    if [ ! -f "${example_path}/Builderfile" ]; then
        echo "SKIPPED" > "$result_file"
        return
    fi
    
    cd "$example_path"
    start_time=$(get_ms)
    
    if $BUILDER build 2>&1 >/dev/null; then
        end_time=$(get_ms)
        duration=$((end_time - start_time))
        echo "PASSED:${duration}" > "$result_file"
    else
        echo "FAILED" > "$result_file"
    fi
}

export -f get_ms

export -f build_example
export BUILDER RESULTS_DIR

# Collect all examples
EXAMPLES=()
cd "$SCRIPT_DIR"

for dir in */; do
    [ ! -d "$dir" ] && continue
    dir_name="${dir%/}"
    [[ "$dir_name" == "javascript" || "$dir_name" == "observability" ]] && continue
    EXAMPLES+=("${SCRIPT_DIR}/${dir_name}:${dir_name}")
done

# JavaScript subdirectories
if [ -d "javascript" ]; then
    for js_dir in javascript/*/; do
        [ ! -d "$js_dir" ] && continue
        js_name="${js_dir%/}"
        EXAMPLES+=("${SCRIPT_DIR}/${js_name}:${js_name}")
    done
fi

echo -e "${CYAN}[INFO]${NC} Testing ${#EXAMPLES[@]} examples in parallel..."
echo ""

START_TIME=$(get_ms)

# Run all builds in parallel
printf '%s\n' "${EXAMPLES[@]}" | xargs -P "$MAX_JOBS" -I {} bash -c '
    IFS=":" read -r path name <<< "{}"
    build_example "$path" "$name"
'

END_TIME=$(get_ms)
TOTAL_TIME=$((END_TIME - START_TIME))

# Collect results
PASSED=0
FAILED=0
SKIPPED=0
TOTAL_BUILD_TIME=0

declare -a FAILED_EXAMPLES
declare -a SKIPPED_EXAMPLES
declare -a TIMING_DATA

for result_file in "$RESULTS_DIR"/*.result; do
    [ ! -f "$result_file" ] && continue
    example_name=$(basename "$result_file" .result | sed 's/_/\//g')
    result=$(cat "$result_file")
    
    if [[ "$result" == "SKIPPED" ]]; then
        ((SKIPPED++))
        SKIPPED_EXAMPLES+=("$example_name")
    elif [[ "$result" == PASSED:* ]]; then
        ((PASSED++))
        duration=${result#PASSED:}
        TOTAL_BUILD_TIME=$((TOTAL_BUILD_TIME + duration))
        TIMING_DATA+=("${duration}ms:${example_name}")
    else
        ((FAILED++))
        FAILED_EXAMPLES+=("$example_name")
    fi
done

TOTAL=$((PASSED + FAILED + SKIPPED))

# Print summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}                    PERFORMANCE SUMMARY                         ${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "Total Examples: ${TOTAL}"
echo -e "${GREEN}Passed: ${PASSED}${NC}"
echo -e "${RED}Failed: ${FAILED}${NC}"
echo -e "${YELLOW}Skipped: ${SKIPPED}${NC}"
echo ""
echo -e "${CYAN}⏱  Timing:${NC}"
echo -e "  Wall clock time:    ${TOTAL_TIME}ms ($(echo "scale=1; $TOTAL_TIME/1000" | bc)s)"
echo -e "  Sum of build times: ${TOTAL_BUILD_TIME}ms ($(echo "scale=1; $TOTAL_BUILD_TIME/1000" | bc)s)"
echo -e "  Parallelism factor: $(echo "scale=2; $TOTAL_BUILD_TIME/$TOTAL_TIME" | bc)x"
echo -e "  Throughput:         $(echo "scale=2; $PASSED*1000/$TOTAL_TIME" | bc) builds/sec"
echo ""

# Show top 5 slowest builds
if [ ${#TIMING_DATA[@]} -gt 0 ]; then
    echo -e "${YELLOW}Slowest builds:${NC}"
    printf '%s\n' "${TIMING_DATA[@]}" | sort -t: -k1 -rn | head -5 | while read line; do
        time_part="${line%%:*}"
        name_part="${line#*:}"
        echo -e "  ${time_part} - ${name_part}"
    done
    echo ""
fi

if [ ${FAILED} -gt 0 ]; then
    echo -e "${RED}Failed:${NC}"
    for ex in "${FAILED_EXAMPLES[@]}"; do echo -e "  ${RED}✗${NC} $ex"; done
    echo ""
fi

# Cleanup
rm -rf "$RESULTS_DIR"

if [ ${FAILED} -eq 0 ] && [ ${PASSED} -gt 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✓ ALL EXAMPLES PASSED!                            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              ✗ SOME EXAMPLES FAILED                            ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

