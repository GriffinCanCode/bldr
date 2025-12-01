# Build Configuration Wizard

The Builder Wizard provides an interactive, guided experience for setting up new Builder projects. It combines intelligent auto-detection with user-friendly prompts to generate optimal build configurations.

## Overview

```bash
bldr wizard
```

The wizard guides you through:
1. **Language Selection** - Choose your primary language (with auto-detection)
2. **Project Structure** - Define whether it's an app, library, or monorepo
3. **Package Manager** - Select or auto-detect package management tools
4. **Caching** - Enable build result caching for faster rebuilds
5. **Remote Execution** - Configure distributed builds (optional)

## Features

### Intelligent Auto-Detection

The wizard scans your project directory before prompting, detecting:
- Programming languages and frameworks
- Existing manifest files (package.json, Cargo.toml, etc.)
- Project structure patterns
- Confidence scores for each detection

Detected languages are presented first with their confidence levels, making it easy to select the correct configuration.

### Interactive UI

- **Arrow Key Navigation**: Use ↑/↓ or j/k to navigate options
- **Visual Feedback**: Selected options are highlighted
- **Smart Defaults**: Most common choices are pre-selected
- **Confirmation**: Prompts before overwriting existing files

### Generated Files

The wizard creates three essential files:

1. **Builderfile** - Build target definitions
2. **Builderspace** - Workspace-level configuration
3. **.builderignore** - Files/directories to exclude from scanning

## Usage

### Basic Setup

```bash
cd my-project
bldr wizard
```

### Example Session

```
╔════════════════════════════════════════════════════════╗
║      Builder Configuration Wizard                      ║
╠════════════════════════════════════════════════════════╣
║ Interactive setup wizard for configuring your Builder  ║
║ project. Answer a few questions to create optimized   ║
║ build configuration.                                    ║
╚════════════════════════════════════════════════════════╝

ℹ Scanning project directory...

? What language is your project? (arrow keys)
  > Python (95% confidence)
    JavaScript/TypeScript (80% confidence)
    Other

? Project structure?
  > Single application
    Library
    Monorepo with multiple services

? Package manager?
  > Auto-detect
    pip
    poetry
    pipenv
    conda

? Enable caching? (Y/n) Y

? Enable remote execution? (y/N) N

ℹ Generating configuration files...

────────────────────────────────────────────────────────
✓ Created Builderfile
✓ Created Builderspace
✓ Configured caching
✓ Added .builderignore
────────────────────────────────────────────────────────

Run 'bldr build' to start building!
```

## Language Support

The wizard supports all Builder languages:

### Compiled Languages
- **C/C++** - Auto-detects CMake, Makefile, or direct compilation
- **Rust** - Uses Cargo
- **Go** - Uses Go modules
- **D** - Uses DUB or direct compilation
- **Zig** - Direct compilation
- **Nim** - Uses nimble or direct compilation

### JVM Languages
- **Java** - Maven or Gradle
- **Kotlin** - Gradle or Maven
- **Scala** - SBT, Mill, or Gradle

### .NET Languages
- **C#** - MSBuild or dotnet CLI
- **F#** - dotnet CLI

### Scripting Languages
- **Python** - pip, poetry, pipenv, or conda
- **JavaScript/TypeScript** - npm, yarn, pnpm, or bun
- **Ruby** - bundler or gem
- **PHP** - composer
- **Perl** - cpan or cpanm
- **Lua** - luarocks
- **R** - CRAN packages

### Functional Languages
- **Haskell** - Stack or Cabal
- **OCaml** - Opam or Dune
- **Elixir** - Mix
- **Elm** - elm-package

### Other
- **Swift** - SPM (Swift Package Manager)
- **Protobuf** - protoc

## Project Structure Types

### Single Application

For projects that build one executable or deployable artifact:

```d
target("app") {
    type: executable;
    language: python;
    sources: ["src/**/*.py"];
}
```

### Library

For reusable libraries:

```d
target("mylib") {
    type: library;
    language: rust;
    sources: ["src/**/*.rs"];
}
```

### Monorepo

For projects with multiple independent services:

```d
target("frontend") {
    type: executable;
    language: typescript;
    sources: ["frontend/src/**/*.ts"];
}

target("backend") {
    type: executable;
    language: go;
    sources: ["backend/**/*.go"];
}

target("shared") {
    type: library;
    language: typescript;
    sources: ["shared/**/*.ts"];
}
```

## Configuration Options

### Caching

When enabled, Builder caches build results based on content hashes:

```d
workspace {
    cache {
        enabled: true;
        directory: ".builder-cache";
    }
}
```

Benefits:
- Instant rebuilds when nothing changes
- Per-file granularity
- Content-addressed (BLAKE3 hashing)
- Shared across branches

### Remote Execution

For distributed builds (requires setup):

```d
workspace {
    remote {
        enabled: true;
        endpoint: "grpc://build-cluster:8080";
    }
}
```

## Advanced Usage

### Non-Interactive Mode

In CI/CD or automated environments where stdin is not available, the wizard automatically uses defaults based on detection results.

### Overwriting Existing Files

If Builderfile and Builderspace already exist:

```
? Build files already exist. Overwrite? (y/N)
```

Selecting "No" cancels the wizard without changes.

### Custom Templates

After generation, you can manually edit the files:

1. **Builderfile** - Add dependencies, custom commands, environment variables
2. **Builderspace** - Configure parallelism, timeouts, telemetry
3. **.builderignore** - Add project-specific exclusions

## Comparison with `bldr init`

| Feature | `bldr wizard` | `bldr init` |
|---------|-----------------|----------------|
| Interactive | ✓ Yes | ✗ No |
| Arrow key navigation | ✓ Yes | ✗ No |
| Package manager selection | ✓ Yes | ✗ Auto only |
| Project structure choice | ✓ Yes | ✗ Auto only |
| Visual feedback | ✓ Rich | ○ Basic |
| Best for | New users, complex setups | Scripts, simple projects |

## Tips

1. **Run in project root** - The wizard scans from the current directory
2. **Review before building** - Check generated files match your needs
3. **Iterative refinement** - You can re-run the wizard to update config
4. **Start simple** - Begin with basic settings, add complexity later

## Examples

### Python Web App

```bash
cd my-flask-app
bldr wizard
# Select: Python → Single application → poetry → Enable caching
bldr build
```

### Rust + TypeScript Monorepo

```bash
cd my-fullstack-app
bldr wizard
# Select: Rust → Monorepo → Enable caching
# Then manually edit Builderfile to add TypeScript frontend
bldr build
```

### Go Microservice

```bash
cd my-service
bldr wizard
# Select: Go → Single application → Enable caching + remote
bldr build
```

## Troubleshooting

### "No supported languages detected"

The wizard couldn't find language-specific files. You can still proceed and manually configure the Builderfile.

### Arrow keys not working

Ensure your terminal supports ANSI escape sequences. Most modern terminals do, but some minimal environments may not.

### Terminal garbled after wizard

Run `reset` to restore terminal state. This shouldn't happen normally - please report if it does.

## See Also

- `bldr init` - Non-interactive initialization
- `bldr infer` - Preview auto-detection results
- `bldr build` - Build your project
- `bldr help` - Full command reference

