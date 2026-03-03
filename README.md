# bldr

High-performance build system for polyglot monorepos. Runtime dependency discovery, lock-free parallel execution, incremental compilation. Built in D.

## Key Features

- **Dynamic Build Graphs** — Actions discover dependencies at runtime, eliminating code generation friction
- **28 Language Handlers** — C/C++, Rust, Go, D, Zig, Python, TypeScript, Java, Kotlin, Scala, and more
- **Three-Tier Caching** — Target, action, and distributed cache for maximum reuse
- **Work-Stealing Scheduler** — Chase-Lev deque, near-linear scaling to 64+ cores
- **Hermetic Builds** — Native sandboxing on Linux/macOS/Windows
- **Full LSP** — VS Code extension with autocomplete, diagnostics, go-to-definition
- **Query Language** — Bazel-compatible `bldrquery` for dependency exploration
- **Migration Tools** — Import from Bazel, CMake, Maven, Gradle, Cargo, npm, and more

## Installation

```bash
# macOS
brew install ldc dub && git clone https://github.com/GriffinCanCode/bldr.git && cd bldr && dub build --build=release

# Linux  
sudo apt install ldc dub && git clone https://github.com/GriffinCanCode/bldr.git && cd bldr && dub build --build=release
```

## Quick Start

```bash
bldr init                              # Initialize project
bldr wizard                            # Interactive setup
bldr build                             # Build all targets
bldr build //path/to:target            # Build specific target
bldr test                              # Run tests
bldr build --watch                     # Watch mode
bldr query 'deps(//src:app)'           # Query dependencies
bldr migrate --auto CMakeLists.txt     # Migrate from other build systems
bldr explain caching                   # Built-in documentation
```

## Builderfile Example

```d
let version = "1.0.0";
let flags = ["-O2", "-Wall"];

target("core-lib") {
    type: library;
    language: d;
    sources: ["src/core/**/*.d"];
    flags: flags;
}

target("app") {
    type: executable;
    language: d;
    sources: ["src/main.d"];
    deps: [":core-lib"];
}

target("tests") {
    type: test;
    language: d;
    sources: ["tests/**/*.d"];
    deps: [":core-lib"];
}
```

## Documentation

- [Architecture](docs/architecture/overview.md)
- [DSL Specification](docs/architecture/dsl.md)
- [User Guides](docs/user-guides/)
- [Examples](examples/)

## Status

| Component | Status |
|-----------|--------|
| Core Engine | ✅ Production |
| Language Handlers | ✅ Production |
| LSP / VS Code | ✅ Production |
| Distributed Execution | ⚠️ Beta |
| Plugin System | ⚠️ Beta |

## License

[Griffin License v1.0](LICENSE) — Free for commercial use with attribution.
