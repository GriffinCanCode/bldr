# AST-Level Incremental Compilation

Incremental compilation system that tracks changes at the symbol level (classes, functions, methods) rather than file level, providing fine-grained rebuild optimization.

## Overview

Traditional incremental compilation tracks file-to-file dependencies: when `header.h` changes, all files that include it are recompiled. AST-level incremental compilation goes further by tracking symbol-level dependencies: when a single class in `header.h` changes, only code that uses that specific class is recompiled.

## Architecture

### Components

1. **AST Parser Interface** (`infrastructure/analysis/ast/parser.d`)
   - Language-agnostic interface (`IASTParser`) for AST extraction
   - Parser registry (`ASTParserRegistry`) for multiple languages
   - Base class with common functionality (`BaseASTParser`)

2. **Tree-sitter Integration** (`infrastructure/parsing/treesitter/`)
   - `registry.d` - Grammar registry and parser instantiation
   - `parser.d` - Tree-sitter parser wrapper implementing `IASTParser`
   - `config.d` - Language-specific symbol extraction configurations
   - `grammars/` - Per-language grammar configurations (C++, Rust, Go, Python, etc.)

3. **AST Dependency Cache** (`engine/caching/incremental/ast_dependency.d`)
   - Stores parsed AST representations (`FileAST`, `ASTSymbol`)
   - Symbol-to-symbol dependency tracking (`ASTDependency`)
   - Thread-safe operations via `Mutex`
   - Persistent storage via `ASTStorage`

4. **AST Incremental Engine** (`engine/compilation/incremental/ast_engine.d`)
   - `ASTIncrementalEngine` - Orchestrates AST-level change analysis
   - Determines minimal symbol rebuild set
   - `HybridIncrementalEngine` - Automatically chooses between AST-level and file-level

### Symbol Types

```d
enum SymbolType
{
    Class,
    Struct,
    Function,
    Method,
    Field,
    Enum,
    Typedef,
    Namespace,
    Template,
    Variable
}
```

### Flow

```
┌─────────────────┐
│  Source Change  │
└────────┬────────┘
         │
         ▼
┌──────────────────────┐
│   Parse Changed      │
│   Files via          │
│   Tree-sitter        │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Compare ASTs       │
│   (contentHash)      │
│   Detect Changed     │
│   Symbols            │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Find Dependent     │
│   Symbols via        │
│   ASTDependencyCache │
└────────┬─────────────┘
         │
         ▼
┌──────────────────────┐
│   Rebuild Only       │
│   Affected Files     │
└──────────────────────┘
```

## Symbol Tracking

Each symbol tracks:

```d
struct ASTSymbol
{
    string name;              // Symbol name
    SymbolType type;          // Class, Function, Method, etc.
    size_t startLine;         // Start line in source
    size_t endLine;           // End line in source
    string signature;         // Full declaration
    string contentHash;       // BLAKE3 hash of symbol content
    string[] dependencies;    // Symbols this depends on
    string[] usedTypes;       // Types referenced
    bool isPublic;            // Export visibility
}
```

### Change Detection

```d
// Original
class MyClass {
    int getValue() { return value; }  // contentHash: ABC123
    int value;
};

// Modified  
class MyClass {
    int getValue() { return value * 2; }  // contentHash: DEF456 (CHANGED)
    int value;
};

// Result: Only files using MyClass::getValue need recompilation
```

## Usage

### Automatic Detection

AST-level incremental compilation is automatically enabled when:
- Tree-sitter is available
- Project has ≥5 source files
- ≥50% of files have parsers available

```d
// HybridIncrementalEngine decides automatically
auto engine = new HybridIncrementalEngine(astEngine, enableAST: true);
auto result = engine.analyzeChanges(sourceFiles, changedFiles);
```

### Manual Control

```d
import engine.compilation.incremental.ast_engine;
import engine.caching.incremental.ast_dependency;

// Disable AST-level analysis
auto hybrid = new HybridIncrementalEngine(astEngine, enableAST: false);
```

### Command Line

```bash
# Build (AST-level used automatically when beneficial)
bldr build //my_app

# Clear AST cache
bldr clean --ast-cache
```

## Supported Languages

The following languages have tree-sitter grammar configurations:

- C, C++
- Rust
- Go
- Python
- JavaScript, TypeScript
- Java, Kotlin, Scala
- C#, F#
- Ruby
- PHP
- Lua
- Perl
- Swift
- Haskell
- OCaml
- Nim
- Zig
- R
- Elixir
- Elm
- CSS
- Protocol Buffers

**Note**: Grammar availability depends on tree-sitter library installation. Run `source/infrastructure/parsing/treesitter/setup.sh` to install.

## Performance

### When It Helps

1. Large files with multiple classes/functions
2. Frequently modified utility classes
3. Projects with >20 source files
4. Header-heavy codebases

### When It Doesn't Help

1. Small projects (<5 files)
2. Changes to widely-used base classes
3. Header-only libraries
4. Projects without clear symbol boundaries

### Overhead

- **First build**: Additional AST parsing time
- **Incremental builds**: Faster when symbol changes are localized
- **Cache size**: ~50-100 bytes per symbol

## Analysis Result

```d
struct ASTChangeAnalysis
{
    string[] filesToRebuild;              // Files needing recompilation
    string[string] symbolsToRecompile;    // File -> symbols list
    string[string] changeReasons;         // File -> reason for rebuild
    size_t changedSymbolCount;            // Total symbols changed
    size_t totalSymbolCount;              // Total symbols analyzed
    float granularity;                    // % of symbols needing recompilation
}
```

## Cache Storage

Binary format stored in `.builder-cache/ast-incremental/`:

```d
struct FileAST
{
    string filePath;          // Source file path
    string fileHash;          // BLAKE3 hash of file
    ASTSymbol[] symbols;      // Extracted symbols
    string[] includes;        // Header dependencies
    SysTime timestamp;        // Parse timestamp
}
```

## Limitations

1. **Tree-sitter Availability**: Requires tree-sitter library and grammars
2. **Language Coverage**: Not all language constructs are extracted
3. **Incremental Linking**: Still requires full link step
4. **External Build Systems**: Limited support when wrapping Make/CMake

## Configuration

Environment variables:

```bash
# Set AST cache directory
export BUILDER_AST_CACHE_DIR=".builder-cache/ast-incremental"

# Enable debug logging
export BUILDER_AST_DEBUG=1
```

## See Also

- [Incremental Compilation](incremental-compilation.md) - File-level incremental compilation
- [Caching](caching.md) - Action-level caching
- [Tree-sitter Integration](../architecture/treesitter-integration.md) - Parser implementation details
