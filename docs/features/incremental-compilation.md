# Incremental Compilation

Module-level incremental compilation system that minimizes rebuilds by tracking file-level dependencies and recompiling only affected source files when dependencies change.

## Overview

Builder's incremental compilation system extends beyond action-level caching to provide sophisticated, language-aware dependency tracking. When a header file or module changes, only the source files that transitively depend on it are recompiled, dramatically reducing build times for large projects.

## Architecture

### Core Components

1. **Dependency Cache** (`source/caching/incremental/dependency.d`)
   - Tracks file-to-file dependencies
   - Persists dependency graphs across builds
   - Analyzes which files need recompilation based on changes

2. **Incremental Engine** (`source/compilation/incremental/engine.d`)
   - Orchestrates minimal rebuild determination
   - Integrates with ActionCache for dual-level optimization
   - Supports multiple compilation strategies

3. **Language Analyzers** (`source/languages/*/analysis/incremental.d`)
   - Language-specific dependency extraction
   - Resolves imports/includes to absolute file paths
   - Filters external dependencies (standard libraries, third-party packages)

### How It Works

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

## Supported Languages

### C++
- Header dependency tracking via `#include` analysis
- Resolves headers through include paths
- Filters standard library headers (STL, C standard library)
- Tracks transitive dependencies

```d
// Example: C++ incremental compilation
auto analyzer = new CppDependencyAnalyzer(["/path/to/include"]);
auto deps = analyzer.analyzeDependencies("main.cpp");
// Returns: ["header.h", "utils.h"] (resolved to absolute paths)
```

### D
- Module dependency tracking via `import` statements
- Resolves module names to source files
- Filters Phobos and Druntime modules
- Supports package.d files

```d
auto analyzer = new DDependencyAnalyzer("/project/root", ["/path/to/imports"]);
auto deps = analyzer.analyzeDependencies("main.d");
// Returns: ["mymodule.d", "utils/package.d"]
```

### Rust
- Uses Cargo metadata for accurate dependency tracking
- Parses `mod` and `use` statements
- Resolves modules following Rust's file structure rules
- Filters standard library crates

```d
auto analyzer = new RustDependencyAnalyzer("/path/to/rust/project");
auto deps = analyzer.analyzeDependencies("main.rs");
// Returns: ["module.rs", "utils/mod.rs"]
```

### Go
- Detects module path from `go.mod`
- Parses import statements (single and block)
- Resolves imports to package directories
- Filters standard library packages

```d
auto analyzer = new GoDependencyAnalyzer("/path/to/go/module");
auto deps = analyzer.analyzeDependencies("main.go");
// Returns: ["package/file1.go", "package/file2.go"]
```

### TypeScript
- Loads tsconfig.json for configuration
- Parses import/export/require statements
- Resolves relative and absolute imports
- Filters node_modules dependencies
- Supports multiple file extensions (.ts, .tsx, .d.ts, .js, .jsx)

```d
auto analyzer = new TypeScriptDependencyAnalyzer("/path/to/project");
auto deps = analyzer.analyzeDependencies("main.ts");
// Returns: ["./module.ts", "./utils/index.ts"]
```

### Java
- Tracks class dependencies via import statements
- Resolves qualified class names to source files
- Filters JDK standard library
- Supports multiple source paths

```d
auto analyzer = new JavaDependencyAnalyzer("/project/root", ["src/main/java"]);
auto deps = analyzer.analyzeDependencies("Main.java");
// Returns: ["com/example/Module.java", "com/example/Utils.java"]
```

## Usage

### Basic Example

```d
import caching.incremental.dependency;
import caching.actions.action;
import compilation.incremental.engine;

// Initialize caches
auto depCache = new DependencyCache(".builder-cache/incremental");
auto actionCache = new ActionCache(".builder-cache/actions");

// Create incremental engine
auto engine = new IncrementalEngine(depCache, actionCache);

// Determine what needs rebuilding
auto result = engine.determineRebuildSet(
    allSourceFiles,
    changedFiles,
    (file) => makeActionId(file),
    (file) => makeMetadata(file)
);

// Compile only necessary files
foreach (file; result.filesToCompile)
{
    auto deps = analyzer.analyzeDependencies(file);
    compile(file);
    
    // Record successful compilation
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

### Integration with Language Handlers

Language handlers can use the BuildContext to record dependencies:

```d
override Result!(string, BuildError) buildWithContext(BuildContext context)
{
    if (context.hasIncremental())
    {
        // Analyze dependencies for each source file
        foreach (source; context.target.sources)
        {
            auto deps = analyzer.analyzeDependencies(source);
            if (deps.isOk)
            {
                // Record dependencies for incremental compilation
                context.recordDependencies(source, deps.unwrap());
            }
        }
    }
    
    // Continue with compilation...
}
```

### Advanced: Custom Dependency Analyzer

Implement the `DependencyAnalyzer` interface for custom languages:

```d
class MyLanguageAnalyzer : BaseDependencyAnalyzer
{
    override Result!(string[], BuildError) analyzeDependencies(
        string sourceFile,
        string[] searchPaths = []
    ) @system
    {
        // 1. Parse source file for import/require statements
        auto imports = parseImports(sourceFile);
        
        // 2. Resolve to absolute file paths
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
        
        return Result!(string[], BuildError).ok(resolved);
    }
    
    override bool isExternalDependency(string importPath) @system
    {
        // Determine if this is a standard library or third-party dependency
        return importPath.startsWith("std.") || 
               importPath.canFind("node_modules");
    }
}
```

## Compilation Strategies

The incremental engine supports three strategies:

### Full
Rebuild everything regardless of caches or dependencies.
```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Full
);
```

### Incremental (Default)
Rebuild files with action cache misses or dependency changes, including transitive dependents.
```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Incremental
);
```

### Minimal
Rebuild only files that directly changed or have action cache misses. Does not transitively rebuild dependents.
```d
auto engine = new IncrementalEngine(
    depCache, actionCache, CompilationStrategy.Minimal
);
```

## Performance

### Reduction Rates

Typical reduction rates (percentage of files that don't need recompilation):

| Scenario | Reduction | Example |
|----------|-----------|---------|
| Header change | 70-90% | Changed 1 header, recompile 10/100 files |
| Source change | 90-99% | Changed 1 source, recompile 1/100 files |
| Config change | 0% | Changed flags, recompile all |
| No changes | 100% | No files changed, recompile 0/100 files |

### C++ Project Example

Project: 500 source files, 200 headers
- Full build: 500 compilations (~10 minutes)
- Header change affecting 10%: 50 compilations (~1 minute)
- Source file change: 1 compilation (~1 second)
- **90-99% reduction in rebuild time for typical changes**

## Caching Layers

Builder uses a three-tier caching strategy:

```
┌─────────────────────────────────┐
│  Layer 1: Action Cache          │ ← Per-file compilation cache
│  - Caches individual compile    │
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

### 1. Enable Incremental Compilation

```d
BuildContext context;
context.incrementalEnabled = true;
context.depRecorder = (source, deps) {
    depCache.recordDependencies(source, deps);
};
```

### 2. Use Watch Mode

Combine with watch mode for optimal developer experience:
```bash
bldr build --watch --incremental
```

### 3. Configure Include/Import Paths

Ensure analyzers have correct search paths:
```d
auto analyzer = new CppDependencyAnalyzer([
    "include",
    "src",
    "/usr/local/include"
]);
```

### 4. Periodic Cache Cleanup

Dependency caches can grow over time. Clear periodically:
```bash
bldr clean --incremental-cache
```

### 5. CI/CD Integration

For CI builds, consider full rebuilds with caching:
```bash
# Development: incremental
bldr build --incremental

# CI: full with caching for reproducibility
bldr build --strategy=full
```

## Limitations

### Current Limitations

1. **Macro Changes**: C++ macro changes in headers may not trigger correct rebuilds
2. **Template Instantiations**: Template changes may not track all instantiation sites
3. **Dynamic Imports**: Runtime-determined imports cannot be tracked statically
4. **Build Script Generation**: Generated code dependencies require explicit marking

### Workarounds

For macro-heavy code:
```d
// Mark target as always rebuild if macros change
context.target.langConfig["rebuild_on_macro_change"] = "true";
```

For generated code:
```d
// Use discovery system to declare generated dependencies
auto discovery = DiscoveryPatterns.codeGeneration(
    originTarget,
    generatedFiles,
    "generated"
);
```

## Implementation Details

### Dependency Cache Storage

Binary format for efficient I/O:
- Version byte
- Entry count
- For each entry:
  - Source file path (length-prefixed string)
  - Dependency count
  - Dependency paths (length-prefixed strings)
  - Source hash
  - Dependency hashes
  - Timestamp (64-bit)

### Change Detection

Two-phase algorithm:
1. **Fast Path**: Check metadata (mtime) for quick filtering
2. **Slow Path**: Compute content hash for definitive validation

### Transitive Analysis

Uses breadth-first search to find all transitive dependencies:
```d
string[] getTransitiveDependencies(string source) {
    queue = [source];
    visited = [];
    while (!queue.empty) {
        current = queue.dequeue();
        deps = getDependencies(current);
        foreach (dep; deps) {
            if (dep not in visited) {
                queue.enqueue(dep);
                visited.add(dep);
            }
        }
    }
    return visited;
}
```

## See Also

- [Action Caching](caching.md) - Per-action compilation caching
- [Graph Cache](graphcache.md) - Build graph caching
- [Watch Mode](watch.md) - Continuous incremental builds
- [Performance](performance.md) - Performance optimization strategies

