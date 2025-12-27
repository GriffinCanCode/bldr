# WebAssembly Example Project

This example demonstrates Builder's WebAssembly/WASI support.

## Prerequisites

Install at least one of these toolchains:

```bash
# wabt (wat2wasm) - for WAT files
brew install wabt

# wasmtime - for running WASI modules
brew install wasmtime

# Rust with wasm-pack (optional)
curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh

# Zig (optional)
brew install zig
```

## Building

```bash
# Build WAT module
builder build hello-wat

# Build all
builder build
```

## Running

```bash
# Run with wasmtime
wasmtime bin/hello.wasm

# Or use Builder's integrated runtime
builder run hello-wat
```

## Files

- `src/hello.wat` - Simple WAT example with WASI fd_write
- `src/lib.wat` - Library module with math functions
- `Builderfile` - Build configuration

## Usage in JavaScript

```javascript
const fs = require('fs');
const wasmBuffer = fs.readFileSync('bin/lib.wasm');

WebAssembly.instantiate(wasmBuffer).then(result => {
    const { add, sub, mul, factorial, fibonacci } = result.instance.exports;
    
    console.log('add(5, 3) =', add(5, 3));           // 8
    console.log('factorial(5) =', factorial(5));     // 120
    console.log('fibonacci(10) =', fibonacci(10));   // 55
});
```

## Supported Source Languages

This project demonstrates WAT (WebAssembly Text Format). Builder also supports:

- **Rust** via wasm-pack
- **C/C++** via Emscripten or Clang
- **Go** via TinyGo
- **Zig** native WASM target
- **AssemblyScript** (TypeScript subset)

See the `Builderfile` for configuration examples.


