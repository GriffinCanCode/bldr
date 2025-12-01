# AST-Level Incremental Compilation Example

This example demonstrates AST-level incremental compilation with symbol-level dependency tracking.

## What It Demonstrates

- Fine-grained incremental compilation at class/function level
- Symbol-level change detection
- Dramatic build time improvements for large codebases

## Structure

```
src/
  ├── core/
  │   ├── base.h       - Base classes
  │   ├── base.cpp
  │   ├── utils.h      - Utility functions
  │   └── utils.cpp
  ├── features/
  │   ├── feature1.h   - Feature 1 (uses base)
  │   ├── feature1.cpp
  │   ├── feature2.h   - Feature 2 (uses base)
  │   └── feature2.cpp
  └── main.cpp         - Entry point
```

## Running

```bash
# Initial build - parses all ASTs
cd examples/ast-incremental-example
bldr build //app

# Modify a single method in base.h
echo "// Modified" >> src/core/base.h

# Rebuild - only affected symbols recompiled
bldr build //app

# Check statistics
bldr query //app --ast-stats
```

## Expected Results

### Initial Build
```
Parsing 8 C++ files...
Extracted 45 symbols
Building 8 files...
Build time: 12.3s
```

### Incremental Build (after modifying 1 method)
```
AST-level analysis: 1/45 symbols changed (2.2% granularity)
Files affected: 2 (feature1.cpp, main.cpp)
Rebuilding 2 files...
Build time: 2.1s (83% faster)
```

### File-Level Incremental (for comparison)
```
File-level analysis: base.h modified
Files affected: 6 (all files including base.h)
Rebuilding 6 files...
Build time: 7.8s (37% faster than full)
```

## Key Points

1. **AST-level is 4x faster** than file-level for isolated changes
2. **Granularity metrics** show exactly what percentage of symbols changed
3. **Automatic fallback** to file-level if AST parsing fails
4. **Persistent cache** speeds up subsequent builds

## Experiment

Try these modifications to see AST-level tracking in action:

1. **Modify a rarely-used method**: Fast rebuild
   ```bash
   # Edit src/core/utils.cpp - change debugPrint() implementation
   bldr build //app  # Only rebuilds files calling debugPrint()
   ```

2. **Modify a widely-used method**: Slower rebuild
   ```bash
   # Edit src/core/base.cpp - change Base::process() implementation
   bldr build //app  # Rebuilds all files using Base::process()
   ```

3. **Add a new class**: No rebuild of existing code
   ```bash
   # Add src/features/feature3.cpp with new Feature3 class
   bldr build //app  # Only compiles the new file
   ```

## Configuration

In `Builderfile`:

```d
target("app") {
    language = "cpp"
    sources = glob("src/**/*.cpp")
    
    // AST-level incremental is enabled by default
    // To disable:
    // incremental_level = "file"  // Use file-level only
    
    // To enable debug logging:
    // ast_debug = true
}
```

## Benchmarking

Compare strategies:

```bash
# Full rebuild
bldr clean && bldr build //app --strategy=full

# File-level incremental
bldr clean && bldr build //app --strategy=file-level

# AST-level incremental (default)
bldr clean && bldr build //app --strategy=ast-level

# Hybrid (automatic selection)
bldr clean && bldr build //app --strategy=hybrid
```

## See Also

- [AST-Level Incremental Documentation](../../docs/features/ast-incremental.md)
- [C++ Compilation](../../docs/features/languages.md#cpp)
- [Performance Tuning](../../docs/features/performance.md)

