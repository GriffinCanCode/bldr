# Languages Package

The languages package provides language-specific build handlers and dependency analysis for multiple programming languages.

## Architecture

### Core Modules
- **registry.d** - **Central source of truth** for all language definitions, aliases, file extensions, and categorization
- **base.d** - Base language interface and factory

### Language Registry

The `registry.d` module is the single source of truth for all language-related information:
- Language name aliases (e.g., "py" → Python, "c++" → C++)
- File extension mappings (e.g., ".ts" → TypeScript)
- Language display labels for UI
- Language categorization (Compiled, Scripting, JVM, .NET, Web)

**Important**: When adding a new language, update `registry.d` and it will automatically appear in help text, wizard, and all other places. Never hardcode language lists elsewhere.

### Supported Languages

Languages are organized by category. See `registry.d` for the complete list:

#### Compiled Languages
C, C++, D, Zig, Rust, Go, Nim, OCaml, Haskell, Swift, Protobuf

#### Scripting Languages  
Python, Ruby, Perl, PHP, Lua, R, Elixir

#### JVM Languages
Java, Kotlin, Scala

#### .NET Languages
C#, F#

#### Web Languages
JavaScript, TypeScript, CSS, Elm

### Module Structure

Each language has a modular structure with:
- **core/** - Core handler and configuration
- **analysis/** - Dependency analysis and detection
- **tooling/** - Language-specific tools (compilers, formatters, linters)
- **managers/** - Package manager integration
- **builders/** - Build system integration

## Usage

```d
import languages;
import infrastructure.di : NullServiceContainer;

auto handler = LanguageFactory.create("python");
auto deps = handler.analyzeDependencies(sourceFile);
// Build with context (IServiceContainer provides tracer, logger, SIMD)
BuildContext context;
context.target = target;
context.config = config;
context.services = services;  // Or NullServiceContainer() for testing
handler.buildWithContext(context);
```

## Key Features

- Automatic dependency detection per language
- Language-specific build command generation
- Support for language-specific package managers
- Incremental compilation support
- Cross-language dependency handling

