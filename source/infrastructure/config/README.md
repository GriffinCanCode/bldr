# Config Package

Build configuration parsing, workspace management, and DSL interpretation for the Builder system.

## Architecture

```
config/
├── parsing/       # Lexical analysis and DSL parsing
│   ├── lexer.d    # Tokenization for Builderfile DSL
│   ├── parser.d   # Recursive descent parser
│   └── unified.d  # Unified parsing API
├── workspace/     # AST and workspace management
│   ├── ast.d      # Abstract syntax tree types
│   └── workspace.d # Workspace configuration
├── schema/        # Target and configuration schemas
│   └── schema.d   # TargetType, TargetLanguage enums
├── analysis/      # Semantic analysis
│   └── semantic.d # AST → Target transformation
├── caching/       # Parse cache for performance
│   ├── parse.d    # Parse result caching
│   ├── schema.d   # Cache schema definitions
│   ├── sqlite.d   # SQLite-backed cache storage
│   └── storage.d  # Storage abstractions
├── scripting/     # Tier 1 programmability (let, fn, for, if)
│   ├── builtins.d # Built-in functions
│   ├── evaluator.d # Expression evaluation
│   ├── expander.d # Variable expansion
│   ├── interpreter.d # Script interpretation
│   ├── scopemanager.d # Scope management
│   └── types.d    # Script type definitions
└── macros/        # Tier 2 programmability (D-based macros)
    ├── api.d      # Public macro API
    ├── compiler.d # Macro compilation
    ├── ctfe.d     # Compile-time function execution
    └── loader.d   # Macro loader
```

## Usage

```d
import infrastructure.config;

// Parse a Builderfile with the unified parser
auto result = parseDSL(source, filePath, workspaceRoot);
if (result.isOk) {
    auto targets = result.unwrap().targets;
}

// Access workspace configuration
auto workspace = new Workspace("path/to/project");
```

## Key Features

- **Builderfile DSL**: Custom configuration language with clean syntax
- **Two-tier programmability**: Scripting (let/fn/for/if) + D macros
- **Parse caching**: SQLite-backed cache for fast incremental parsing
- **Type-safe schemas**: TargetType, TargetLanguage enums with validation
- **Semantic analysis**: AST transformation to build targets
- **Workspace management**: Multi-project workspace support

