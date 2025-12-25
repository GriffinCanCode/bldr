#!/bin/bash
# Test script for scripting feature examples
# Validates that all example Builderfiles can be parsed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Testing Scripting Feature Examples"
echo "=========================================="
echo ""

# Build bldr if needed
if [ ! -f "../../bin/bldr" ]; then
    echo "Building bldr..."
    cd ../..
    dub build
    cd "$SCRIPT_DIR"
fi

BLDR="../../bin/bldr"

# Test each example Builderfile
EXAMPLES=(
    "Builderfile"
    "Builderfile.variables"
    "Builderfile.loops"
    "Builderfile.conditionals"
    "Builderfile.functions"
    "Builderfile.builtins"
    "Builderfile.complete"
)

PASSED=0
FAILED=0

for example in "${EXAMPLES[@]}"; do
    if [ -f "$example" ]; then
        echo -n "Testing $example... "
        
        # Try to parse the file (use --dry-run or parse mode if available)
        if $BLDR parse "$example" 2>/dev/null; then
            echo "✅ PASSED"
            ((PASSED++))
        else
            # If parse command doesn't exist, try validate or just load
            if $BLDR validate "$example" 2>/dev/null; then
                echo "✅ PASSED"
                ((PASSED++))
            else
                echo "❌ FAILED"
                ((FAILED++))
            fi
        fi
    else
        echo "⚠️  $example not found"
    fi
done

echo ""
echo "=========================================="
echo "Results: $PASSED passed, $FAILED failed"
echo "=========================================="

if [ $FAILED -gt 0 ]; then
    exit 1
fi

echo ""
echo "All examples parsed successfully!"

