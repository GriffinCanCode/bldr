# Toolchain System

**Status: ✅ Complete & Integrated**

## Overview

The Toolchain System provides unified platform and toolchain abstraction for cross-compilation and build tool management in Builder. It replaces fragmented language-specific toolchain detection with a single, extensible system.

## Architecture

The toolchain system is organized into modular subsystems with clear separation of concerns:

```
toolchain/
├── package.d             # Main barrel export (public API)
├── README.md             # This file
│
├── core/                 # Core Specifications
│   ├── package.d         # Barrel export for core
│   ├── platform.d        # Platform abstraction (OS, Arch, ABI)
│   └── spec.d            # Toolchain, Tool, Version specifications
│
├── detection/            # Toolchain Detection
│   ├── package.d         # Barrel export for detection
│   ├── detector.d        # Base detection + core detectors (GCC, Clang, Rust)
│   └── language_detectors.d  # Language-specific detectors (Go, Python, Node, etc.)
│
├── registry/             # Registry & Constraints
│   ├── package.d         # Barrel export for registry
│   ├── registry.d        # Central toolchain registry (singleton)
│   └── constraints.d     # Version constraint solving (semver)
│
└── providers/            # Toolchain Providers
    ├── package.d         # Barrel export for providers
    └── providers.d       # Local and remote toolchain providers
```

### Module Organization

**`core/`** - Foundational data structures and platform abstractions
- Platform triple parsing and host detection
- Toolchain and Tool specifications
- Version parsing and comparison
- Capability flags and toolchain references

**`detection/`** - Automatic toolchain discovery
- Base detector interface and ExecutableDetector
- Built-in detectors: GCC, Clang, Rust (in `detector.d`)
- Language-specific detectors: Go, Python, Node, Java, Zig, D, CMake (in `language_detectors.d`)
- AutoDetector orchestration

**`registry/`** - Centralized toolchain management
- Singleton registry for all toolchains
- Constraint-based toolchain resolution
- Version constraint parsing and matching
- Platform-based toolchain lookup

**`providers/`** - Toolchain provisioning
- Local filesystem toolchain provider
- Repository-based remote toolchain provider
- Manifest-based toolchain definition
- Integration with Builder's repository system

## Key Features

### 1. Platform Abstraction

Represents target platforms as **OS + Architecture + ABI** triples:

```d
auto platform = Platform.parse("x86_64-unknown-linux-gnu");
auto host = Platform.host();

if (target.isCross())
    writeln("Cross-compiling!");
```

**Supported**: x86, x86_64, ARM, ARM64, RISC-V, MIPS, PowerPC, WASM  
**OSes**: Linux, macOS, Windows, BSD variants, Android, iOS, Web  
**ABIs**: GNU, MUSL, MSVC, MinGW, Darwin, Android, EABI

### 2. Toolchain Specification

Defines toolchains as collections of tools with capabilities:

```d
Tool tool;
tool.name = "clang++";
tool.version_ = Version(15, 0, 0);
tool.type = ToolchainType.Compiler;
tool.capabilities = Capability.LTO | Capability.CrossCompile;
```

**Tool Types**: Compiler, Linker, Archiver, Assembler, Interpreter, Runtime, BuildTool, PackageManager

**Capabilities**: CrossCompile, LTO, PGO, Incremental, Sanitizers, Debugging, Optimization, StaticAnalysis, Modules, Hermetic

### 3. Auto-Detection

Automatically discovers installed toolchains:

```d
auto registry = ToolchainRegistry.instance();
registry.initialize(); // Auto-detects all available toolchains

// Find by name
auto toolchains = registry.getByName("gcc");

// Find for platform
auto result = registry.findFor(Platform.host(), ToolchainType.Compiler);
```

**Built-in Detectors**:
- **C/C++**: GCC (gcc, g++, ld, ar), Clang (clang, clang++, lld, llvm-ar)
- **Rust**: rustc, cargo
- **Go**: go, gofmt
- **Python**: python3, pip
- **Node.js**: node, npm, npx
- **Java**: java, javac
- **Zig**: zig
- **D**: DMD, LDC, GDC, dub
- **Build Tools**: CMake, ninja

### 4. Version Constraints

Semantic version constraint solving:

```d
auto constraint = ToolchainConstraint.parse("gcc@>=11.0.0");
auto result = registry.findMatching(constraint.unwrap());

// Supports: exact (1.2.3), >=, <, ranges (>=1.0.0 <2.0.0), wildcards (1.x, 1.2.x)
```

### 5. Remote Toolchain Providers

Fetch toolchains from external repositories:

```d
// In Builderspace:
repository("llvm-15") {
    url: "https://github.com/llvm/llvm-project/releases/...";
    integrity: "blake3:abc123...";
}

// Use in target:
target("app") {
    toolchain: "@llvm-15//:clang";
    platform: "linux-x86_64";
}
```

### 6. Manifest-Based Toolchains

Declare custom toolchains via JSON:

```json
{
  "toolchains": [{
    "name": "custom-gcc",
    "version": "11.3.0",
    "host": "x86_64-unknown-linux-gnu",
    "target": "x86_64-unknown-linux-gnu",
    "tools": [{
      "name": "gcc",
      "path": "bin/gcc",
      "type": "compiler",
      "capabilities": ["lto", "optimization"]
    }],
    "env": {"CC": "gcc"},
    "sysroot": "sysroot"
  }]
}
```

## Integration

### Language Handlers

Language handlers use the unified system via the main barrel export:

```d
import infrastructure.toolchain;

class MyHandler : BaseLanguageHandler
{
    protected override LanguageBuildResult buildImpl(in Target target, in WorkspaceConfig config)
    {
        auto registry = ToolchainRegistry.instance();
        registry.initialize();
        
        // Auto-detect or use constraint
        auto result = registry.findFor(Platform.host(), ToolchainType.Compiler);
        if (result.isErr)
            return error("No compiler found");
        
        auto tc = result.unwrap();
        auto compiler = tc.compiler();
        
        // Use compiler.path, compiler.version_, etc.
        execute([compiler.path, "build.sh"]);
    }
}
```

### DSL Integration

```
target("app") {
    type: executable;
    platform: "linux-arm64";          // Target platform
    toolchain: "gcc@>=11.0.0";        // Version constraint
    sources: ["main.c"];
}
```

## API Reference

### Platform

```d
Platform.parse(string triple) -> Result!(Platform, BuildError)
Platform.host() -> Platform
Platform.toTriple() -> string
Platform.isCross() -> bool
Platform.compatibleWith(Platform) -> bool
```

### Registry

```d
ToolchainRegistry.instance() -> ToolchainRegistry
initialize() -> void
get(string id) -> Result!(Toolchain, BuildError)
getByName(string name) -> Toolchain[]
findFor(Platform, ToolchainType) -> Result!(Toolchain, BuildError)
findMatching(ToolchainConstraint) -> Result!(Toolchain, BuildError)
resolve(ToolchainRef) -> Result!(Toolchain, BuildError)
list() -> const(Toolchain)[]
addDetector(ToolchainDetector) -> void
addProvider(ToolchainProvider) -> void
```

### Convenience Functions

```d
getToolchain(string id) -> Result!(Toolchain, BuildError)
findToolchain(Platform, ToolchainType) -> Result!(Toolchain, BuildError)
resolveToolchain(string refStr) -> Result!(Toolchain, BuildError)
getToolchainByName(string name, string versionConstraint = "") -> Result!(Toolchain, BuildError)
getCompilerPath(string toolchainName) -> string
```

## Design Principles

### 1. Modular Architecture

The system is organized into four focused subsystems:
- **Core**: Platform-independent data structures (~700 lines)
- **Detection**: Automatic toolchain discovery (~950 lines)
- **Registry**: Centralized management and constraints (~740 lines)
- **Providers**: Remote toolchain provisioning (~460 lines)

Each subsystem has its own package.d barrel export for clean API boundaries.

### 2. Elegance Through Unification

Previously, each language handler had its own toolchain detection (~200-300 lines each). Now: single system (~2,850 lines total) serving all languages.

### 3. Extensibility

- Registry pattern for custom detectors
- Provider pattern for remote toolchains
- Plugin architecture for new languages

### 4. Type Safety

- Strong typing throughout (enums, structs, Result types)
- No string parsing in hot paths
- Compile-time capability checks

### 5. Zero Tech Debt

- Short, focused modules (150-450 lines)
- Single responsibility per class
- Comprehensive unit tests
- No external dependencies

### 6. Performance

- Lazy initialization (registry initializes on first use)
- Caching (detected toolchains cached in memory)
- O(1) lookup by ID
- Minimal detection overhead

## Migration Guide

### Before (C++ handler)

```d
import languages.compiled.cpp.tooling.toolchain;

auto compilerInfo = Toolchain.detect(Compiler.GCC);
if (!compilerInfo.isAvailable)
    error("GCC not found");
string compiler = compilerInfo.path;
```

### After (Unified system)

```d
import infrastructure.toolchain;

auto result = getToolchainByName("gcc");
if (result.isErr)
    error("GCC not found");
auto tc = result.unwrap();
auto compiler = tc.compiler();
string compilerPath = compiler.path;
```

## Testing

```bash
# Run toolchain tests
dub test --filter="toolchain"

# Detect available toolchains
./bin/bldr detect --toolchains

# List registered toolchains
./bin/bldr toolchains list

# Show toolchain details
./bin/bldr toolchains show gcc-11
```

## Module Statistics

### Core (`core/`)
- **Lines**: ~700 lines
- **Files**: 2 (platform.d, spec.d)
- **Exports**: Platform, Toolchain, Tool, Version, ToolchainRef, Capability, ToolchainType

### Detection (`detection/`)
- **Lines**: ~950 lines
- **Files**: 2 (detector.d, language_detectors.d)
- **Exports**: ToolchainDetector, AutoDetector, ExecutableDetector
- **Detectors**: 11 built-in (GCC, Clang, Rust, Go, Python, Node, Java, Zig, D, CMake)

### Registry (`registry/`)
- **Lines**: ~740 lines
- **Files**: 2 (registry.d, constraints.d)
- **Exports**: ToolchainRegistry, ToolchainConstraint, VersionConstraint, ConstraintSolver

### Providers (`providers/`)
- **Lines**: ~460 lines
- **Files**: 1 (providers.d)
- **Exports**: ToolchainProvider, LocalToolchainProvider, RepositoryToolchainProvider, ToolchainManifest

### Overall
- **Total Lines**: ~2,850 lines of production code
- **Modules**: 4 subsystems (core, detection, registry, providers)
- **Files**: 7 implementation files + 5 barrel exports
- **Unit Tests**: 12 test suites
- **Supported Platforms**: 40+ combinations
- **Languages Integrated**: C++, D (more to come)

## Future Enhancements

1. **Toolchain Download**: Automatic download of missing toolchains
2. **Sysroot Management**: Managed sysroots for cross-compilation
3. **Toolchain Caching**: Persistent cache across builds
4. **Remote Execution**: Execute builds with remote toolchains
5. **Toolchain Profiles**: Predefined toolchain configurations

## Credits

Design inspired by:
- Bazel's toolchain system
- Rust's target triple format
- LLVM's platform abstractions
- Zig's cross-compilation model

## See Also

- `/examples/toolchain-integration/` - Usage examples
- `/examples/cross-compile/` - Cross-compilation examples
- `/docs/features/` - Feature documentation
