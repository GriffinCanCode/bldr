# Incremental Compilation

Module-level incremental compilation minimizes rebuilds by tracking file-level dependencies and recompiling only affected source files when dependencies change.

## Overview

Builder's incremental compilation extends beyond action-level caching to provide language-aware dependency tracking. When a header file or module changes, only the source files that transitively depend on it are recompiled.

## Architecture

### Components

**Dependency Cache**: `source/engine/caching/incremental/`

```
incremental/
├── dependency.d    # DependencyCache - file dependency tracking
├── storage.d       # Binary storage for dependency data
├── schema.d        # Serializable types
└── ast_dependency.d # AST-level dependency tracking
```

**Incremental Engine**: `source/engine/compilation/incremental/`

```
incremental/
├── engine.d        # IncrementalEngine - rebuild determination
├── analyzer.d      # DependencyAnalyzer interface
├── ast_engine.d    # AST-level incremental engine
└── package.d       # Public API
```

**Language Analyzers**: `source/languages/*/analysis/incremental.d`

- C++: `source/languages/compiled/cpp/analysis/incremental.d`
- Rust: `source/languages/compiled/rust/analysis/incremental.d`
- Go: `source/languages/scripting/go/analysis/incremental.d`
- TypeScript: `source/languages/web/typescript/analysis/incremental.d`
- Java: `source/languages/jvm/java/analysis/incremental.d`
- D: `source/languages/compiled/d/analysis/incremental.d`

### Flow

```
┌──────────────────┐
│  Source Change   │
└────────┬─────────┘
         │
         ▼
┌──────────────────────────┐
│  Dependency Analyzer     │ ← Language-specific
│  - Parse imports/includes│
│  - Resolve to files      │
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Incremental Engine      │
│  - Check ActionCache     │
│  - Analyze dependencies  │
│  - Determine rebuild set │
└────────┬─────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Minimal Rebuild         │
│  - Compile affected files│
│  - Update caches         │
└──────────────────────────┘
```

## Core Types

### DependencyAnalyzer Interface

```d
interface DependencyAnalyzer
{
    BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] includePaths = []
    ) @system;
    
    string resolveDependency(
        string dependency,
        string sourceDir,
        string[] searchPaths = []
    ) @system;
    
    bool isExternalDependency(string dependency) @system;
}
```

### FileDependency

```d
struct FileDependency
{
    string sourceFile;
    string[] dependencies;
    string sourceHash;
    string[] depHashes;
    SysTime timestamp;
    
    bool isValid() const @system;
    bool hasDependencyChanges() const @system;
}
```

### IncrementalResult

```d
struct IncrementalResult
{
    string[] filesToCompile;
    string[] cachedFiles;
    CompilationStrategy strategy;
    string[string] reasons;
    size_t totalFiles;
    size_t compiledFiles;
    size_t cachedFiles_;
    float reductionRate;
}
```

## Supported Languages

### C++

Analyzes `#include` directives:

```d
auto analyzer = new CppDependencyAnalyzer(["/path/to/include"]);
auto deps = analyzer.analyzeDependencies("main.cpp");
// Returns: ["header.h", "utils.h"] (resolved to absolute paths)
```

Features:
- Header dependency tracking
- Resolves through include paths
- Filters STL and C standard library headers
- Tracks transitive dependencies

### Rust

Uses Cargo metadata for dependency tracking:

```d
auto analyzer = new RustDependencyAnalyzer("/path/to/rust/project");
auto deps = analyzer.analyzeDependencies("main.rs");
// Returns: ["module.rs", "utils/mod.rs"]
```

Features:
- Parses `mod` and `use` statements
- Follows Rust file structure rules
- Filters standard library crates

### Go

Parses import statements:

```d
auto analyzer = new GoDependencyAnalyzer("/path/to/go/module");
auto deps = analyzer.analyzeDependencies("main.go");
// Returns: ["package/file1.go", "package/file2.go"]
```

Features:
- Detects module path from `go.mod`
- Parses single and block imports
- Filters standard library packages

### TypeScript

Parses import/export statements:

```d
auto analyzer = new TypeScriptDependencyAnalyzer("/path/to/project");
auto deps = analyzer.analyzeDependencies("main.ts");
// Returns: ["./module.ts", "./utils/index.ts"]
```

Features:
- Loads tsconfig.json
- Resolves relative and absolute imports
- Filters node_modules
- Supports .ts, .tsx, .d.ts, .js, .jsx

### Java

Tracks class dependencies:

```d
auto analyzer = new JavaDependencyAnalyzer("/project/root", ["src/main/java"]);
auto deps = analyzer.analyzeDependencies("Main.java");
// Returns: ["com/example/Module.java"]
```

Features:
- Resolves qualified class names
- Filters JDK standard library
- Supports multiple source paths

## Usage

### Basic Example

```d
import engine.caching.incremental.dependency;
import engine.caching.actions.action;
import engine.compilation.incremental.engine;

// Initialize
auto depCache = new DependencyCache(".builder-cache/incremental");
auto actionCache = new ActionCache(".builder-cache/actions");
auto engine = new IncrementalEngine(depCache, actionCache);

// Determine rebuild set
auto result = engine.determineRebuildSet(
    allSourceFiles,
    changedFiles,
    (file) => makeActionId(file),
    (file) => makeMetadata(file)
);

// Compile necessary files
foreach (file; result.filesToCompile)
{
    auto deps = analyzer.analyzeDependencies(file);
    compile(file);
    
    engine.recordCompilation(
        file,
        deps.unwrap(),
        actionId,
        outputs,
        metadata
    );
}

// Statistics
writeln("Compiled: ", result.compiledFiles, "/", result.totalFiles);
writeln("Reduction: ", result.reductionRate, "%");
```

### Custom Analyzer

```d
class MyLanguageAnalyzer : BaseDependencyAnalyzer
{
    override BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] searchPaths = []
    ) @system
    {
        // 1. Parse source file for imports
        auto imports = parseImports(sourceFile);
        
        // 2. Resolve to absolute paths
        string[] resolved;
        foreach (imp; imports)
        {
            if (!isExternalDependency(imp))
            {
                auto path = resolveImport(imp, searchPaths);
                if (!path.empty)
                    resolved ~= path;
            }
        }
        
        return BuildResult!(string[]).ok(resolved);
    }
    
    override bool isExternalDependency(string importPath) @system
    {
        return importPath.startsWith("std.") || 
               importPath.canFind("node_modules");
    }
}
```

## Compilation Strategies

### Full

Rebuild everything regardless of caches.

```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Full
);
```

Use for CI or when caches are untrusted.

### Incremental (Default)

Rebuild files with cache misses or dependency changes, plus transitive dependents.

```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Incremental
);
```

### Minimal

Rebuild only directly changed files or cache misses. Skip transitive dependents.

```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Minimal
);
```

## Performance

### Typical Reduction Rates

| Scenario | Reduction | Example |
|----------|-----------|---------|
| Header change | 70-90% | 1 header → rebuild 10/100 files |
| Source change | 90-99% | 1 source → rebuild 1/100 files |
| Config change | 0% | Rebuild all |
| No changes | 100% | Rebuild 0/100 files |

### Example: C++ Project

Project: 500 sources, 200 headers
- Full build: 500 compilations (~10 minutes)
- Header change (10%): 50 compilations (~1 minute)
- Source file change: 1 compilation (~1 second)

## Caching Layers

```
┌─────────────────────────────────┐
│  Layer 1: Action Cache          │ ← Per-file compilation cache
│  - Caches individual compiles   │
│  - Input hash validation        │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│  Layer 2: Dependency Cache      │ ← File-to-file dependencies
│  - Tracks include/import graph  │
│  - Determines affected files    │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│  Layer 3: Target Cache          │ ← Whole target cache
│  - Caches final outputs         │
│  - Fast path for unchanged      │
└─────────────────────────────────┘
```

## Best Practices

### Enable Incremental Compilation

```d
BuildContext context;
context.incrementalEnabled = true;
context.depRecorder = (source, deps) {
    depCache.recordDependencies(source, deps);
};
```

### Use Watch Mode

```bash
bldr build --watch --incremental
```

### Configure Include Paths

```d
auto analyzer = new CppDependencyAnalyzer([
    "include",
    "src",
    "/usr/local/include"
]);
```

### Periodic Cache Cleanup

```bash
bldr clean --incremental-cache
```

### CI/CD

```bash
# Development
bldr build --incremental

# CI (full with caching for reproducibility)
bldr build --strategy=full
```

## Limitations

### Current Limitations

1. **C++ Macros**: Macro changes in headers may not trigger correct rebuilds
2. **Templates**: Template changes may not track all instantiation sites
3. **Dynamic Imports**: Runtime-determined imports not tracked statically
4. **Generated Code**: Generated code dependencies require explicit marking

### Storage Format

Binary format for efficient I/O:
- Version byte
- Entry count
- For each entry: source path, dependency count, dependencies, hashes, timestamp

### Change Detection

Two-phase:
1. **Fast Path**: Check metadata (mtime) for quick filtering
2. **Slow Path**: Compute content hash for definitive validation

### Transitive Analysis

Breadth-first search for transitive dependencies:

```d
string[] getTransitiveDependencies(string source) {
    queue = [source];
    visited = [];
    while (!queue.empty) {
        current = queue.dequeue();
        deps = getDependencies(current);
        foreach (dep; deps.filter!(d => d !in visited && !isExternal(d))) {
            queue.enqueue(dep);
            visited.add(dep);
        }
    }
    return visited;
}
```

## Related Documentation

- [Action Caching](caching.md)
- [Graph Cache](graphcache.md)
- [Watch Mode](../user-guides/watch.md)
- [Performance](performance.md)
