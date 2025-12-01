#!/usr/bin/env bash
# Thread Sanitizer Test Runner
# Builds and runs tests with ThreadSanitizer to detect data races and concurrency issues

set -e

echo "=================================="
echo "Thread Sanitizer Test Runner"
echo "=================================="
echo ""

# Check if LDC is installed
if ! command -v ldc2 &> /dev/null; then
    echo "ERROR: LDC compiler (ldc2) is not installed."
    echo "Thread Sanitizer requires LDC."
    echo ""
    echo "Install LDC:"
    echo "  macOS:   brew install ldc"
    echo "  Ubuntu:  apt-get install ldc"
    echo "  Arch:    pacman -S ldc"
    echo ""
    exit 1
fi

echo "✓ LDC compiler found: $(ldc2 --version | head -n1)"
echo ""

# Set Thread Sanitizer options for better output
export TSAN_OPTIONS="halt_on_error=1 history_size=7 second_deadlock_stack=1 log_path=tsan-report"

echo "Building with Thread Sanitizer..."
dub build --compiler=ldc2 --build=tsan --config=executable

echo ""
echo "Running concurrency tests..."
echo "Note: Tests that trigger data races will cause immediate failure"
echo ""

# Run the builder on test examples that exercise concurrency
TEST_PROJECTS=(
    "examples/simple"
    "examples/python-multi"
    "examples/mixed-lang"
    "examples/typescript-app"
)

SUCCESS_COUNT=0
FAIL_COUNT=0

for project in "${TEST_PROJECTS[@]}"; do
    if [ ! -d "$project" ]; then
        echo "⚠ Skipping $project (not found)"
        continue
    fi
    
    echo "Testing: $project"
    cd "$project"
    
    # Clean previous build artifacts
    rm -rf bin/ .builder-cache/ 2>/dev/null || true
    
    # Run builder with TSan
    if ../../bin/bldr build --parallel; then
        echo "  ✓ Passed (no data races detected)"
        ((SUCCESS_COUNT++))
    else
        echo "  ✗ Failed (data race or error detected)"
        ((FAIL_COUNT++))
        
        # Show TSan report if available
        if [ -f "tsan-report" ]; then
            echo ""
            echo "=== Thread Sanitizer Report ==="
            cat tsan-report
            echo "==============================="
            echo ""
        fi
    fi
    
    cd - > /dev/null
    echo ""
done

# Run unit tests with TSan
echo "Running unit tests with Thread Sanitizer..."
if dub test --compiler=ldc2 --build=tsan; then
    echo "✓ Unit tests passed (no data races detected)"
    ((SUCCESS_COUNT++))
else
    echo "✗ Unit tests failed (data race detected)"
    ((FAIL_COUNT++))
fi

echo ""
echo "=================================="
echo "Thread Sanitizer Test Summary"
echo "=================================="
echo "Passed: $SUCCESS_COUNT"
echo "Failed: $FAIL_COUNT"

if [ -f "tsan-report" ]; then
    echo ""
    echo "Detailed reports saved to: tsan-report.*"
fi

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    echo "❌ Thread Sanitizer detected issues!"
    echo "Please review the reports above and fix the data races."
    exit 1
else
    echo ""
    echo "✅ All tests passed! No data races detected."
    exit 0
fi

