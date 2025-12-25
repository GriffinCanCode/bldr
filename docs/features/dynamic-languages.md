# Dynamic Language Support

## Overview

Builder supports adding language support through declarative JSON specifications. Instead of writing D code for each language handler, define language support in a JSON file.

### Comparison

| Approach | Lines | Programming Required |
|----------|-------|---------------------|
| D Handler | ~150+ | D knowledge |
| JSON Spec | ~20-30 | None |

## Architecture

The dynamic language system is in `source/languages/`:

```
languages/
├── dynamic/
│   ├── spec.d      # LanguageSpec parser
│   ├── handler.d   # SpecBasedHandler
│   └── package.d   # Public API
├── specs/          # JSON specifications
│   ├── crystal.json
│   ├── dart.json
│   ├── v.json
│   └── README.md
└── registry.d      # Handler registry
```

### Components

**LanguageSpec** (`spec.d`):
- Parses JSON specification files
- Template variable expansion
- Compiler availability checking

**SpecBasedHandler** (`handler.d`):
- Generic handler driven by specification
- Routes to compile/test/format commands
- Supports import analysis via regex

**SpecRegistry** (`spec.d`):
- Discovers and loads spec files
- Provides lookup by language name

## Specification Format

### Complete Example (Crystal)

```json
{
  "language": {
    "name": "crystal",
    "display": "Crystal",
    "category": "compiled",
    "extensions": [".cr"],
    "aliases": ["cr", "crystal"]
  },
  "detection": {
    "shebang": ["#!/usr/bin/env crystal"],
    "files": ["shard.yml", "shard.lock"],
    "version_cmd": "crystal --version"
  },
  "build": {
    "compiler": "crystal",
    "compile_cmd": "crystal build {{sources}} -o {{output}} {{flags}}",
    "test_cmd": "crystal spec {{sources}}",
    "format_cmd": "crystal tool format {{sources}}",
    "lint_cmd": "crystal tool format --check {{sources}}",
    "check_cmd": "crystal build --no-codegen {{sources}}",
    "env": {
      "CRYSTAL_PATH": "lib:{{workspace}}"
    },
    "incremental": false,
    "caching": true
  },
  "dependencies": {
    "pattern": "require \"([^\"]+)\"",
    "resolver": "shard",
    "manifest": "shard.yml",
    "install_cmd": "shards install"
  }
}
```

### Field Reference

#### language (required)
| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Unique identifier (e.g., "crystal") |
| `display` | string | UI display name |
| `category` | string | One of: compiled, scripting, jvm, dotnet, web |
| `extensions` | string[] | File extensions (e.g., [".cr"]) |
| `aliases` | string[] | Alternative names |

#### detection (optional)
| Field | Type | Description |
|-------|------|-------------|
| `shebang` | string[] | Shebang patterns |
| `files` | string[] | Project manifest files |
| `version_cmd` | string | Command to check compiler version |

#### build (required for compilation)
| Field | Type | Description |
|-------|------|-------------|
| `compiler` | string | Compiler executable name |
| `compile_cmd` | string | Compile command template |
| `test_cmd` | string | Test command template |
| `format_cmd` | string | Format command template |
| `lint_cmd` | string | Lint command template |
| `check_cmd` | string | Type-check command template |
| `env` | object | Environment variables |
| `incremental` | boolean | Supports incremental compilation |
| `caching` | boolean | Supports build caching (default: true) |

#### dependencies (optional)
| Field | Type | Description |
|-------|------|-------------|
| `pattern` | string | Regex for import extraction |
| `resolver` | string | Resolution strategy |
| `manifest` | string | Dependency manifest file |
| `install_cmd` | string | Dependency install command |

### Template Variables

Commands support variable substitution:

| Variable | Description |
|----------|-------------|
| `{{sources}}` | Space-separated source files |
| `{{output}}` | Output file path |
| `{{flags}}` | User-provided flags |
| `{{workspace}}` | Workspace root directory |
| `{{manifest}}` | Dependency manifest path |

Example:
```json
"compile_cmd": "crystal build {{sources}} -o {{output}} {{flags}}"
```

Expands to:
```bash
crystal build src/main.cr -o bin/app --release
```

## Usage

### For Users

Use spec-based languages like built-in languages:

```
target("myapp") {
    type: executable;
    language: crystal;
    sources: ["src/main.cr"];
}
```

No configuration required—Builder auto-discovers specs.

### Adding a Custom Language

Create `~/.builder/specs/mylang.json`:

```json
{
  "language": {
    "name": "mylang",
    "display": "MyLang",
    "extensions": [".ml"]
  },
  "build": {
    "compiler": "mylang",
    "compile_cmd": "mylang compile {{sources}} -o {{output}}"
  }
}
```

Use immediately:

```
target("app") {
    language: mylang;
    sources: ["main.ml"];
}
```

### Programmatic API

```d
import languages.dynamic.spec;
import languages.dynamic.handler;

// Load all specs
auto registry = new SpecRegistry();
registry.loadAll();

// Get specific spec
if (auto spec = registry.get("crystal")) {
    auto handler = new SpecBasedHandler(*spec);
    auto result = handler.buildWithContext(context);
}

// Check availability
if (spec.isAvailable()) {
    // Compiler found on system
}
```

### HandlerRegistry Integration

The handler registry automatically loads dynamic specs:

```d
auto registry = new HandlerRegistry();
registry.initialize();

// Returns SpecBasedHandler for crystal
auto handler = registry.getByName("crystal");
```

Built-in handlers take precedence over specs.

## Included Specifications

| Language | File | Compiler | Category |
|----------|------|----------|----------|
| Crystal | crystal.json | crystal | compiled |
| Dart | dart.json | dart | compiled |
| V | v.json | v | compiled |

## When to Use Specs vs D Handlers

### Use JSON Specs For

- Straightforward compilers (single command)
- Standard toolchains (compiler + linter + formatter)
- Simple dependency management (one manifest file)
- Regex-extractable imports

### Use D Handlers For

- Multi-stage compilation pipelines
- Complex dependency resolution
- Custom caching strategies
- Deep IDE integration (LSP, debugging)
- Conditional logic based on target configuration

**Example**: Rust uses a D handler because:
- Cargo has complex workspace semantics
- Multiple build modes (dev/release/test)
- Toolchain management (rustup)
- Incremental compilation tracking

## Spec Loading

### Search Paths

1. `source/languages/specs/` (built-in)
2. `~/.builder/specs/` (user-defined)

### Performance

- **Cold start**: ~5ms for 10 specs
- **Cached**: ~1ms (in-memory after load)
- **Per-build overhead**: Negligible

## Validation

Specs are validated on load. Errors include:

```
Error: Invalid language spec 'mylang.json'
  - Field 'language.name' cannot be empty
```

Required fields:
- `language.name`
- `build.compiler` (for compilation)

## Contributing Specs

To add a new language spec:

1. Create JSON file in `source/languages/specs/`
2. Test locally: `bldr build //test/mylang:simple`
3. Submit PR with the JSON file
4. Include example Builderfile in PR description

### Checklist

- [ ] `language.name` is unique
- [ ] `language.extensions` has at least one entry
- [ ] `build.compiler` is widely available
- [ ] `compile_cmd` template is correct
- [ ] Tested on real project

## Limitations

1. **No programmatic logic**: Specs are declarative; complex conditions require D handlers
2. **Single command templates**: Multi-step builds need D handlers
3. **Limited import analysis**: Only regex-based extraction

## See Also

- [Language Specifications README](../../source/languages/specs/README.md)
- [Plugin Architecture](../architecture/PLUGINS.md)
- [Language Registry](../architecture/overview.md#language-support)
