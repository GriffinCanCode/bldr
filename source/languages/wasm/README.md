# WebAssembly Language Support

First-class WebAssembly (WASM) and WASI support for Builder's polyglot build system.

## Overview

The WASM module provides:
- **Multi-source compilation**: Compile to WASM from Rust, C/C++, Go, Zig, AssemblyScript
- **Runtime execution**: Execute WASM modules via wasmtime, wasmer, wasm3, Node.js
- **WASI support**: Full WASI capability model (filesystem, env, stdio, etc.)
- **WAT support**: WebAssembly Text Format compilation and inspection
- **Module analysis**: Inspect imports, exports, memory, and features

## Supported Toolchains

| Toolchain | Source Languages | Features |
|-----------|------------------|----------|
| **wasm-pack** | Rust | npm packages, web apps, wasm-bindgen |
| **Emscripten** | C, C++ | Full libc, pthreads, filesystem |
| **Clang** | C, C++ | Standalone WASI modules |
| **TinyGo** | Go | Embedded, WASI, small binaries |
| **Zig** | Zig | Native WASM target, SIMD |
| **AssemblyScript** | TypeScript | TypeScript subset, fast compilation |
| **wabt** | WAT | Text format to binary |

## Supported Runtimes

| Runtime | Type | Best For |
|---------|------|----------|
| **wasmtime** | JIT/AOT | Production, WASI |
| **wasmer** | JIT/AOT | Universal, plugins |
| **wasm3** | Interpreter | Embedded, constrained |
| **Node.js** | V8 | JavaScript interop |
| **Browser** | V8/SpiderMonkey | Web applications |

## Usage

### Basic WASM Target

```yaml
targets:
  - name: hello-wasm
    type: executable
    language: webassembly
    sources: [src/main.rs]
    langConfig:
      wasm: |
        {
          "toolchain": "wasm-pack",
          "runtime": "wasmtime",
          "wasi": { "enabled": true }
        }
```

### WASI Application

```yaml
targets:
  - name: cli-tool
    type: executable
    language: wasm
    sources: [src/main.c]
    langConfig:
      wasm: |
        {
          "toolchain": "emscripten",
          "wasi": {
            "enabled": true,
            "capabilities": ["fileRead", "fileWrite", "stdout", "stderr"],
            "dirs": [
              { "guest": "/data", "host": "./data", "readonly": false }
            ]
          }
        }
```

### Browser Target

```yaml
targets:
  - name: web-app
    type: library
    language: webassembly
    sources: [src/lib.rs]
    langConfig:
      wasm: |
        {
          "toolchain": "wasm-pack",
          "runtime": "browser",
          "jsGlue": true,
          "esModule": true
        }
```

### WAT Compilation

```yaml
targets:
  - name: manual-wasm
    type: executable
    language: wat
    sources: [src/module.wat]
    langConfig:
      wasm: |
        {
          "toolchain": "wat2wasm",
          "optimize": "os"
        }
```

## Configuration Reference

### Source Languages
- `auto` - Detect from file extensions
- `rust` - Rust via wasm-pack/cargo
- `c` - C via Emscripten/clang
- `cpp` - C++ via Emscripten/clang
- `go` - Go via TinyGo
- `zig` - Zig native
- `assemblyscript` - AssemblyScript (asc)
- `wat` - WebAssembly Text Format
- `wasm` - Pre-compiled binary

### Optimization Levels
- `none` / `0` - Debug mode
- `1` / `o1` - Basic optimization
- `2` / `o2` - Standard (default)
- `3` / `o3` - Aggressive
- `s` / `os` - Optimize for size
- `z` / `oz` - Aggressively optimize for size

### WASM Features (Proposals)
```json
{
  "features": {
    "simd": true,
    "threads": true,
    "multiValue": true,
    "bulkMemory": true,
    "referenceTypes": false,
    "tailCall": false,
    "exceptions": false,
    "gc": false,
    "memory64": false,
    "componentModel": false
  }
}
```

### Memory Configuration
```json
{
  "memory": {
    "initialPages": 256,
    "maxPages": 4096,
    "shared": false,
    "memory64": false
  }
}
```

### WASI Capabilities
- `fileRead` - Read files from host
- `fileWrite` - Write files to host
- `stdout` - Standard output
- `stderr` - Standard error
- `stdin` - Standard input
- `network` - Network access (experimental)
- `env` - Environment variables
- `args` - Command line arguments
- `clock` - Time/clock access
- `random` - Random number generation

## Module Structure

```
wasm/
├── core/
│   ├── config.d     # Configuration types (WasmConfig, WasiConfig, etc.)
│   ├── handler.d    # WebAssemblyHandler implementation
│   └── package.d
├── tooling/
│   ├── tools.d      # Toolchain detection and builders
│   └── package.d
├── analysis/
│   ├── inspector.d  # WASM module inspection
│   └── package.d
├── package.d
└── README.md
```

## Cross-Compilation

WebAssembly serves as a universal compilation target:

```yaml
# Rust → WASM
targets:
  - name: rust-wasm
    language: webassembly
    sources: [Cargo.toml]
    langConfig:
      wasm: { "sourceLang": "rust", "toolchain": "wasm-pack" }

# C → WASM (Emscripten)
targets:
  - name: c-wasm
    language: webassembly
    sources: [src/main.c]
    langConfig:
      wasm: { "sourceLang": "c", "toolchain": "emscripten" }

# Zig → WASM (native)
targets:
  - name: zig-wasm
    language: webassembly
    sources: [src/main.zig]
    langConfig:
      wasm: { "sourceLang": "zig", "toolchain": "zig" }
```

## WASM Size Optimization

```yaml
langConfig:
  wasm: |
    {
      "optimize": "oz",
      "strip": true,
      "lto": true,
      "features": {
        "bulkMemory": true
      }
    }
```

## Testing WASM Modules

```yaml
targets:
  - name: wasm-tests
    type: test
    language: webassembly
    sources: [tests/]
    langConfig:
      wasm: |
        {
          "runtime": "wasmtime",
          "wasi": {
            "enabled": true,
            "inheritStdio": true
          }
        }
```

## Dependencies

### Required (one of)
- wasm-pack (Rust)
- emcc (Emscripten)
- clang with WASM target
- tinygo
- zig
- asc (AssemblyScript)
- wat2wasm (wabt)

### Optional
- wasm-opt (binaryen) - Post-compilation optimization
- wasmtime/wasmer/wasm3 - WASI execution
- node - JavaScript runtime

## Future Enhancements

- [ ] Component Model (wit-bindgen) support
- [ ] WASM GC proposal
- [ ] WASM Exception Handling
- [ ] wasm-tools integration
- [ ] WASM debugging support
- [ ] Hot module replacement


