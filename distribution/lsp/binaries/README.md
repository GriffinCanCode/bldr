# Builder LSP Binaries

Platform-specific binaries for the Builder Language Server.

## Available Binaries

| Platform | Architecture | Binary Name |
|----------|-------------|-------------|
| macOS | ARM64 (Apple Silicon) | `builder-lsp-darwin-arm64` |
| macOS | x86_64 (Intel) | `builder-lsp-darwin-x86_64` |
| Linux | x86_64 | `builder-lsp-linux-x86_64` |
| Linux | ARM64 | `builder-lsp-linux-aarch64` |
| Windows | x86_64 | `builder-lsp-windows-x86_64.exe` |

## Building Binaries

### Prerequisites

- D compiler (ldc2 recommended for cross-compilation)
- dub package manager
- Cross-compilation toolchains (for non-native platforms)

### Build Commands

#### macOS ARM64 (Apple Silicon)

```bash
dub build :lsp --build=release --compiler=ldc2 --arch=arm64-apple-macos
cp bin/bldr-lsp distribution/lsp/binaries/bldr-lsp-darwin-arm64
```

#### macOS x86_64 (Intel)

```bash
dub build :lsp --build=release --compiler=ldc2 --arch=x86_64-apple-macos
cp bin/bldr-lsp distribution/lsp/binaries/bldr-lsp-darwin-x86_64
```

#### Linux x86_64

```bash
dub build :lsp --build=release --compiler=ldc2 --arch=x86_64-linux-gnu
cp bin/bldr-lsp distribution/lsp/binaries/bldr-lsp-linux-x86_64
```

#### Linux ARM64

```bash
dub build :lsp --build=release --compiler=ldc2 --arch=aarch64-linux-gnu
cp bin/bldr-lsp distribution/lsp/binaries/bldr-lsp-linux-aarch64
```

#### Windows x86_64

```bash
dub build :lsp --build=release --compiler=ldc2 --arch=x86_64-windows-msvc
cp bin/bldr-lsp.exe distribution/lsp/binaries/bldr-lsp-windows-x86_64.exe
```

### Build All Platforms

Use the provided script to build all binaries:

```bash
./tools/build-lsp-binaries.sh
```

This script will:
1. Build binaries for all supported platforms
2. Strip debug symbols for smaller size
3. Verify each binary runs correctly
4. Copy to distribution folder
5. Calculate SHA256 checksums

## Checksums

SHA256 checksums for binary verification:

```
# Generate checksums
cd distribution/lsp/binaries
shasum -a 256 * > SHA256SUMS

# Verify
shasum -a 256 -c SHA256SUMS
```

## Release Process

1. Build all binaries:
   ```bash
   ./tools/build-lsp-binaries.sh
   ```

2. Test each binary on target platform:
   ```bash
   ./bldr-lsp-<platform> --version
   ```

3. Generate checksums:
   ```bash
   cd distribution/lsp/binaries
   shasum -a 256 * > SHA256SUMS
   ```

4. Tag release:
   ```bash
   git tag -a v2.0.0 -m "Release v2.0.0"
   git push origin v2.0.0
   ```

5. Create GitHub release and attach binaries

6. Update package managers (Homebrew, npm, etc.)

## Binary Size Optimization

Binaries are built with:
- Release mode (`--build=release`)
- LLVM optimizations (LDC2)
- Stripped debug symbols
- Link-time optimization (LTO)

Typical sizes:
- macOS: ~2-3 MB
- Linux: ~2-3 MB
- Windows: ~2.5-3.5 MB

## Testing

Test each binary before release:

```bash
# Basic functionality
./bldr-lsp-darwin-arm64 --version
./bldr-lsp-darwin-arm64 --help

# LSP protocol test
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | ./bldr-lsp-darwin-arm64

# Integration test
cd tests
./test-lsp-integration.sh ../distribution/lsp/binaries/bldr-lsp-darwin-arm64
```

## Cross-Compilation Notes

### macOS

- Use Xcode toolchain for native builds
- Can cross-compile ARM64 ↔ x86_64 on same machine with Universal Binary support
- Sign binaries for distribution: `codesign -s "Developer ID" builder-lsp`

### Linux

- Use musl for static binaries (better portability)
- Test on both glibc and musl systems
- For ARM64, use QEMU for testing if not on ARM64 hardware

### Windows

- Build on Windows or use MinGW/MSVC cross-compilation
- Include Visual C++ runtime if needed
- Test on Windows 10+ and Windows Server

## CI/CD Integration

GitHub Actions workflow for building binaries:

```yaml
name: Build LSP Binaries

on:
  release:
    types: [created]

jobs:
  build:
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v3
      - name: Install D
        uses: dlang-community/setup-dlang@v1
        with:
          compiler: ldc-latest
      - name: Build LSP
        run: dub build :lsp --build=release
      - name: Upload binary
        uses: actions/upload-artifact@v3
        with:
          name: builder-lsp-${{ matrix.os }}
          path: bin/bldr-lsp*
```

## Troubleshooting

### Binary Not Executing

**macOS**: "cannot be opened because the developer cannot be verified"
- Solution: `xattr -d com.apple.quarantine builder-lsp-darwin-arm64`
- Or sign the binary before distribution

**Linux**: "No such file or directory" (but file exists)
- Solution: Install required libraries or use static build
- Check: `ldd builder-lsp-linux-x86_64`

**Windows**: "VCRUNTIME140.dll is missing"
- Solution: Include runtime or link statically
- Or instruct users to install VC++ redistributable

### Performance Issues

- Ensure binary is built with `--build=release`
- Use LDC2 compiler (faster than DMD)
- Enable LTO: `--build=release-lto`
- Profile with: `dub build :lsp --build=profile`

## Support

- [Building Guide](../../../docs/development/TESTING.md)
- [LSP Documentation](../README.md)
- [Report Issues](https://github.com/GriffinCanCode/Builder/issues)

