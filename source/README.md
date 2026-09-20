# Builder Source Code

This directory contains the complete source code for the Builder build system, organized into modular packages.

## Package Structure

### 🚀 [engine/](engine/)
Core build execution engine and performance systems
- **runtime/** - Build execution, hermetic builds, remote execution, recovery, watch mode
- **graph/** - Dependency graph construction and management
- **compilation/** - Incremental compilation engine
- **caching/** - Multi-tier caching (local, action, remote)
- **distributed/** - Distributed build execution with work-stealing

### 🎨 [frontend/](frontend/)
User interfaces and developer tools
- **cli/** - Command-line interface with event-driven rendering
- **lsp/** - Language Server Protocol implementation
- **query/** - Build graph query language
- **testframework/** - Test execution and reporting

### 🌐 [languages/](languages/)
Multi-language support (32 handlers registered in `engine/runtime/services/registry/handler.d`)
- Compiled languages (C, C++, D, Rust, Go, Zig, etc.)
- Scripting languages (Python, Ruby, Perl, PHP, Lua, R)
- JVM languages (Java, Kotlin, Scala)
- .NET languages (C#, F#)
- Web languages (JavaScript, TypeScript, CSS, Elm)

### 🛠️ [infrastructure/](infrastructure/)
Core infrastructure and support systems
- **config/** - Configuration parsing, DSL, scripting, workspace management
- **analysis/** - Dependency resolution, scanning, detection
- **repository/** - Repository management and artifact fetching
- **toolchain/** - Unified toolchain detection and management
- **errors/** - Type-safe error handling with Result types
- **telemetry/** - Build telemetry, tracing, and observability
- **utils/** - Common utilities (files, crypto, concurrency, SIMD)
- **plugins/** - Plugin system and SDK
- **migration/** - Build system migration tools
- **tools/** - Miscellaneous development tools

## Main Entry Point

**app.d** - Main application entry point that orchestrates all packages

## Usage

Each package can be imported individually or as a whole:

```d
// Import entire group
import infrastructure.analysis;

// Import specific module
import infrastructure.analysis.scanning.scanner;

// Import multiple packages
import engine.runtime, infrastructure.config, infrastructure.errors;

// Import from frontend
import frontend.cli.commands.help;

// Import languages
import languages;
```

## Package Organization

Each package follows the D package.d convention:
- `package.d` - Public imports and package documentation
- `README.md` - Detailed package documentation
- Module files - Individual implementation files

This structure allows for clean imports and modular architecture while maintaining clear separation of concerns.

## Building

bldr is not yet self-hosting: it is built with dub. See the root `dub.json` for
build configuration and the `Makefile` for the C/SIMD objects it links against
(`make build`).

## Testing

Tests are located in the `tests/` directory at the project root, mirroring the source structure.

