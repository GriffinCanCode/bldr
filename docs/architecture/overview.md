# Builder Architecture

## Overview

Builder is a build system for mixed-language monorepos, using D's compile-time metaprogramming for dependency analysis. This document describes the core architecture.

## Core Components

### 1. Build Graph

**Location**: `source/engine/graph/`

The build graph represents all targets and their dependencies as a directed acyclic graph (DAG).

Features:
- Topological sorting for correct build order
- Cycle detection
- Parallel build scheduling based on dependency depth
- Build status tracking (Pending, Building, Success, Failed, Cached)

Algorithm:
- DFS-based topological sort
- Depth calculation for wave-based parallel execution

### 2. Build Cache

**Location**: `source/engine/caching/`

Incremental build cache with content-addressable storage.

Strategy:
- Two-tier hashing: metadata (mtime+size) + BLAKE3 content hash
- Binary serialization
- Lazy writes (batch updates, write once per build)
- LRU eviction with configurable size limits
- Dependency-aware invalidation

Performance:
- **Two-Tier Hashing** (`infrastructure/utils/files/hash.d`): Metadata check (~1μs) before content hash (~50μs-1ms). 95%+ of unchanged files detected by metadata alone.
- **BLAKE3**: SIMD-accelerated (AVX-512/AVX2/NEON), 3-5x faster than SHA-256
- **Size-Tiered Strategy**: Tiny (<4KB) direct, small (<1MB) chunked, medium (<100MB) sampled, large (>100MB) aggressive sampling

Configuration:
```bash
BUILDER_CACHE_MAX_SIZE=1073741824      # 1 GB default
BUILDER_CACHE_MAX_ENTRIES=10000        # 10k entries default
BUILDER_CACHE_MAX_AGE_DAYS=30          # 30 days default
```

### 3. Build Executor

**Location**: `source/engine/runtime/core/`

Orchestrates build execution.

Strategy:
- Wave-based parallel execution (builds all ready nodes in parallel)
- Respects dependency order
- Configurable parallelism (default: CPU count)
- Fail-fast error handling

Flow:
1. Get topologically sorted nodes
2. Find all ready nodes (dependencies satisfied)
3. Build ready nodes in parallel
4. Update node status
5. Repeat until all nodes built or error

### 4. Dependency Analysis

**Location**: `source/infrastructure/analysis/`

Compile-time metaprogramming with strongly typed domain objects.

Components:
- `targets/types.d`: Strongly typed domain objects (Import, Dependency, FileAnalysis)
- `targets/spec.d`: Language specification registry
- `metadata/metagen.d`: Compile-time code generation
- `inference/analyzer.d`: Main analyzer
- `incremental/analyzer.d`: Incremental analysis with caching

Import Pattern Support:
- D: `import` statements
- Python: `import` and `from` statements
- JavaScript/TypeScript: ES6 `import` and CommonJS `require`
- Go: `import` declarations
- Rust: `use` statements
- C/C++: `#include` directives
- Java/Kotlin/Scala: `import` statements
- C#: `using` statements
- Ruby: `require` and `require_relative`
- PHP: `require`, `include`, and `use`

### 5. Language Handlers

**Location**: `source/languages/`

Pluggable language-specific build logic.

Base Interface:
```d
interface LanguageHandler {
    BuildResult!string buildWithContext(BuildContext context);
    bool needsRebuild(in Target target, in WorkspaceConfig config);
    void clean(in Target target, in WorkspaceConfig config);
    string[] getOutputs(in Target target, in WorkspaceConfig config);
    Import[] analyzeImports(in string[] sources);
}
```

Supported Languages:

| Category | Languages |
|----------|-----------|
| Compiled | C/C++, Rust, D, Zig, Nim, Swift, Haskell, OCaml |
| JVM | Java, Kotlin, Scala |
| .NET | C#, F# |
| Scripting | Python, Ruby, PHP, Perl, Lua, Elixir, R |
| Web | JavaScript, TypeScript, CSS, Elm |
| Functional | Go, Gleam |
| Protocol | Protobuf |
| Custom | Shell, Templating |
| Dynamic | Crystal, Dart, V (JSON spec-based) |

Handler Structure:
```
languages/
├── base/           - Base interface and mixins
├── compiled/       - C++, D, Rust, Zig, Nim, Swift, Haskell, OCaml
├── dotnet/         - C#, F#
├── jvm/            - Java, Kotlin, Scala
├── scripting/      - Python, Ruby, PHP, Perl, Lua, Elixir, Go, R, Gleam
├── web/            - JavaScript, TypeScript, CSS, Elm
├── custom/         - Shell, Templating
├── dynamic/        - JSON spec-based handlers
├── specs/          - JSON language specifications (Crystal, Dart, V)
└── registry.d      - Language registry
```

### 6. Configuration System

**Location**: `source/infrastructure/config/`

D-based DSL with JSON backward compatibility.

DSL Format:
```d
target("target-name") {
    type: executable;  // or library, test, custom
    language: python;  // optional, inferred from sources
    sources: ["src/**/*.py"];
    deps: ["//path/to:other-target"];
    flags: ["-O2", "-Wall"];
    env: {"KEY": "value"};
}
```

Architecture:
- **Lexer** (`parsing/lexer.d`): Zero-allocation tokenization
- **AST** (`workspace/ast.d`): Strongly-typed AST nodes
- **Parser** (`parsing/unified.d`): Recursive descent parser
- **Semantic Analysis** (`analysis/semantic.d`): Type checking and validation

Features:
- Comment support (`//`, `/* */`, `#`)
- Detailed error messages with line/column
- Glob pattern expansion (`**` recursive)
- Negation patterns (`!pattern`)
- Language inference from file extensions

## Design Decisions

### Why D?

1. **Compile-time Metaprogramming**: Templates, mixins, and CTFE for code generation
2. **Zero-Cost Abstractions**: Strong typing compiled to optimal machine code
3. **Performance**: Native compilation with LLVM backend (LDC)
4. **Memory Safety**: @safe by default
5. **C/C++ Interop**: Seamless integration with build tools

### Build Graph vs Build Rules

Unlike Bazel's rule-based approach, Builder uses a pure dependency graph:

Advantages:
- Simpler mental model
- Easier to visualize and debug
- More flexible for mixed-language projects
- Less boilerplate

Trade-offs:
- Less fine-grained control over build steps
- Fewer built-in optimizations

### Caching Strategy

**Two-Tier Hashing**:
- Tier 1: Fast metadata check (mtime + size)
- Tier 2: Content hash only if metadata changed

**Target-Level Caching**:
- Simpler than action-level
- Faster for small/medium projects
- Can extend to action-level if needed

## Performance

### Time Complexity

| Operation | Complexity |
|-----------|------------|
| Dependency Analysis | O(V + E) |
| Import Resolution | O(1) average |
| Topological Sort | O(V + E) |
| Cycle Detection | O(V + E) |
| Cache Lookup | O(1) average |

V = targets, E = dependencies

### Scalability

Tested with:
- 1,000+ targets: ~100ms analysis time
- 10,000+ files: ~500ms file scanning

Optimizations:
- Size-tiered hashing (50-500x faster for large files)
- Parallel file scanning (4-8x faster)
- O(1) import index lookups
- Compile-time code generation
- Binary cache storage (5-10x faster than JSON)
- Two-tier hashing (1000x faster for unchanged files)
- Lazy cache writes (100x I/O reduction)

## Related Documentation

- [Hermetic Builds](hermetic.md) - Sandboxed execution
- [Incremental Analysis](incremental-design.md) - Caching analysis results
- [Error System](error-system-unified.md) - Error handling
- [Migration](migration.md) - Build system migration
- [DSL](DSL.md) - Configuration syntax
