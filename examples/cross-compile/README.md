# Cross-Compilation Example

This example demonstrates Builder's cross-compilation capabilities using the unified toolchain system.

## Overview

The example builds a simple C program that reports its architecture, OS, and compiler for multiple target platforms from a single host machine.

## Prerequisites

For each target platform, you'll need the appropriate cross-compilation toolchain installed:

### ARM64 Linux
```bash
# Ubuntu/Debian
sudo apt install gcc-aarch64-linux-gnu

# macOS (Homebrew)
brew install aarch64-elf-gcc
```

### ARM32 Linux
```bash
# Ubuntu/Debian
sudo apt install gcc-arm-linux-gnueabihf
```

### RISC-V Linux
```bash
# Ubuntu/Debian
sudo apt install gcc-riscv64-linux-gnu
```

### WebAssembly (Emscripten)
```bash
# Install Emscripten SDK
git clone https://github.com/emscripten-core/emsdk.git
cd emsdk
./emsdk install latest
./emsdk activate latest
source ./emsdk_env.sh
```

### macOS (OSXCross)
```bash
# See: https://github.com/tpoechtrager/osxcross
```

### Windows (MinGW)
```bash
# Ubuntu/Debian
sudo apt install mingw-w64

# macOS (Homebrew)
brew install mingw-w64
```

## Building

### Build all targets
```bash
bldr build //...
```

### Build specific target
```bash
# Native build
bldr build :app-native

# ARM64 build
bldr build :app-arm64

# WebAssembly build
bldr build :app-wasm
```

### List available toolchains
```bash
builder toolchains list
```

### Detect installed toolchains
```bash
builder detect --toolchains
```

## Platform Triples

Builder uses standard target triple format: `<arch>-<vendor>-<os>-<abi>`

Examples:
- `x86_64-unknown-linux-gnu` - 64-bit x86 Linux with GNU libc
- `aarch64-unknown-linux-gnu` - 64-bit ARM Linux
- `arm-unknown-linux-gnueabihf` - 32-bit ARM Linux with hard float
- `x86_64-apple-darwin` - macOS
- `x86_64-w64-mingw32` - Windows 64-bit
- `wasm32-unknown-web` - WebAssembly

Simplified aliases are also supported:
- `linux-arm64` → `aarch64-unknown-linux-gnu`
- `darwin-x86_64` → `x86_64-apple-darwin`
- `windows-x86_64` → `x86_64-w64-mingw32`

## Toolchain References

### Auto-detection
```
toolchain: "gcc";  // Find any GCC toolchain
toolchain: "clang";  // Find any Clang toolchain
```

### Specific version
```
toolchain: "gcc-11";  // GCC version 11.x
toolchain: "clang-15";  // Clang version 15.x
```

### External toolchain
```
toolchain: "@toolchains//arm:gcc";  // External ARM GCC
toolchain: "@toolchains//llvm:clang";  // External LLVM
```

## Testing Cross-Compiled Binaries

### QEMU (for ARM/RISC-V)
```bash
# Install QEMU
sudo apt install qemu-user

# Run ARM64 binary
qemu-aarch64 bin/app-arm64

# Run ARM32 binary
qemu-arm bin/app-arm32

# Run RISC-V binary
qemu-riscv64 bin/app-riscv64
```

### Node.js (for WebAssembly)
```bash
node --experimental-wasm-modules bin/app.wasm
```

### Wine (for Windows binaries on Linux)
```bash
wine bin/app.exe
```

## Advanced Usage

### Custom Toolchain Configuration

Create a toolchain definition file:

```json
{
  "id": "custom-arm-gcc",
  "name": "gcc",
  "version": "11.3.0",
  "host": "x86_64-unknown-linux-gnu",
  "target": "aarch64-unknown-linux-gnu",
  "tools": {
    "compiler": "/opt/gcc-arm/bin/aarch64-linux-gnu-gcc",
    "linker": "/opt/gcc-arm/bin/aarch64-linux-gnu-ld",
    "archiver": "/opt/gcc-arm/bin/aarch64-linux-gnu-ar"
  },
  "sysroot": "/opt/gcc-arm/aarch64-linux-gnu/sysroot",
  "env": {
    "CC": "aarch64-linux-gnu-gcc",
    "CXX": "aarch64-linux-gnu-g++",
    "AR": "aarch64-linux-gnu-ar"
  }
}
```

Register in Builderfile:

```
toolchain_config("custom-arm") {
    config: "toolchain.json";
}

target("app") {
    toolchain: "custom-arm";
    platform: "linux-arm64";
    sources: ["main.c"];
}
```

### Hermetic Cross-Compilation

Enable hermetic builds for reproducibility:

```
target("app-hermetic") {
    type: executable;
    platform: "linux-arm64";
    toolchain: "@toolchains//arm:gcc";
    hermetic: true;  // Enforce hermetic build
    sources: ["main.c"];
}
```

## Architecture

The cross-compilation system consists of:

1. **Platform Detection**: Identifies host and target platforms
2. **Toolchain Discovery**: Auto-detects installed toolchains
3. **Toolchain Selection**: Matches toolchain to target platform
4. **Build Configuration**: Sets compiler flags, sysroot, etc.
5. **Hermetic Execution**: Runs build in isolated environment

## Troubleshooting

### Toolchain not found
```bash
# List detected toolchains
builder toolchains list

# Verify toolchain installation
which aarch64-linux-gnu-gcc

# Re-run detection
builder detect --toolchains --force
```

### Linking errors
Check that your sysroot contains the necessary libraries:
```bash
ls /usr/aarch64-linux-gnu/lib
```

### Platform not supported
Check supported platforms:
```bash
builder platforms list
```

## Performance Tips

- Use `--parallel` for faster multi-target builds
- Enable `--cache` to avoid rebuilding unchanged targets
- Use `--distributed` for distributed cross-compilation
- Set `jobs: 0` for auto-detected parallelism

## References

- [Builder Toolchain Documentation](../../docs/features/toolchains.md)
- [Platform Triple Format](https://llvm.org/docs/CrossCompilation.html)
- [Hermetic Builds](../../docs/features/hermetic.md)

