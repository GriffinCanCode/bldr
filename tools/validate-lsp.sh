#!/bin/bash
# Builder LSP Validation Script
# Comprehensive validation of LSP implementation

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Builder LSP Implementation Validation${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo

# Track validation results
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

check() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if eval "$2" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $1"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $1"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

check_with_details() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if eval "$2" &>/dev/null; then
        echo -e "${GREEN}✓${NC} $1"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $1"
        echo -e "  ${YELLOW}Details:${NC} $3"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
}

section() {
    echo
    echo -e "${BLUE}━━━ $1 ━━━${NC}"
}

# 1. LSP Source Files
section "LSP Source Files"
check "protocol.d exists" "test -f source/lsp/protocol.d"
check "server.d exists" "test -f source/lsp/server.d"
check "workspace.d exists" "test -f source/lsp/workspace.d"
check "completion.d exists" "test -f source/lsp/completion.d"
check "hover.d exists" "test -f source/lsp/hover.d"
check "definition.d exists" "test -f source/lsp/definition.d"
check "references.d exists" "test -f source/lsp/references.d"
check "rename.d exists" "test -f source/lsp/rename.d"
check "main.d exists" "test -f source/lsp/main.d"
check "LSP README exists" "test -f source/lsp/README.md"

# 2. LSP Binary
section "LSP Binary"
check "builder-lsp binary exists" "test -f bin/bldr-lsp"
check "builder-lsp is executable" "test -x bin/bldr-lsp"
check "builder-lsp has correct architecture" "file bin/bldr-lsp | grep -q 'arm64\|x86_64'"

# 3. LSP Binary Functionality
section "LSP Binary Functionality"
echo -n "Testing LSP initialize response... "
MSG='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file:///tmp","capabilities":{}}}'
LEN=${#MSG}
RESPONSE=$(printf "Content-Length: %d\r\n\r\n%s" $LEN "$MSG" | timeout 2 bin/bldr-lsp 2>/dev/null || true)
if echo "$RESPONSE" | grep -q '"result".*"capabilities"'; then
    echo -e "${GREEN}✓${NC} LSP server responds correctly to initialize"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
else
    echo -e "${RED}✗${NC} LSP server response invalid"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

if echo "$RESPONSE" | grep -q '"completionProvider"'; then
    echo -e "${GREEN}✓${NC} Completion capability advertised"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
else
    echo -e "${RED}✗${NC} Missing completion capability"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

if echo "$RESPONSE" | grep -q '"hoverProvider"'; then
    echo -e "${GREEN}✓${NC} Hover capability advertised"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
else
    echo -e "${RED}✗${NC} Missing hover capability"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

# 4. Build Configuration
section "Build Configuration"
check "dub.json exists" "test -f dub.json"
check "dub.json has lsp config" "grep -q '\"lsp\"' dub.json"
check "Makefile has build-lsp target" "grep -q 'build-lsp:' Makefile"
check "Makefile has install-lsp target" "grep -q 'install-lsp:' Makefile"
check "Makefile has extension target" "grep -q 'extension:' Makefile"

# 5. VS Code Extension Files
section "VS Code Extension"
check "Extension directory exists" "test -d tools/vscode/builder-lang"
check "package.json exists" "test -f tools/vscode/builder-lang/package.json"
check "extension.js exists" "test -f tools/vscode/builder-lang/extension.js"
check "extension.js syntax valid" "node -c tools/vscode/builder-lang/extension.js"
check "package.json has LSP client dependency" "grep -q 'vscode-languageclient' tools/vscode/builder-lang/package.json"
check "package.json has activation events" "grep -q 'activationEvents' tools/vscode/builder-lang/package.json"
check "Extension has main entry point" "grep -q '\"main\".*extension.js' tools/vscode/builder-lang/package.json"

# 6. Syntax Highlighting
section "Syntax Highlighting"
check "TextMate grammar exists" "test -f tools/vscode/builder-lang/syntaxes/builder.tmLanguage.json"
check "Language config exists" "test -f tools/vscode/builder-lang/language-configuration.json"

# 7. Documentation
section "Documentation"
check "User guide exists" "test -f docs/user-guides/LSP.md"
check "LSP checklist exists" "test -f docs/development/LSP_CHECKLIST.md"
check "Extension README exists" "test -f tools/vscode/builder-lang/README.md"

# 8. No Linter Errors
section "Code Quality"
echo -n "Checking for linter errors... "
if dub build --config=lsp --build=debug &>/dev/null; then
    echo -e "${GREEN}✓${NC} LSP builds without errors"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
else
    echo -e "${RED}✗${NC} LSP build has errors"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
fi
TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

# 9. Integration
section "Integration Validation"
check "No CLI command for LSP in app.d" "! grep -q '\"lsp\".*Command' source/app.d"
check "LSP has separate main.d" "test -f source/lsp/main.d"
check "app.d excludes lsp/main.d" "grep -q 'excludedSourceFiles.*lsp/main.d' dub.json"

# Summary
echo
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Validation Summary${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo
echo -e "Total checks:  ${BLUE}$TOTAL_CHECKS${NC}"
echo -e "Passed:        ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Failed:        ${RED}$FAILED_CHECKS${NC}"
echo

if [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "${GREEN}✓ All validation checks passed!${NC}"
    echo -e "${GREEN}✓ LSP implementation is READY FOR USE${NC}"
    echo
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "  1. Install LSP server: ${YELLOW}sudo make install-lsp${NC}"
    echo -e "  2. Install VS Code extension: ${YELLOW}make install-extension${NC}"
    echo -e "  3. Reload VS Code and open a Builderfile"
    echo
    exit 0
else
    echo -e "${RED}✗ Some validation checks failed${NC}"
    echo -e "${YELLOW}Please review the errors above and fix them${NC}"
    echo
    exit 1
fi

