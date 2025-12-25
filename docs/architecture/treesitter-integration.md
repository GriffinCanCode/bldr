# Tree-sitter Integration Architecture

**Status:** Implemented  
**Version:** 1.0

---

## Overview

Builder uses tree-sitter for AST parsing across 25+ programming languages. This provides:

- **Grammar-based parsing** instead of regex heuristics
- **Incremental parsing** for watch mode (10-100x faster re-parse)
- **Error tolerance** for partially valid code
- **Symbol-level incremental compilation** across all supported languages

---

## Architecture

```
source/infrastructure/parsing/treesitter/
├── bindings.d       # C API bindings
├── config.d         # Language configurations
├── parser.d         # TreeSitterParser class
├── registry.d       # Grammar registry
├── loader.d         # Grammar loading
├── deps.d           # Dependency extraction
├── incremental.d    # Parse tree caching
├── adapter.d        # Integration with AST registry
└── grammars/        # Per-language grammar modules
    ├── python.d
    ├── java.d
    ├── typescript.d
    ├── javascript.d
    ├── go.d
    ├── rust.d
    ├── c.d
    ├── cpp.d
    ├── csharp.d
    ├── kotlin.d
    ├── swift.d
    ├── ruby.d
    ├── php.d
    ├── lua.d
    ├── perl.d
    ├── r.d
    ├── haskell.d
    ├── ocaml.d
    ├── scala.d
    ├── nim.d
    ├── zig.d
    ├── elixir.d
    ├── elm.d
    ├── fsharp.d
    ├── css.d
    └── protobuf.d
```

---

## Components

### C API Bindings (`bindings.d`)

Minimal tree-sitter C API surface:

```d
extern(C) struct TSParser;
extern(C) struct TSTree;
extern(C) struct TSNode;
extern(C) struct TSLanguage;

extern(C) @system nothrow @nogc:
TSParser* ts_parser_new();
void ts_parser_delete(TSParser*);
bool ts_parser_set_language(TSParser*, const(TSLanguage)*);
TSTree* ts_parser_parse_string(TSParser*, const(TSTree)*, const(char)*, uint);
TSNode ts_tree_root_node(const(TSTree)*);
void ts_tree_edit(TSTree*, const(TSInputEdit)*);
// ...
```

RAII wrappers provided for memory safety:
- `Parser` - wraps `TSParser*`
- `Tree` - wraps `TSTree*`

### Language Configuration (`config.d`)

Each language has a configuration mapping tree-sitter node types to Builder symbols:

```d
struct LanguageConfig {
    string languageId;           // "python"
    string displayName;          // "Python"
    string[] extensions;         // [".py"]
    
    SymbolConfig symbols;        // Node type → SymbolType mapping
    VisibilityConfig visibility; // Public/private patterns
    DependencyConfig dependencies; // Import extraction
}

struct SymbolConfig {
    // Maps tree-sitter node types to Builder symbol types
    // e.g., "class_definition" → SymbolType.Class
    SymbolType[string] nodeTypeMap;
    string[] nameNodes;          // Nodes containing symbol name
}
```

Built-in configurations for: Python, Java, TypeScript, JavaScript, Go, Rust, C, C++, C#, Kotlin, Swift, Ruby, PHP, Lua, Perl, R, Haskell, OCaml, Scala, Nim, Zig, Elixir, Elm, F#, CSS, Protobuf.

### Universal Parser (`parser.d`)

```d
final class TreeSitterParser : BaseASTParser {
    private const(TSLanguage)* grammar;
    private LanguageConfig config;
    private bool incrementalEnabled;
    
    /// Parse file (full parse)
    override BuildResult!FileAST parseFile(string filePath) @system;
    
    /// Parse with incremental edits (watch mode)
    BuildResult!FileAST parseContentWithEdits(
        string content,
        string filePath,
        const TextEdit[] edits
    ) @system;
}
```

The parser:
1. Creates a tree-sitter parser with the language grammar
2. Parses source to tree-sitter AST
3. Traverses nodes to extract symbols
4. Maps to Builder's `FileAST` format

### Incremental Cache (`incremental.d`)

```d
final class IncrementalTreeCache {
    /// Get or parse tree for file
    BuildResult!CachedTree parseIncremental(
        string filePath,
        string content,
        string languageId,
        const TextEdit[] edits
    ) @system;
    
    /// Register grammar for language
    void registerGrammar(string languageId, const(TSLanguage)* grammar);
    
    /// Invalidate cache for file
    void invalidate(string filePath);
}
```

When edits are provided:
1. Retrieves cached tree if available
2. Applies edits to tree using `ts_tree_edit()`
3. Re-parses incrementally (only changed portions)
4. Caches result

### Registry (`registry.d`)

```d
final class TreeSitterRegistry {
    /// Get language grammar
    const(TSLanguage)* getGrammar(string languageId) @system;
    
    /// Check if language supported
    bool hasLanguage(string languageId);
    
    /// List all supported languages
    string[] supportedLanguages();
}
```

Grammars are lazily loaded on first use.

---

## Symbol Extraction

### Process

1. Parse source with tree-sitter
2. Walk AST nodes
3. For each node type in config:
   - Extract symbol name
   - Determine visibility (public/private)
   - Extract dependencies/imports
4. Build `FileAST` with symbols

### Example: Python

```python
class MyClass:
    def method(self):
        pass

def top_level():
    pass
```

Extracted symbols:
- `MyClass` (Class, public)
- `method` (Function, private - nested)
- `top_level` (Function, public)

### Visibility Rules

Languages define visibility via:
- **Modifiers**: `public`, `private`, `export`
- **Name patterns**: `_private` (Python), `lowerCase` (Go)
- **Position**: Top-level vs nested

---

## Dependency Extraction

The `deps.d` module extracts imports:

```d
struct DependencyExtractor {
    string[] extractDependencies(TSNode root, string languageId) @system;
}
```

Language-specific patterns:
- **Python**: `import X`, `from X import Y`
- **Java**: `import pkg.Class`
- **TypeScript**: `import { X } from 'Y'`
- **Go**: `import "pkg"`

---

## Integration

### With AST Parser Registry

```d
void registerTreeSitterParsers() @system {
    auto registry = ASTParserRegistry.instance();
    auto tsRegistry = TreeSitterRegistry.instance();
    
    foreach (lang; tsRegistry.supportedLanguages()) {
        auto config = getLanguageConfig(lang);
        auto grammar = tsRegistry.getGrammar(lang);
        registry.registerParser(new TreeSitterParser(grammar, config));
    }
}
```

### With Watch Mode

```d
// On file change
auto edits = calculateTextEdits(oldContent, newContent);
auto result = parser.parseContentWithEdits(newContent, path, edits);
```

---

## Performance

### Parse Speed

| Operation | Speed |
|-----------|-------|
| Initial parse | 500-1000 LOC/ms |
| Incremental | 10-100x faster (changed portions only) |

### Memory

| Component | Size |
|-----------|------|
| Grammar | ~1-5 MB per language |
| Parse tree | ~50 bytes per node |
| Typical file | 10-50 KB tree |

### Incremental Benefit

For a small edit in a 10,000 line file:
- **Full parse**: ~10ms
- **Incremental**: <1ms

---

## Adding a New Language

1. **Add grammar module** in `grammars/`:

```d
// grammars/newlang.d
module infrastructure.parsing.treesitter.grammars.newlang;

extern(C) const(TSLanguage)* tree_sitter_newlang() @system nothrow @nogc;
```

2. **Add configuration** in `config.d`:

```d
LanguageConfig newlangConfig = {
    languageId: "newlang",
    displayName: "NewLang",
    extensions: [".nl"],
    symbols: SymbolConfig(
        ["function_definition": SymbolType.Function,
         "class_definition": SymbolType.Class]
    )
};
```

3. **Register grammar** in `registry.d`

4. **Build and link** the grammar shared library

---

## Supported Languages

| Language | Extensions | Status |
|----------|------------|--------|
| Python | `.py` | ✅ |
| Java | `.java` | ✅ |
| TypeScript | `.ts`, `.tsx` | ✅ |
| JavaScript | `.js`, `.jsx` | ✅ |
| Go | `.go` | ✅ |
| Rust | `.rs` | ✅ |
| C | `.c`, `.h` | ✅ |
| C++ | `.cpp`, `.hpp`, `.cc` | ✅ |
| C# | `.cs` | ✅ |
| Kotlin | `.kt` | ✅ |
| Swift | `.swift` | ✅ |
| Ruby | `.rb` | ✅ |
| PHP | `.php` | ✅ |
| Lua | `.lua` | ✅ |
| Perl | `.pl`, `.pm` | ✅ |
| R | `.R`, `.r` | ✅ |
| Haskell | `.hs` | ✅ |
| OCaml | `.ml` | ✅ |
| Scala | `.scala` | ✅ |
| Nim | `.nim` | ✅ |
| Zig | `.zig` | ✅ |
| Elixir | `.ex`, `.exs` | ✅ |
| Elm | `.elm` | ✅ |
| F# | `.fs` | ✅ |
| CSS | `.css` | ✅ |
| Protobuf | `.proto` | ✅ |

---

## Related Documentation

- [Tree-sitter README](../../source/infrastructure/parsing/treesitter/README.md)
- [Parser Implementation](../../source/infrastructure/parsing/treesitter/parser.d)
- [Grammar Modules](../../source/infrastructure/parsing/treesitter/grammars/)
- [Incremental Compilation](incremental-design.md)
