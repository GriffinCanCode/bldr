# Build Configuration Wizard

The wizard provides an interactive setup for new Builder projects, combining auto-detection with user prompts to generate build configuration.

## Usage

```bash
bldr wizard
```

## Steps

The wizard guides you through:

1. **Language Selection** - Choose primary language (auto-detected options shown first with confidence scores)
2. **Project Structure** - Single application, library, or monorepo
3. **Package Manager** - Language-specific package manager selection
4. **Caching** - Enable build result caching
5. **Remote Execution** - Enable distributed builds (optional)

## Generated Files

The wizard creates three files:

| File | Purpose |
|------|---------|
| `Builderfile` | Build target definitions |
| `Builderspace` | Workspace configuration |
| `.builderignore` | Files to exclude from scanning |

## Example Session

```
╔════════════════════════════════════════════════════════╗
║      Builder Configuration Wizard                      ║
╚════════════════════════════════════════════════════════╝

ℹ Scanning project directory...

? What language is your project?
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

## Navigation

- Arrow keys (↑/↓) or j/k to navigate options
- Enter to select
- Y/N for confirmations

## Language Support

When languages are detected, they appear with confidence scores. Otherwise, common languages are listed:

- Python
- JavaScript
- TypeScript
- Go
- Rust
- C++
- Java
- C#
- Ruby
- Other (generic)

## Package Managers

Language-specific options:

| Language | Options |
|----------|---------|
| Python | Auto-detect, pip, poetry, pipenv, conda |
| JavaScript/TypeScript | Auto-detect, npm, yarn, pnpm, bun |
| Ruby | Auto-detect, bundler, gem |
| PHP | Auto-detect, composer |
| Rust | cargo (automatic) |
| Go | go (automatic) |

## Project Structures

**Single Application:**
```
target("app") {
    type: executable;
    language: python;
    sources: ["src/**/*.py"];
}
```

**Library:**
```
target("mylib") {
    type: library;
    language: rust;
    sources: ["src/**/*.rs"];
}
```

**Monorepo:**
```
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
```

## Configuration Output

### Builderspace

```
workspace {
    name: "my-project";
    version: "1.0.0";

    cache {
        enabled: true;
        directory: ".builder-cache";
    }
}
```

With remote execution enabled:

```
workspace {
    name: "my-project";
    version: "1.0.0";

    cache {
        enabled: true;
        directory: ".builder-cache";
    }

    remote {
        enabled: true;
        // Configure endpoint
        // endpoint: "grpc://localhost:8080";
    }
}
```

### .builderignore

Generated based on selected language:

```gitignore
# Version control
.git/
.svn/

# Builder cache
.builder-cache/

# Python (example)
venv/
.venv/
__pycache__/
*.pyc
.pytest_cache/

# IDE
.idea/
.vscode/
```

## Existing Files

If Builderfile and Builderspace already exist, the wizard prompts before overwriting:

```
? Build files already exist. Overwrite? (y/N)
```

## Comparison with `bldr init`

| Feature | `bldr wizard` | `bldr init` |
|---------|---------------|-------------|
| Interactive | Yes | No |
| Package manager selection | Yes | Auto only |
| Project structure choice | Yes | Auto only |
| Use case | New users, complex setups | Scripts, simple projects |

## After Setup

1. Review generated files
2. Run `bldr build` to test
3. Edit configuration as needed
4. Add to version control

## See Also

- `bldr init` - Non-interactive initialization
- `bldr infer` - Preview auto-detection results
- `bldr migrate` - Migrate from other build systems
