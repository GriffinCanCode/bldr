# Builderfile DSL Specification

The Builder system uses a modern D-based DSL for Builderfile configuration. This document describes the DSL syntax and semantics.

## Overview

The Builderfile DSL is designed to be:
- **Readable**: Clean, intuitive syntax for defining build targets
- **Type-safe**: Compile-time validation with sophisticated error messages
- **Extensible**: Easy to add new fields and target types
- **Efficient**: Zero-allocation parsing with Result monads for error handling

## Syntax

### Basic Structure

```d
target("name") {
    field: value;
    field: value;
}
```

### Target Declaration

Every Builderfile contains one or more target declarations:

```d
target("my-app") {
    type: executable;
    language: python;
    sources: ["main.py"];
}
```

### Fields

#### Required Fields

**`type`** - Target type (required)
```d
type: executable;  // Produces an executable binary
type: library;     // Produces a library
type: test;        // Produces a test target
type: custom;      // Custom build logic
type: shell;       // Run arbitrary shell commands (alias: genrule)
```

**`sources`** - Source files (required)
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
flags: [
    "-O2",
    "-march=native",
    "-fno-exceptions"
];
```

**`env`** - Environment variables
```d
env: {"PATH": "/usr/bin"};
env: {
    "PYTHONPATH": "/usr/lib/python",
    "DEBUG": "1",
    "OPTIMIZATION": "3"
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
includes: [
    "include",
    "third_party/include"
];
```

**`config`** - Language-specific configuration
```d
config: {
    "mode": "bundle",
    "bundler": "esbuild"
};
config: {
    "minify": true,
    "sourcemap": true,
    "target": "es2020"
};
```

This field allows passing language-specific configuration as a map. Each language handler interprets this differently:
- **JavaScript/TypeScript**: Bundler configuration (mode, bundler, platform, format, etc.)
- **Python**: Virtual environment, package manager settings
- **Go**: Build tags, GOOS, GOARCH
- **Rust**: Cargo features, target triple

**`command`** - Shell command to execute (for shell/genrule targets)
```d
command: "gleam build";
command: "npm run build";
command: "cargo build --release && cp target/release/myapp ./bin/";
```

**`workdir`** - Working directory for command execution
```d
workdir: "frontend";
workdir: "./packages/core";
```

**`root`** - Root directory for language toolchains
```d
root: "./scorer";         // For Zig projects in subdirectories
root: "packages/backend"; // Find build.zig relative to this path
```

This field is useful when your project files (like `build.zig`) are in a subdirectory.

## Data Types

### Strings

String literals use double or single quotes with escape sequences:

```d
"simple string"
'single quotes'
"escaped \"quotes\""
"newline\nand\ttab"
```

### Arrays

Arrays contain comma-separated values:

```d
[]                          // Empty array
["single"]                  // Single element
["a", "b", "c"]            // Multiple elements
[                          // Multi-line
    "element1",
    "element2",
    "element3"
]
```

### Maps

Maps contain key-value pairs:

```d
{}                                    // Empty map
{"key": "value"}                     // Single pair
{"k1": "v1", "k2": "v2"}            // Multiple pairs
{                                    // Multi-line
    "PATH": "/usr/bin",
    "HOME": "/home/user",
    "DEBUG": "1"
}
```

### Identifiers

Unquoted identifiers for keywords and enum values:

```d
executable
library
python
javascript
```

## Comments

Three comment styles are supported:

```d
// Line comment (C++ style)

/* Block comment
   spanning multiple lines */

# Shell-style comment
```

## Complete Examples

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

### Complex Multi-Language Project

```d
target("core") {
    type: library;
    language: rust;
    sources: ["src/**/*.rs"];
    flags: [
        "-C", "opt-level=3",
        "-C", "target-cpu=native"
    ];
}

target("bindings") {
    type: library;
    language: python;
    sources: ["bindings.py"];
    deps: [":core"];
}

target("application") {
    type: executable;
    language: python;
    sources: ["main.py"];
    deps: [
        ":core",
        ":bindings",
        "//third_party:helpers"
    ];
    env: {
        "PYTHONPATH": "/usr/lib/python3.10",
        "LD_LIBRARY_PATH": "/usr/local/lib"
    };
    output: "bin/app";
}
```

### Test Target

```d
target("tests") {
    type: test;
    language: python;
    sources: ["tests/**/*.py"];
    deps: [":app", ":utils"];
    env: {
        "TEST_MODE": "1"
    };
}
```

### Shell/Genrule Target (Arbitrary Commands)

Use `type: shell` (or `type: genrule`) to run arbitrary shell commands. This is useful for integrating languages not natively supported:

```d
target("gleam-build") {
    type: shell;
    command: "gleam build";
    workdir: "./gleam-project";
    sources: ["gleam-project/src/**/*.gleam"];
    output: "gleam-project/build";
}
```

```d
target("custom-codegen") {
    type: genrule;
    command: "python3 scripts/generate.py --out=src/generated";
    sources: ["schemas/*.yaml"];
    output: "src/generated";
    deps: [":schemas"];
}
```

### Zig Subdirectory Project

Use the `root` field when build.zig is in a subdirectory:

```d
target("scorer") {
    type: executable;
    language: zig;
    root: "./scorer";              // Directory containing build.zig
    sources: ["scorer/src/**/*.zig"];
    output: "bin/scorer";
}
```

### JavaScript/TypeScript with Bundling

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

**JavaScript Configuration Options:**
- `mode`: "node", "bundle", or "library"
- `bundler`: "esbuild", "webpack", "rollup", "vite", "auto", or "none"
  - `esbuild`: Fast general-purpose bundler (default)
  - `webpack`: Complex projects with advanced features
  - `rollup`: Library optimization with tree-shaking
  - `vite`: Modern frameworks (React, Vue, Svelte) with HMR
  - `auto`: Auto-detect best available bundler
  - `none`: No bundling (Node.js scripts)
- `entry`: Entry point file for bundling
- `platform`: "browser", "node", or "neutral"
- `format`: "esm", "cjs", "iife", or "umd"
- `minify`: Enable minification (boolean)
- `sourcemap`: Generate source maps (boolean)
- `target`: Target ES version (e.g., "es2018", "es2020")
- `jsx`: Enable JSX transformation (boolean)
- `jsxFactory`: JSX factory function (default: "React.createElement")
- `external`: Array of packages to exclude from bundle
- `configFile`: Path to custom bundler config (optional)

## Architecture

### Compilation Pipeline

1. **Lexical Analysis** (`config.lexer`)
   - Tokenizes source into typed tokens
   - Handles strings, numbers, identifiers, keywords
   - Filters comments
   - Tracks line/column for error reporting

2. **Syntax Analysis** (`config.dsl`)
   - Recursive descent parser
   - Builds strongly-typed AST
   - Parser combinator patterns
   - Comprehensive error messages

3. **Semantic Analysis** (`config.dsl`)
   - Validates AST structure
   - Type checking
   - Converts AST to Target objects
   - Language inference

4. **Integration** (`config.parser`)
   - Seamless fallback from JSON to DSL
   - Glob pattern expansion
   - Target name resolution

### AST Structure

```d
BuildFile
  └─ TargetDecl[]
       ├─ name: string
       └─ Field[]
            ├─ name: string
            └─ value: ExpressionValue
                 ├─ String
                 ├─ Number
                 ├─ Identifier
                 ├─ Array
                 └─ Map
```

### Error Handling

All parsing operations return `Result!(T, BuildError)` for type-safe error handling:

```d
auto result = parseDSL(source, path, root);
if (result.isErr) {
    auto error = result.unwrapErr();
    writeln(error.toString());  // Detailed error with line/column
}
```

Error messages include:
- File path
- Line and column numbers
- Context information
- Helpful suggestions

## Design Principles

1. **Zero-Cost Abstractions**: Strong typing compiled away to optimal machine code
2. **Metaprogramming**: Compile-time validation using D's template system
3. **Parser Combinators**: Elegant composition of parsing operations
4. **Result Monads**: Explicit error handling without exceptions
5. **Single Responsibility**: Each module has one clear purpose
   - `lexer.d` - Tokenization only
   - `ast.d` - AST types only
   - `dsl.d` - Parsing and semantic analysis

## Performance

- **Lexer**: O(n) single-pass tokenization with zero allocations for primitives
- **Parser**: O(n) recursive descent with minimal backtracking
- **Semantic Analysis**: O(n) single-pass validation
- **Overall**: Linear time complexity with respect to file size

## Comparison with JSON

### JSON Format (Legacy)
```json
{
    "name": "app",
    "type": "executable",
    "language": "python",
    "sources": ["main.py"],
    "deps": [":utils"]
}
```

### DSL Format (Modern)
```d
target("app") {
    type: executable;
    language: python;
    sources: ["main.py"];
    deps: [":utils"];
}
```

**Advantages of DSL:**
- More readable and less verbose
- Comments supported
- Better error messages with line/column info
- Extensible syntax for future features
- Compile-time validation
- Natural for developers

**Backward Compatibility:**
- JSON format still fully supported
- Automatic detection and fallback
- No migration required
- Both formats can coexist

## Future Extensions

Potential future enhancements:

- **Variables**: `let VERSION = "1.0.0";`
- **Imports**: `import "common.build";`
- **Functions**: `glob("src/**/*.py")`
- **Conditionals**: `if platform == "linux" { ... }`
- **String interpolation**: `"${VERSION}-release"`

## Best Practices

1. **Use DSL for new projects**: More maintainable and readable
2. **Group related targets**: Keep related targets in same file
3. **Use comments**: Document complex build configurations
4. **Leverage glob patterns**: Avoid manual file listings
5. **Multi-line for readability**: Break long arrays/maps across lines
6. **Consistent formatting**: Use consistent indentation (2 or 4 spaces)

## Testing

Comprehensive test suite in `tests/unit/config/dsl.d`:
- Lexer tokenization tests
- Parser syntax tests
- Semantic analysis tests
- Error handling tests
- Integration tests

Run tests:
```bash
./bin/test-runner tests/unit/config/dsl.d
```

## Implementation

Source files:
- `source/infrastructure/config/parsing/lexer.d` - Lexical analyzer
- `source/infrastructure/config/workspace/ast.d` - AST node types
- `source/infrastructure/config/parsing/unified.d` - Unified DSL parser
- `source/infrastructure/config/parsing/parser.d` - Integration

See `source/infrastructure/config/` for the complete configuration system.

## Builderspace Files

### Overview

Builderspace files provide workspace-level configuration that applies to all targets in the build. They configure build options, global environment variables, and other workspace-wide settings.

### Location

Builderspace files should be placed at the root of your workspace:
```
/path/to/workspace/
  Builderspace       # Workspace configuration
  Builderfile        # Build targets
  src/
    Builderfile
```

### Syntax

Builderspace files use the Builder DSL format

```d
workspace("name") {
    // Build options
    cacheDir: ".builder-cache";
    outputDir: "bin";
    parallel: true;
    maxJobs: 8;
    verbose: false;
    incremental: true;
    
    // Global environment variables
    env: {
        "PYTHONPATH": "/usr/lib/python3.10",
        "NODE_PATH": "/usr/local/lib/node_modules"
    };
}
```

### Fields

#### cacheDir (string)
Directory for build cache storage.

**Default**: `.builder-cache`

```d
cacheDir: ".cache";
cacheDir: "build/cache";
```

#### outputDir (string)
Default output directory for build artifacts.

**Default**: `bin`

```d
outputDir: "bin";
outputDir: "dist";
outputDir: "build/output";
```

#### parallel (boolean)
Enable parallel build execution.

**Default**: `true`

```d
parallel: true;   // Enable parallel builds
parallel: false;  // Sequential builds only
```

#### maxJobs (number)
Maximum number of parallel build jobs.

**Default**: `0` (auto-detect CPU count)

```d
maxJobs: 0;   // Auto-detect
maxJobs: 4;   // Fixed to 4 jobs
maxJobs: 8;   // Fixed to 8 jobs
```

#### verbose (boolean)
Enable verbose build output.

**Default**: `false`

```d
verbose: true;   // Detailed output
verbose: false;  // Normal output
```

#### incremental (boolean)
Enable incremental builds with caching.

**Default**: `true`

```d
incremental: true;   // Use cache
incremental: false;  // Always rebuild
```

#### env (map)
Global environment variables applied to all builds.

**Default**: `{}`

```d
env: {
    "PYTHONPATH": "/usr/lib/python3.10",
    "NODE_PATH": "/usr/local/lib/node_modules",
    "PATH": "/usr/local/bin:/usr/bin"
};
```

### Examples

#### Minimal Configuration

```d
workspace("my-project") {
    outputDir: "dist";
}
```

#### Development Configuration

```d
workspace("dev-workspace") {
    cacheDir: ".cache";
    outputDir: "build";
    parallel: true;
    maxJobs: 0;  // Auto-detect
    verbose: true;
    incremental: true;
    
    env: {
        "DEBUG": "1",
        "LOG_LEVEL": "debug"
    };
}
```

#### Production Configuration

```d
workspace("production") {
    cacheDir: ".builder-cache";
    outputDir: "dist";
    parallel: true;
    maxJobs: 16;
    verbose: false;
    incremental: true;
    
    env: {
        "NODE_ENV": "production",
        "PYTHONOPTIMIZE": "2"
    };
}
```

#### Python Project

```d
workspace("python-project") {
    outputDir: "bin";
    parallel: true;
    maxJobs: 8;
    
    env: {
        "PYTHONPATH": "/usr/lib/python3.10:/usr/local/lib/python3.10",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0"
    };
}
```

#### Multi-Language Project

```d
workspace("multi-lang") {
    cacheDir: ".cache";
    outputDir: "bin";
    parallel: true;
    maxJobs: 0;
    incremental: true;
    
    env: {
        "PYTHONPATH": "/usr/lib/python3.10",
        "NODE_PATH": "/usr/local/lib/node_modules",
        "GOPATH": "/home/user/go",
        "CARGO_HOME": "/home/user/.cargo"
    };
}
```

### Interaction with Builderfile Files

- Builderspace configuration applies globally to all targets
- Builderfile files can override environment variables per-target
- Target-specific settings take precedence over workspace settings
- Global environment is merged with target-specific environment

Example:
```d
// Builderspace
workspace("my-app") {
    env: {
        "DEBUG": "0",
        "PATH": "/usr/bin"
    };
}

// Builderfile
target("app") {
    type: executable;
    sources: ["main.py"];
    env: {
        "DEBUG": "1"  // Overrides workspace setting
    };
}
// Result: app gets DEBUG=1, PATH=/usr/bin
```

### Implementation Details

- **Parser**: Reuses Builderfile DSL lexer and parser infrastructure
- **Module**: `config.workspace` - ~400 lines of code
- **Error Handling**: Full Result monad integration with detailed errors
- **Validation**: Type-safe parsing with semantic analysis
- **Format**: DSL only (no JSON support needed for new feature)

### Architecture

```
Builderspace file
    ↓
Lexer (config.lexer)
    ↓
Parser (config.workspace.WorkspaceParser)
    ↓
AST (config.workspace.WorkspaceFile)
    ↓
Semantic Analysis (config.workspace.WorkspaceAnalyzer)
    ↓
WorkspaceConfig (config.schema)
```

### Best Practices

1. **Enable incremental builds**: Significantly faster for large projects
2. **Auto-detect CPU count**: Use `maxJobs: 0` for portability
3. **Minimal environment**: Only set truly global variables
4. **Use comments**: Document non-obvious configuration choices
5. **Version control**: Commit Builderspace files to repository
6. **Keep it simple**: Only configure what differs from defaults

