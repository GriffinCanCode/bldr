# Builderfile DSL Specification

Builder uses a D-based DSL for build configuration. This document describes the syntax and semantics.

## Overview

The Builderfile DSL provides:
- Clean syntax for defining build targets
- Type-safe parsing with detailed error messages
- Zero-allocation lexing for primitives
- Result monad error handling

## Syntax

### Basic Structure

```d
target("name") {
    field: value;
    field: value;
}
```

### Target Declaration

```d
target("my-app") {
    type: executable;
    language: python;
    sources: ["main.py"];
}
```

### Fields

#### Required Fields

**`type`** - Target type
```d
type: executable;  // Produces an executable binary
type: library;     // Produces a library
type: test;        // Produces a test target
type: custom;      // Custom build logic
type: shell;       // Run arbitrary shell commands (alias: genrule)
```

**`sources`** - Source files
```d
sources: ["main.py"];
sources: ["src/**/*.py"];  // Glob patterns supported
sources: [
    "file1.py",
    "file2.py",
    "file3.py"
];
```

#### Optional Fields

**`language`** - Programming language (optional, inferred from sources)
```d
language: python;
language: javascript;
language: go;
language: rust;
language: d;
language: c;
language: cpp;
language: java;
language: typescript;
```

**`deps`** - Dependencies on other targets
```d
deps: [":lib"];              // Local dependency
deps: ["//path/to:target"];  // External dependency
deps: [
    ":utils",
    "//lib:core",
    "//third_party:external"
];
```

**`flags`** - Compiler/build flags
```d
flags: ["-O2"];
flags: ["-O2", "-Wall", "-Werror"];
```

**`env`** - Environment variables
```d
env: {"PATH": "/usr/bin"};
env: {
    "PYTHONPATH": "/usr/lib/python",
    "DEBUG": "1"
};
```

**`output`** - Output path
```d
output: "bin/app";
output: "dist/executable";
```

**`includes`** - Include directories
```d
includes: ["include"];
includes: ["include", "third_party/include"];
```

**`config`** - Language-specific configuration
```d
config: {
    "mode": "bundle",
    "bundler": "esbuild"
};
```

**`command`** - Shell command (for shell/genrule targets)
```d
command: "gleam build";
command: "npm run build";
```

**`workdir`** - Working directory for command execution
```d
workdir: "frontend";
```

**`root`** - Root directory for language toolchains
```d
root: "./scorer";  // For Zig projects in subdirectories
```

## Data Types

### Strings
```d
"simple string"
'single quotes'
"escaped \"quotes\""
"newline\nand\ttab"
```

### Arrays
```d
[]                          // Empty array
["single"]                  // Single element
["a", "b", "c"]            // Multiple elements
```

### Maps
```d
{}                           // Empty map
{"key": "value"}            // Single pair
{"k1": "v1", "k2": "v2"}   // Multiple pairs
```

### Identifiers
```d
executable
library
python
javascript
```

## Comments

```d
// Line comment (C++ style)

/* Block comment
   spanning multiple lines */

# Shell-style comment
```

## Examples

### Simple Executable
```d
target("hello") {
    type: executable;
    language: python;
    sources: ["main.py"];
}
```

### Library with Dependencies
```d
target("utils") {
    type: library;
    language: python;
    sources: ["lib/utils.py"];
}

target("app") {
    type: executable;
    language: python;
    sources: ["main.py"];
    deps: [":utils"];
}
```

### Shell/Genrule Target
```d
target("gleam-build") {
    type: shell;
    command: "gleam build";
    workdir: "./gleam-project";
    sources: ["gleam-project/src/**/*.gleam"];
    output: "gleam-project/build";
}
```

### JavaScript with Bundling
```d
target("bundle") {
    type: executable;
    language: javascript;
    sources: ["src/**/*.js"];
    output: "bundle.js";
    
    config: {
        "mode": "bundle",
        "bundler": "esbuild",
        "entry": "src/app.js",
        "platform": "browser",
        "format": "iife",
        "minify": true,
        "sourcemap": true,
        "target": "es2020"
    };
}
```

## Architecture

### Compilation Pipeline

1. **Lexical Analysis** (`config/parsing/lexer.d`)
   - Tokenizes source into typed tokens
   - Handles strings, numbers, identifiers, keywords
   - Filters comments
   - Tracks line/column for error reporting

2. **Syntax Analysis** (`config/parsing/unified.d`)
   - Recursive descent parser
   - Builds typed AST
   - Pratt parsing for expressions
   - Detailed error messages

3. **Semantic Analysis** (`config/parsing/unified.d`)
   - Validates AST structure
   - Type checking
   - Converts AST to Target objects
   - Language inference

4. **Integration** (`config/parsing/parser.d`)
   - Seamless fallback from JSON to DSL
   - Glob pattern expansion
   - Target name resolution

### AST Structure

```
BuildFile
  └─ Stmt[]
       ├─ TargetDecl
       │    ├─ name: string
       │    └─ fields: Field[]
       ├─ VarDecl (let/const)
       │    ├─ name: string
       │    └─ value: Expr
       ├─ FunctionDecl
       └─ ...
```

### Error Handling

All parsing operations return `Result!(T, BuildError)`:

```d
auto result = parseDSL(source, path, root);
if (result.isErr) {
    auto error = result.unwrapErr();
    writeln(error.toString());  // Detailed error with line/column
}
```

## Builderspace Files

Workspace-level configuration:

```d
workspace("name") {
    cacheDir: ".builder-cache";
    outputDir: "bin";
    parallel: true;
    maxJobs: 8;
    verbose: false;
    incremental: true;
    
    env: {
        "PYTHONPATH": "/usr/lib/python3.10"
    };
}
```

### Builderspace Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cacheDir` | string | `.builder-cache` | Cache storage directory |
| `outputDir` | string | `bin` | Default output directory |
| `parallel` | boolean | `true` | Enable parallel builds |
| `maxJobs` | number | `0` (auto) | Max parallel jobs |
| `verbose` | boolean | `false` | Verbose output |
| `incremental` | boolean | `true` | Enable incremental builds |
| `env` | map | `{}` | Global environment variables |

### Environment Precedence

Target-specific settings override workspace settings:

```d
// Builderspace
workspace("my-app") {
    env: { "DEBUG": "0" };
}

// Builderfile
target("app") {
    type: executable;
    sources: ["main.py"];
    env: { "DEBUG": "1" };  // Overrides workspace
}
// Result: app gets DEBUG=1
```

## Token Types

| Category | Tokens |
|----------|--------|
| Literals | `Identifier`, `String`, `Number`, `True`, `False`, `Null` |
| Keywords | `Target`, `Repository`, `Type`, `Language`, `Sources`, `Deps`, `Flags`, `Env`, `Output`, `Includes`, `Config` |
| Programmability | `Let`, `Const`, `Fn`, `Macro`, `If`, `Else`, `For`, `In`, `Return`, `Import` |
| Types | `Executable`, `Library`, `Test`, `Custom` |
| Punctuation | `(`, `)`, `{`, `}`, `[`, `]`, `:`, `;`, `,`, `.` |
| Operators | `+`, `-`, `*`, `/`, `%`, `=`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`, `?`, `|` |

## Performance

| Phase | Complexity |
|-------|------------|
| Lexer | O(n) single-pass |
| Parser | O(n) recursive descent |
| Semantic Analysis | O(n) single-pass |

## JSON Compatibility

JSON format is still supported for backward compatibility:

```json
{
    "name": "app",
    "type": "executable",
    "language": "python",
    "sources": ["main.py"],
    "deps": [":utils"]
}
```

Detection is automatic based on file content.

## Source Files

| Component | File |
|-----------|------|
| Lexer | `source/infrastructure/config/parsing/lexer.d` |
| AST | `source/infrastructure/config/workspace/ast.d` |
| Unified Parser | `source/infrastructure/config/parsing/unified.d` |
| Integration | `source/infrastructure/config/parsing/parser.d` |
| Workspace Parser | `source/infrastructure/config/workspace/workspace.d` |
