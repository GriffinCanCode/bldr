# AST-Level Incremental Compilation

Advanced incremental compilation system that tracks changes at the symbol level (classes, functions, methods) rather than file level, providing fine-grained rebuild optimization.

## Overview

Traditional incremental compilation tracks file-to-file dependencies: when `header.h` changes, all files that include it are recompiled. AST-level incremental compilation goes further by tracking symbol-level dependencies: when a single class in `header.h` changes, only code that uses that specific class is recompiled.

## Architecture

### Components

1. **AST Parser Interface** (`infrastructure/analysis/ast/parser.d`)
   - Language-agnostic interface for AST extraction
   - Parser registry for multiple languages
   - Extensible to any language with symbol structure

2. **C++ AST Parser** (`languages/compiled/cpp/analysis/ast_parser.d`)
   - Regex-based pattern matching for C++ constructs
   - Extracts classes, structs, functions, methods, namespaces
   - Tracks symbol signatures and content hashes

3. **AST Dependency Cache** (`engine/caching/incremental/ast_dependency.d`)
   - Stores parsed AST representations
   - Symbol-to-symbol dependency tracking
   - Persistent binary storage for fast load/save

4. **AST Incremental Engine** (`engine/compilation/incremental/ast_engine.d`)
   - Orchestrates AST-level change analysis
   - Determines minimal symbol rebuild set
   - Falls back to file-level when not beneficial

5. **Hybrid Engine** 
   - Automatically chooses between AST-level and file-level
   - Considers project size and parser availability
   - Seamless integration with existing incremental compilation

### How It Works

```
┌─────────────────┐
│  Source Change  │
└────────┬────────┘
         │
         ▼
┌──────────────────────┐
│   Parse Changed      │
│   Files to AST       │
│   Extract Symbols    │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Compare ASTs       │
│   Detect Changed     │
│   Symbols            │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Find Dependent     │
│   Symbols Across     │
│   All Files          │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Rebuild Only       │
│   Affected Symbols   │
└──────────────────────┘
```

## Benefits

### Granularity
- **File-level**: Change 1 line in header → recompile 50 files
- **AST-level**: Change 1 class in header → recompile only files using that class

### Statistics Example

```
Project: 100 C++ files, 500 classes
Change: Modified 1 method in 1 class

File-level incremental:
  - Files rebuilt: 15 (files including the header)
  - Time: 45 seconds

AST-level incremental:
  - Files rebuilt: 3 (only files using that specific class)
  - Symbols changed: 1/500 (0.2% granularity)
  - Time: 9 seconds
  - 80% faster than file-level
```

## Usage

### C++ Projects

AST-level incremental compilation is automatically enabled for C++ projects:

```d
// In your Builderfile
target("my_app") {
    language = "cpp"
    sources = glob("src/**/*.cpp")
    // AST-level tracking enabled by default
}
```

### Manual Control

Disable AST-level if needed:

```d
import languages.compiled.cpp.builders.incremental;

auto builder = new IncrementalCppBuilder(config, null, null, false); // false = disable AST
```

### Command Line

```bash
# Build with AST-level incremental compilation
bldr build //my_app

# Check AST cache statistics
bldr query //my_app --ast-stats

# Clear AST cache
bldr clean --ast-cache
```

## Supported Languages

Currently implemented:
- **C++** (classes, structs, functions, methods, namespaces, templates)

Planned:
- **Java** (classes, interfaces, methods, fields)
- **C#** (classes, structs, methods, properties)
- **TypeScript** (classes, interfaces, functions)
- **Go** (structs, functions, methods)
- **Rust** (structs, impl blocks, functions)

## Performance Characteristics

### Overhead
- **First build**: +5-10% (AST parsing overhead)
- **Incremental builds**: 2-10x faster than file-level
- **Cache size**: ~50-100 bytes per symbol
- **Parse time**: ~1-2ms per 1000 lines of code

### When It Helps Most
1. Large headers with multiple classes
2. Frequently modified utility classes
3. Template-heavy codebases
4. Projects with >20 source files

### When It Doesn't Help
1. Tiny projects (<5 files)
2. Changes to base classes used everywhere
3. Header-only libraries
4. Projects without clear symbol boundaries

## Implementation Details

### Symbol Tracking

Each symbol tracks:
- **Name**: Fully qualified name (e.g., `MyNamespace::MyClass::method`)
- **Type**: Class, Function, Method, Struct, etc.
- **Location**: Start/end line numbers
- **Signature**: Full declaration
- **Content Hash**: Hash of symbol implementation
- **Dependencies**: Other symbols referenced
- **Used Types**: Types used in the symbol

### Change Detection

```d
// Original
class MyClass {
    int getValue() { return value; }  // Symbol hash: ABC123
    int value;
};

// Modified  
class MyClass {
    int getValue() { return value * 2; }  // Symbol hash: DEF456 (CHANGED)
    int value;
};

// Result: Only MyClass::getValue marked as changed
// Files using MyClass but not calling getValue don't need recompilation
```

### Cache Format

Binary format for efficient storage:
```
[MAGIC: "ASTC"] [VERSION: 1]
[Entry Count: uint32]
For each entry:
  [File Path: string]
  [File Hash: string]
  [Symbol Count: uint32]
  For each symbol:
    [Name: string]
    [Type: uint8]
    [Lines: uint64, uint64]
    [Signature: string]
    [Hash: string]
    [Dependencies: string[]]
    [Used Types: string[]]
```

## Limitations

1. **C++ Parsing**: Uses regex patterns, not full compiler-grade parsing
   - May miss complex template instantiations
   - Doesn't handle all edge cases of C++ syntax
   
2. **Incremental Linking**: Still requires full link step when any object changes
   - Future: Implement incremental linking for further speedup
   
3. **Header-only Classes**: No benefit (no separate compilation units)

4. **Build System Integration**: Works best with Builder's native compilation
   - Limited support when wrapping external build systems (Make, CMake)

## Future Enhancements

1. **Function-level compilation**: Compile individual functions, not just files
2. **Incremental linking**: Link only changed object files
3. **Cross-file optimization aware**: Track inlining and optimization boundaries
4. **LSP Integration**: Use Language Server Protocol for better parsing
5. **Parallel AST parsing**: Parse multiple files concurrently
6. **Smart rebuilds**: Consider actual usage, not just dependencies

## Configuration

Environment variables:

```bash
# Enable/disable AST-level tracking
export BUILDER_AST_INCREMENTAL=1

# Set AST cache directory
export BUILDER_AST_CACHE_DIR=".builder-cache/ast"

# Set granularity threshold (min % symbols changed to use AST-level)
export BUILDER_AST_GRANULARITY_THRESHOLD=50

# Enable AST parsing debug logs
export BUILDER_AST_DEBUG=1
```

## Debugging

View AST cache contents:

```bash
# Show parsed symbols for a file
builder ast parse src/my_file.cpp

# Show symbol dependencies
builder ast deps src/my_file.cpp

# Show what would be rebuilt
builder ast analyze --dry-run

# Compare two AST snapshots
builder ast diff @before @after
```

## See Also

- [Incremental Compilation](incremental-compilation.md) - File-level incremental compilation
- [Caching](caching.md) - Action-level caching
- [Performance](performance.md) - Overall performance optimization strategies

