module languages.wasm;

/// WebAssembly Language Support
/// 
/// First-class WASM/WASI support for the polyglot build system:
/// - Compile from multiple source languages (Rust, C/C++, Go, Zig, AssemblyScript)
/// - Execute with WASI runtimes (wasmtime, wasmer, wasm3)
/// - WAT (WebAssembly Text Format) support
/// - WASM module inspection and validation
/// 
/// Supported Toolchains:
///   - wasm-pack: Rust → WASM (npm packages, web apps)
///   - Emscripten: C/C++ → WASM (emcc, emrun)
///   - Clang: C/C++ → WASM (standalone)
///   - TinyGo: Go → WASM (embedded, WASI)
///   - Zig: Zig → WASM (native support)
///   - AssemblyScript: TypeScript → WASM (asc)
///   - wabt: WAT → WASM (wat2wasm, wasm-validate)
/// 
/// Supported Runtimes:
///   - wasmtime: Bytecode Alliance reference runtime
///   - wasmer: Universal WASM runtime
///   - wasm3: Fast interpreter (embedded)
///   - Node.js: JavaScript WASM runtime
///   - Browser: Web target (via serve)
/// 
/// WASI Features:
///   - Filesystem access (preopens)
///   - Environment variables
///   - Command line arguments
///   - Standard I/O
///   - Clock/time access
/// 
/// Usage:
///   targets:
///     - name: hello-wasm
///       type: executable
///       language: webassembly
///       sources: [src/main.rs]
///       langConfig:
///         wasm: |
///           {
///             "toolchain": "wasm-pack",
///             "runtime": "wasmtime",
///             "wasi": { "enabled": true }
///           }

public import languages.wasm.core;
public import languages.wasm.tooling;
public import languages.wasm.analysis;


