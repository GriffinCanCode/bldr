# AST Analysis Infrastructure

Language-agnostic infrastructure for AST-level analysis and symbol tracking.

## Purpose

Provides common interfaces and utilities for parsing source code into Abstract Syntax Trees (ASTs) and extracting symbol-level information for fine-grained incremental compilation.

## Modules

### parser.d
Core AST parser infrastructure:
- `IASTParser` - Language-agnostic parser interface
- `BaseASTParser` - Base implementation with common functionality
- `ASTParserRegistry` - Registry for managing language-specific parsers
- `initializeASTParsers()` - Initialize all available parsers

## Architecture

```
IASTParser (interface)
    ↑
    |
BaseASTParser (abstract)
    ↑
    |
    └── TreeSitterParser (universal, 28+ languages)
        ├── C/C++ via tree-sitter-cpp
        ├── Python via tree-sitter-python  
        ├── Java via tree-sitter-java
        ├── TypeScript via tree-sitter-typescript
        └── ... 20+ more languages
```

## Usage

### Implementing a Parser

```d
import infrastructure.analysis.ast.parser;
import engine.caching.incremental.ast_dependency;

class MyLanguageParser : BaseASTParser
{
    this()
    {
        super("MyLanguage", [".mylang"]);
    }
    
    override BuildResult!FileAST parseFile(string filePath) @system
    {
        // Read and parse file
        auto content = readText(filePath);
        return parseContent(content, filePath);
    }
    
    override BuildResult!FileAST parseContent(string content, string filePath) @system
    {
        FileAST ast;
        ast.filePath = filePath;
        ast.fileHash = FastHash.hashString(content);
        
        // Extract symbols from content
        ast.symbols = extractSymbols(content);
        
        return BuildResult!FileAST.ok(ast);
    }
    
    private ASTSymbol[] extractSymbols(string content)
    {
        // Language-specific symbol extraction
        // ...
    }
}
```

### Registering a Parser

```d
// In your parser module
void registerMyLanguageParser()
{
    auto registry = ASTParserRegistry.instance();
    registry.registerParser(new MyLanguageParser());
}

// Call during initialization
initializeASTParsers();  // Registers all parsers
```

### Using the Registry

```d
auto registry = ASTParserRegistry.instance();

// Check if we can parse a file
if (registry.canParse("myfile.cpp"))
{
    auto parserResult = registry.getParser("myfile.cpp");
    if (parserResult.isOk)
    {
        auto parser = parserResult.unwrap();
        auto astResult = parser.parseFile("myfile.cpp");
        // Use AST...
    }
}
```

## Symbol Types

Supported symbol types (from `engine.caching.incremental.ast_dependency`):
- `Class` - Class definitions
- `Struct` - Struct definitions
- `Function` - Standalone functions
- `Method` - Class/struct methods
- `Field` - Class/struct fields
- `Enum` - Enum definitions
- `Typedef` - Type aliases
- `Namespace` - Namespace/package/module definitions
- `Template` - Template/generic definitions
- `Variable` - Global variables

## Best Practices

### Parser Implementation

1. **Robustness**: Handle malformed code gracefully
   ```d
   try {
       // Parse code
   } catch (Exception e) {
       return Result.err(new ParseError(...));
   }
   ```

2. **Performance**: Cache expensive operations
   ```d
   private Regex!char cachedPattern;
   static this() { cachedPattern = regex(...); }
   ```

3. **Accuracy**: Validate extracted information
   ```d
   if (symbol.startLine > symbol.endLine)
       Logger.warning("Invalid symbol bounds");
   ```

4. **Testing**: Provide comprehensive tests
   ```d
   unittest {
       auto parser = new MyParser();
       auto result = parser.parseContent(testCode, "test.ext");
       assert(result.isOk);
   }
   ```

### Symbol Extraction

1. **Content Hashing**: Hash symbol implementation for change detection
   ```d
   symbol.contentHash = hashSymbolContent(lines, startLine, endLine);
   ```

2. **Dependencies**: Track what symbols depend on
   ```d
   symbol.dependencies = extractDependencies(symbolContent);
   symbol.usedTypes = extractUsedTypes(symbolContent);
   ```

3. **Visibility**: Mark public vs private symbols
   ```d
   symbol.isPublic = determineVisibility(symbolDecl);
   ```

## Integration with Incremental Compilation

The AST analysis infrastructure integrates with:

1. **AST Dependency Cache** (`engine.caching.incremental.ast_dependency`)
   - Stores parsed ASTs persistently
   - Tracks symbol-level dependencies

2. **AST Incremental Engine** (`engine.compilation.incremental.ast_engine`)
   - Uses parsed ASTs for change analysis
   - Determines minimal rebuild sets

3. **Language Builders** (e.g., `languages.compiled.cpp.builders.incremental`)
   - Integrate AST-level tracking into compilation pipeline
   - Fall back to file-level when appropriate

## Future Enhancements

1. **Semantic Analysis**: Beyond syntax, understand semantics
2. **LSP Integration**: Use Language Server Protocol for accurate parsing
3. **Parallel Parsing**: Parse multiple files concurrently
4. **Incremental Parsing**: Reparse only changed portions of files
5. **Type Resolution**: Resolve types across file boundaries

## See Also

- [AST-Level Incremental Compilation](../../../docs/features/ast-incremental.md)
- [Tree-sitter Integration](../parsing/treesitter/README.md)
- [AST Dependency Cache](../../engine/caching/incremental/ast_dependency.d)
- [Language Configurations](../parsing/configs/README.md)

