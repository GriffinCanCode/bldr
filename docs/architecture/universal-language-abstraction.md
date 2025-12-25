# Universal Language Abstraction

**Status:** Implemented  
**Version:** 1.0

---

## Overview

Builder supports adding programming languages through declarative JSON specifications instead of writing D code. This reduces the effort to add basic language support from 150+ lines of D to ~30 lines of JSON.

---

## Architecture

```
source/languages/
├── dynamic/
│   ├── spec.d           # LanguageSpec parser
│   ├── handler.d        # SpecBasedHandler
│   └── package.d        # Public API
└── specs/
    ├── crystal.json     # Crystal language spec
    ├── dart.json        # Dart language spec
    ├── v.json           # V language spec
    └── README.md        # Spec documentation
```

### Components

**LanguageSpec** (`spec.d`)
- Parses JSON specifications
- Validates required fields
- Provides template expansion

**SpecBasedHandler** (`handler.d`)
- Implements `BaseLanguageHandler` interface
- Expands command templates
- Executes compiler commands

**SpecRegistry** (`spec.d`)
- Discovers specs from `~/.builder/specs/`
- Loads and caches specifications
- Provides lookup by language name

---

## Specification Format

### Minimal Spec

```json
{
  "language": {
    "name": "mylang",
    "extensions": [".ml"]
  },
  "build": {
    "compiler": "mylang",
    "compile_cmd": "mylang {{sources}} -o {{output}}"
  }
}
```

### Complete Spec

```json
{
  "language": {
    "name": "crystal",
    "display": "Crystal",
    "category": "compiled",
    "extensions": [".cr"],
    "aliases": ["cr"]
  },
  "detection": {
    "shebang": ["#!/usr/bin/env crystal"],
    "files": ["shard.yml"],
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

### Fields Reference

#### `language` (required)

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique identifier |
| `display` | No | Display name (defaults to `name`) |
| `category` | No | `compiled`/`scripting`/`jvm`/`dotnet`/`web` |
| `extensions` | Yes | File extensions (e.g., `[".cr"]`) |
| `aliases` | No | Alternative names |

#### `detection` (optional)

| Field | Description |
|-------|-------------|
| `shebang` | Shebang patterns to match |
| `files` | Project manifest files |
| `version_cmd` | Command to check version |

#### `build` (required)

| Field | Required | Description |
|-------|----------|-------------|
| `compiler` | Yes | Compiler executable name |
| `compile_cmd` | Yes | Compilation command template |
| `test_cmd` | No | Test execution template |
| `format_cmd` | No | Formatting template |
| `lint_cmd` | No | Linting template |
| `check_cmd` | No | Type checking template |
| `env` | No | Environment variables |
| `incremental` | No | Supports incremental (default: `false`) |
| `caching` | No | Supports caching (default: `true`) |

#### `dependencies` (optional)

| Field | Description |
|-------|-------------|
| `pattern` | Regex for import extraction |
| `resolver` | Resolution strategy |
| `manifest` | Dependency manifest file |
| `install_cmd` | Dependency install command |

---

## Template Variables

Command templates support substitution:

| Variable | Description |
|----------|-------------|
| `{{sources}}` | Space-separated source files |
| `{{output}}` | Output file path |
| `{{flags}}` | User-provided flags |
| `{{workspace}}` | Workspace root directory |
| `{{manifest}}` | Dependency manifest path |

---

## Usage

### Loading Specs

```d
import languages.dynamic;

auto registry = new SpecRegistry();
registry.loadAll();  // Loads from ~/.builder/specs/

auto spec = registry.get("crystal");
if (spec !is null) {
    auto handler = new SpecBasedHandler(*spec);
    // Use handler for builds
}
```

### Spec Locations

1. `~/.builder/specs/` - User specs
2. `$BUILDER_SPECS_DIR/` - Custom location (env var)

### Builderfile Usage

```d
target("hello") {
    type: executable;
    language: crystal;  // Uses crystal.json spec
    sources: ["src/hello.cr"];
}
```

---

## Current Specs

| Language | File | Status |
|----------|------|--------|
| Crystal | `crystal.json` | ✅ |
| Dart | `dart.json` | ✅ |
| V | `v.json` | ✅ |

---

## When to Use Specs vs Full Handlers

### Use Specs For

- Single-command compilation
- Standard toolchain (compiler + lint + format)
- Simple dependency patterns
- Languages with straightforward build process

### Use Full D Handlers For

- Multi-stage compilation
- Complex dependency resolution (Maven, Cargo)
- Conditional build logic
- Custom caching strategies
- Deep toolchain integration

---

## Adding a New Language

1. Create `~/.builder/specs/mylang.json`:

```json
{
  "language": {
    "name": "mylang",
    "display": "MyLang",
    "extensions": [".ml"]
  },
  "build": {
    "compiler": "mylang",
    "compile_cmd": "mylang build {{sources}} -o {{output}} {{flags}}"
  }
}
```

2. Use in Builderfile:

```d
target("app") {
    type: executable;
    language: mylang;
    sources: ["src/*.ml"];
}
```

No recompilation of Builder required.

---

## Validation

Specs are validated at load time:

- Required fields (`language.name`, `language.extensions`, `build.compiler`, `build.compile_cmd`)
- Extension format (must start with `.`)
- JSON syntax

Errors provide clear messages:

```
Failed to load spec 'invalid.json': Missing required field 'build.compiler'
```

---

## Performance

| Operation | Time |
|-----------|------|
| Spec discovery | ~5ms for 10 specs |
| Spec parsing | ~1ms per spec |
| Template expansion | <0.1ms per command |

Specs are cached in memory after first load.

---

## Related Documentation

- [Spec Format README](../../source/languages/specs/README.md)
- [LanguageSpec Implementation](../../source/languages/dynamic/spec.d)
- [SpecBasedHandler](../../source/languages/dynamic/handler.d)
- [Example: Crystal Spec](../../source/languages/specs/crystal.json)
