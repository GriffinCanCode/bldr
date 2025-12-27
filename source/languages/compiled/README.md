# Compiled Languages

First-class support for compiled language builds with toolchain detection, formatting, linting, and caching.

## Architecture

All compiled handlers extend `BaseCompiledLanguageHandler` from `languages/compiled/base.d`:

```
languages/compiled/
├── base.d          ← BaseCompiledLanguageHandler (shared workflow)
├── cpp/core/       ← CppHandler extends BaseCompiledLanguageHandler
├── d/core/         ← DHandler extends BaseCompiledLanguageHandler
├── haskell/core/   ← HaskellHandler extends BaseCompiledLanguageHandler
├── nim/core/       ← NimHandler extends BaseCompiledLanguageHandler
├── ocaml/core/     ← OCamlHandler extends BaseCompiledLanguageHandler
├── protobuf/core/  ← ProtobufHandler extends BaseCompiledLanguageHandler
├── rust/core/      ← RustHandler extends BaseCompiledLanguageHandler
├── swift/core/     ← SwiftHandler extends BaseCompiledLanguageHandler
├── zig/core/       ← ZigHandler extends BaseCompiledLanguageHandler
└── package.d
```

The base class provides a unified build workflow:
1. **parseConfig()** → Parse language-specific JSON configuration
2. **detectToolchain()** → Check compiler/tool availability
3. **formatSources()** → Run language formatters
4. **lintSources()** → Run linters/static analysis
5. **compileTarget()** → Execute build with action-level caching

Individual handlers only implement:
- Toolchain detection and version queries
- Config parsing from target langConfig
- Formatter/linter integration
- Compiler command building

## Supported Languages

### C++ (GCC, Clang, MSVC)

**File Extensions:** `.cpp`, `.cc`, `.cxx`, `.c`, `.h`, `.hpp`

**Features:**
- Precompiled header (PCH) support
- Incremental linking (ld.lld, Gold, MSVC)
- clang-format integration
- clang-tidy linting
- Address/thread sanitizer support

### D (DMD, LDC, GDC)

**File Extensions:** `.d`

**Features:**
- Multi-compiler support (DMD, LDC, GDC)
- dub integration for packages
- dfmt formatting
- D-Scanner linting

### Rust (rustc, cargo)

**File Extensions:** `.rs`

**Features:**
- Cargo build integration
- rustfmt formatting
- clippy linting
- Cross-compilation via cargo
- Incremental linking support

### Zig

**File Extensions:** `.zig`

**Features:**
- build.zig detection
- zig fmt formatting
- Cross-compilation built-in
- C interop support

### Swift (swiftc, SPM)

**File Extensions:** `.swift`

**Features:**
- Swift Package Manager integration
- Xcode toolchain support
- swift-format formatting
- SwiftLint integration

### Haskell (GHC, Cabal, Stack)

**File Extensions:** `.hs`, `.lhs`

**Features:**
- Auto-detect Stack/Cabal projects
- HLint linting
- Ormolu/Fourmolu formatting
- GHC direct compilation

### Nim

**File Extensions:** `.nim`, `.nims`

**Features:**
- Multiple backends (C, C++, JS, ObjC)
- nimble package integration
- nimpretty formatting
- Cross-compilation support

### OCaml (dune, ocamlopt, ocamlc)

**File Extensions:** `.ml`, `.mli`, `.mll`, `.mly`

**Features:**
- dune build system integration
- ocamlformat formatting
- Native (ocamlopt) and bytecode (ocamlc)
- Incremental linking support

### Protocol Buffers

**File Extensions:** `.proto`

**Features:**
- protoc compiler
- buf CLI integration (lint, format)
- Multi-language code generation
- Dynamic discovery of generated files

## Configuration Example

```d
target("myapp") {
    type: executable;
    language: rust;
    sources: ["src/**/*.rs"];
    rust: {
        edition: "2021";
        profile: "release";
        features: ["async", "serde"];
        clippy: true;
        fmt: true;
    }
}
```

## Action-Level Caching

All compiled language handlers use Builder's action cache:
- Source file content hashing
- Compiler flag tracking
- Output artifact caching
- Incremental rebuilds

## Toolchain Detection

Builder auto-detects installed toolchains:

```bash
bldr info toolchains
```

Shows detected compilers with versions for all supported languages.

