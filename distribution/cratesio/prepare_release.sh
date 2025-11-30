#!/bin/bash
set -e

# Prepare the crate for publication on crates.io
# This script copies necessary source files into the crate directory

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$(dirname "$DIR")")"

echo "Preparing crate in $DIR..."
echo "Repo root: $REPO_ROOT"

# Clean previous bundle
rm -rf "$DIR/source" "$DIR/bin" "$DIR/dub.json" "$DIR/Makefile" "$DIR/tools" "$DIR/LICENSE" "$DIR/README.md"

# Copy source files
echo "Copying source files..."
cp -r "$REPO_ROOT/source" "$DIR/source"
cp "$REPO_ROOT/dub.json" "$DIR/"
cp "$REPO_ROOT/Makefile" "$DIR/"
cp "$REPO_ROOT/LICENSE" "$DIR/"
cp "$REPO_ROOT/README.md" "$DIR/"

# Create bin directory (needed for output)
mkdir -p "$DIR/bin/obj"

# Verify
if [ -f "$DIR/dub.json" ] && [ -d "$DIR/source" ]; then
    echo "Successfully bundled source files."
    echo "You can now run 'cargo publish' from this directory."
    echo "Note: Ensure you have ldc2 and dub installed."
else
    echo "Error: Failed to copy files."
    exit 1
fi

