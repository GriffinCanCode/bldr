#!/bin/bash
# Test Builder VS Code Extension Locally
# This script builds the LSP for your current platform and tests the extension

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}    Builder VS Code Extension - Local Testing${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo

# Detect platform
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$PLATFORM" in
    darwin)
        PLATFORM="darwin"
        ;;
    linux)
        PLATFORM="linux"
        ;;
    mingw*|msys*|cygwin*)
        PLATFORM="win32"
        ;;
    *)
        echo -e "${RED}✗ Unsupported platform: $PLATFORM${NC}"
        exit 1
        ;;
esac

case "$ARCH" in
    x86_64|amd64)
        ARCH="x64"
        ;;
    arm64|aarch64)
        ARCH="arm64"
        ;;
    *)
        echo -e "${RED}✗ Unsupported architecture: $ARCH${NC}"
        exit 1
        ;;
esac

echo -e "Detected platform: ${GREEN}${PLATFORM}-${ARCH}${NC}"
echo

# Step 1: Build LSP server
echo -e "${BLUE}Step 1: Building LSP server...${NC}"
if ! dub build --config=lsp --build=release; then
    echo -e "${RED}✗ Failed to build LSP server${NC}"
    exit 1
fi
echo -e "${GREEN}✓ LSP server built successfully${NC}"
echo

# Step 2: Set up extension directory
echo -e "${BLUE}Step 2: Setting up extension directory...${NC}"
EXTENSION_DIR="tools/vscode/builder-lang"
BIN_DIR="${EXTENSION_DIR}/bin/${PLATFORM}-${ARCH}"

mkdir -p "$BIN_DIR"

# Copy binary
if [ "$PLATFORM" = "win32" ]; then
    cp bin/bldr-lsp.exe "$BIN_DIR/"
    echo -e "${GREEN}✓ Copied builder-lsp.exe to $BIN_DIR${NC}"
else
    cp bin/bldr-lsp "$BIN_DIR/"
    chmod +x "$BIN_DIR/bldr-lsp"
    echo -e "${GREEN}✓ Copied builder-lsp to $BIN_DIR${NC}"
fi
echo

# Step 3: Install npm dependencies
echo -e "${BLUE}Step 3: Installing npm dependencies...${NC}"
cd "$EXTENSION_DIR"
if ! npm install; then
    echo -e "${RED}✗ Failed to install npm dependencies${NC}"
    exit 1
fi
echo -e "${GREEN}✓ npm dependencies installed${NC}"
echo

# Step 4: Test extension code
echo -e "${BLUE}Step 4: Validating extension code...${NC}"
if ! node -c extension.js; then
    echo -e "${RED}✗ Extension code has syntax errors${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Extension code is valid${NC}"
echo

# Step 5: Package extension
echo -e "${BLUE}Step 5: Packaging extension...${NC}"
if ! npx --yes @vscode/vsce package; then
    echo -e "${RED}✗ Failed to package extension${NC}"
    exit 1
fi

VSIX_FILE=$(ls -t builder-lang-*.vsix | head -1)
echo -e "${GREEN}✓ Extension packaged: ${VSIX_FILE}${NC}"
echo

# Step 6: Verify binary is in package
echo -e "${BLUE}Step 6: Verifying binary in package...${NC}"
if unzip -l "$VSIX_FILE" | grep -q "bin/${PLATFORM}-${ARCH}/bldr-lsp"; then
    echo -e "${GREEN}✓ Binary found in package for ${PLATFORM}-${ARCH}${NC}"
else
    echo -e "${RED}✗ Binary NOT found in package${NC}"
    echo -e "${YELLOW}Package contents:${NC}"
    unzip -l "$VSIX_FILE" | grep builder-lsp || echo "No builder-lsp binaries found!"
    exit 1
fi
echo

# Step 7: Offer to install
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Extension ready for testing!${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
echo
echo -e "Package: ${YELLOW}${VSIX_FILE}${NC}"
echo -e "Platform binary: ${YELLOW}bin/${PLATFORM}-${ARCH}/bldr-lsp${NC}"
echo
echo -e "${YELLOW}To install and test:${NC}"
echo -e "  code --install-extension ${VSIX_FILE}"
echo
echo -e "${YELLOW}After installation:${NC}"
echo -e "  1. Reload VS Code window (Cmd/Ctrl+Shift+P → 'Reload Window')"
echo -e "  2. Open a Builderfile"
echo -e "  3. Check Output panel: View → Output → 'Builder LSP'"
echo
read -p "Install extension now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Installing extension...${NC}"
    if code --install-extension "$VSIX_FILE"; then
        echo -e "${GREEN}✓ Extension installed!${NC}"
        echo -e "${YELLOW}Please reload VS Code to activate the extension${NC}"
    else
        echo -e "${RED}✗ Failed to install extension${NC}"
        echo -e "${YELLOW}You can install manually with:${NC}"
        echo -e "  code --install-extension $VSIX_FILE"
    fi
fi
echo
echo -e "${GREEN}Done!${NC}"

