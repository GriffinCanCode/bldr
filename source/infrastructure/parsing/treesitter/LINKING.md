# Tree-sitter Linking Guide

Complete guide to properly linking tree-sitter dependencies with Builder on different platforms.

## Overview

Builder uses tree-sitter for AST parsing. The tree-sitter C library must be:
1. **Installed** on the system (via Homebrew, apt, or source)
2. **Linked** correctly by the D compiler (dub)
3. **Located** at runtime by the dynamic linker

## macOS with Homebrew (Recommended)

### Installation

```bash
brew install tree-sitter
```

### Library Locations

Homebrew installs tree-sitter to different locations based on CPU architecture:

| Architecture | Library Path | Include Path |
|--------------|--------------|--------------|
| Apple Silicon (M1/M2/M3) | `/opt/homebrew/lib` | `/opt/homebrew/include` |
| Intel (x86_64) | `/usr/local/lib` | `/usr/local/include` |

### Dub Configuration

The `dub.json` is configured to search both locations:

```json
{
  "configurations": [
    {
      "libs": ["tree-sitter"],
      "lflags-osx": ["-L/opt/homebrew/lib", "-L/usr/local/lib"],
      "dflags": ["-I/opt/homebrew/include", "-I/usr/local/include"]
    }
  ]
}
```

**Explanation:**
- `"libs": ["tree-sitter"]` - Links against `libtree-sitter.dylib`
- `"lflags-osx"` - Adds library search paths for the linker
- `"dflags"` - Adds include paths for C header imports (if needed)

### Verification

Check if tree-sitter is properly installed:

```bash
# Using Homebrew
brew list tree-sitter

# Using pkg-config
pkg-config --exists tree-sitter && echo "Found" || echo "Not found"
pkg-config --modversion tree-sitter
pkg-config --libs tree-sitter
pkg-config --cflags tree-sitter

# Direct file check
ls -la /opt/homebrew/lib/libtree-sitter.* 2>/dev/null || \
ls -la /usr/local/lib/libtree-sitter.*

# Check headers
ls -la /opt/homebrew/include/tree_sitter/ 2>/dev/null || \
ls -la /usr/local/include/tree_sitter/
```

### Runtime Linking

macOS uses `dyld` to resolve dynamic libraries at runtime. The library is found via:

1. **Absolute paths** - If specified in the binary
2. **@rpath** - Relative to the binary's rpath
3. **System paths** - `/usr/lib`, `/usr/local/lib`
4. **DYLD_LIBRARY_PATH** - Environment variable (not recommended)

To verify runtime linking:

```bash
# Build the project
dub build

# Check what libraries the binary links to
otool -L bin/bldr | grep tree-sitter

# Should output something like:
# /opt/homebrew/lib/libtree-sitter.0.dylib (compatibility version 0.0.0)
```

### Troubleshooting macOS

#### "library not found for -ltree-sitter"

The linker can't find the library. Solutions:

```bash
# Verify installation
brew list tree-sitter

# Reinstall if needed
brew reinstall tree-sitter

# Check library exists
ls -la $(brew --prefix)/lib/libtree-sitter.*

# If using dmd directly (not dub)
dmd -L-L/opt/homebrew/lib -L-ltree-sitter ...
```

#### "dyld: Library not loaded: libtree-sitter.dylib"

The library is found at compile time but not runtime. Solutions:

```bash
# Option 1: Add to DYLD_LIBRARY_PATH (temporary)
export DYLD_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_LIBRARY_PATH
./bin/bldr

# Option 2: Add rpath to binary (permanent)
# This is handled by the Makefile's -Wl,-rpath flags

# Option 3: Install to system location (not recommended)
sudo cp /opt/homebrew/lib/libtree-sitter.* /usr/local/lib/
```

## Linux

### Installation

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install libtree-sitter-dev
```

**Fedora/RHEL:**
```bash
sudo yum install tree-sitter-devel
```

**Arch Linux:**
```bash
sudo pacman -S tree-sitter
```

### Library Locations

| Distribution | Library Path | Include Path |
|--------------|--------------|--------------|
| Ubuntu/Debian | `/usr/lib/x86_64-linux-gnu` | `/usr/include` |
| Fedora/RHEL | `/usr/lib64` or `/usr/lib` | `/usr/include` |
| Arch | `/usr/lib` | `/usr/include` |

### Dub Configuration

Linux typically doesn't need explicit paths (system locations are searched by default):

```json
{
  "configurations": [
    {
      "libs": ["tree-sitter"]
    }
  ]
}
```

### Verification

```bash
# Using pkg-config
pkg-config --exists tree-sitter && echo "Found" || echo "Not found"
pkg-config --modversion tree-sitter

# Check library
ldconfig -p | grep tree-sitter

# Check headers
ls -la /usr/include/tree_sitter/
```

### Runtime Linking

Linux uses `ld.so` to resolve dynamic libraries. Search paths:

1. `/lib` and `/usr/lib` (system libraries)
2. `/usr/local/lib` (locally installed)
3. Paths in `/etc/ld.so.conf.d/`
4. `LD_LIBRARY_PATH` environment variable

To verify:

```bash
# Check binary dependencies
ldd bin/bldr | grep tree-sitter

# Should show:
# libtree-sitter.so.0 => /usr/lib/x86_64-linux-gnu/libtree-sitter.so.0
```

### Troubleshooting Linux

#### "cannot find -ltree-sitter"

```bash
# Check if installed
dpkg -l | grep tree-sitter  # Ubuntu/Debian
rpm -qa | grep tree-sitter  # Fedora/RHEL

# Install dev package
sudo apt-get install libtree-sitter-dev

# Verify library exists
find /usr -name "libtree-sitter.*"
```

#### "error while loading shared libraries: libtree-sitter.so.0"

```bash
# Update library cache
sudo ldconfig

# Add to library path (temporary)
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

# Add to system config (permanent)
echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/tree-sitter.conf
sudo ldconfig
```

## Building from Source

If tree-sitter isn't available via package manager:

```bash
# Clone repository
git clone https://github.com/tree-sitter/tree-sitter
cd tree-sitter

# Build
make

# Install (requires sudo)
sudo make install

# Update library cache (Linux)
sudo ldconfig

# Verify installation
pkg-config --modversion tree-sitter
```

## Testing the Integration

### Runtime Check

Builder includes a dependency checker:

```d
import infrastructure.parsing.treesitter.deps;

void main() {
    // Check if tree-sitter is available
    if (TreeSitterDeps.isInstalled()) {
        writeln("✓ Tree-sitter found");
    } else {
        writeln("✗ Tree-sitter not found");
        TreeSitterDeps.printInstallInstructions();
    }
    
    // Get detailed info
    writeln(TreeSitterDeps.getInstallInfo());
}
```

### Build Test

```bash
# Clean build
dub clean
dub build

# Should succeed without linker errors
# If successful, the binary should run:
./bin/bldr --version
```

### Full Integration Test

```bash
# Run the setup script
cd source/infrastructure/parsing/treesitter
./setup.sh

# This performs:
# 1. Installation check
# 2. Grammar library build
# 3. Configuration verification
```

## Advanced Configuration

### Multiple Library Paths

If you have tree-sitter installed in a custom location:

```json
{
  "lflags": ["-L/custom/path/lib"],
  "dflags": ["-I/custom/path/include"]
}
```

### Static Linking

To avoid runtime dependencies:

```json
{
  "libs": [],
  "sourceFiles": ["/path/to/libtree-sitter.a"]
}
```

Note: Static linking increases binary size but eliminates runtime dependencies.

### Cross-Platform Configuration

For projects targeting multiple platforms:

```json
{
  "configurations": [
    {
      "name": "default",
      "libs": ["tree-sitter"],
      "lflags-osx": ["-L/opt/homebrew/lib", "-L/usr/local/lib"],
      "lflags-linux": [],
      "dflags-osx": ["-I/opt/homebrew/include", "-I/usr/local/include"],
      "dflags-linux": []
    }
  ]
}
```

## Summary

### Quick Setup

| Platform | Command |
|----------|---------|
| macOS | `brew install tree-sitter && dub build` |
| Ubuntu | `sudo apt-get install libtree-sitter-dev && dub build` |
| All | `./source/infrastructure/parsing/treesitter/setup.sh` |

### Key Files

- `dub.json` - Linker configuration
- `source/infrastructure/parsing/treesitter/grammars/Makefile` - Grammar build config
- `source/infrastructure/parsing/treesitter/setup.sh` - Automated setup script
- `source/infrastructure/parsing/treesitter/deps.d` - Runtime dependency checker

### Common Issues

| Error | Cause | Solution |
|-------|-------|----------|
| `library not found for -ltree-sitter` | Missing library at compile time | Install tree-sitter, check lflags |
| `dyld: Library not loaded` | Missing library at runtime (macOS) | Check DYLD_LIBRARY_PATH, rpaths |
| `error while loading shared libraries` | Missing library at runtime (Linux) | Run `ldconfig`, check LD_LIBRARY_PATH |
| `Symbol not found` | ABI mismatch | Rebuild with same tree-sitter version |

### Getting Help

If you encounter linking issues:

1. Run the setup script: `./source/infrastructure/parsing/treesitter/setup.sh --check`
2. Check installation info (from D code):
   ```d
   import infrastructure.parsing.treesitter.deps;
   writeln(TreeSitterDeps.getInstallInfo());
   ```
3. Verify library locations manually (see platform sections above)
4. Check the README files in the treesitter directory

## See Also

- [Tree-sitter Documentation](https://tree-sitter.github.io/tree-sitter/)
- [DUB Build Configuration](https://dub.pm/package-format-json.html)
- [Homebrew Tree-sitter Formula](https://formulae.brew.sh/formula/tree-sitter)

