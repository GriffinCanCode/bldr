# Dynamic Languages Example

This example demonstrates Builder's revolutionary **zero-code language addition** system.

## What This Demonstrates

Instead of writing 150+ lines of D code for each language handler, we define languages via simple JSON specifications. This example shows:

1. Using spec-based languages (Crystal, Dart, V)
2. Creating a custom language spec
3. Automatic handler generation from specs
4. Full integration with Builder's build system

## Project Structure

```
examples/dynamic-languages/
├── crystal/          # Crystal language example
│   ├── Builderfile
│   ├── shard.yml    # Crystal dependencies
│   └── src/
│       └── hello.cr
├── dart/            # Dart language example
│   ├── Builderfile
│   ├── pubspec.yaml # Dart dependencies
│   └── lib/
│       └── hello.dart
├── v/               # V language example
│   ├── Builderfile
│   ├── v.mod        # V module
│   └── hello.v
└── custom/          # Custom language example
    ├── mylang.json  # Custom language spec
    ├── Builderfile
    └── hello.ml
```

## Running Examples

### Crystal Example

```bash
# If Crystal is installed
bldr build //examples/dynamic-languages/crystal:hello
builder run //examples/dynamic-languages/crystal:hello
```

### Dart Example

```bash
# If Dart is installed
bldr build //examples/dynamic-languages/dart:hello
builder run //examples/dynamic-languages/dart:hello
```

### V Example

```bash
# If V is installed
bldr build //examples/dynamic-languages/v:hello
builder run //examples/dynamic-languages/v:hello
```

### Custom Language

```bash
# First, install your custom compiler to $PATH as 'mylang'
# Or modify mylang.json to point to your compiler

bldr build //examples/dynamic-languages/custom:hello
```

## How It Works

### 1. Language Specifications

Each language is defined by a JSON file in `source/languages/specs/`:

```json
{
  "language": {
    "name": "crystal",
    "display": "Crystal",
    "extensions": [".cr"]
  },
  "build": {
    "compiler": "crystal",
    "compile_cmd": "crystal build {{sources}} -o {{output}} {{flags}}"
  }
}
```

### 2. Automatic Discovery

Builder automatically discovers and loads all `.json` specs from:
- `source/languages/specs/` (built-in specs)
- `~/.builder/specs/` (user specs)
- `$BUILDER_SPECS_DIR/` (custom directory)

### 3. Transparent Usage

Use spec-based languages exactly like built-in ones:

```builderfile
target("myapp") {
    language: crystal;  # Automatically uses crystal.json
    sources: ["src/main.cr"];
}
```

No configuration needed!

## Creating a Custom Language

### Step 1: Write Language Spec

Create `mylang.json`:

```json
{
  "language": {
    "name": "mylang",
    "display": "MyLang",
    "category": "compiled",
    "extensions": [".ml"],
    "aliases": ["ml"]
  },
  "detection": {
    "shebang": ["#!/usr/bin/env mylang"],
    "files": ["mylang.toml"]
  },
  "build": {
    "compiler": "mylang",
    "compile_cmd": "mylang compile {{sources}} -o {{output}} {{flags}}",
    "test_cmd": "mylang test {{sources}}",
    "format_cmd": "mylang fmt {{sources}}",
    "lint_cmd": "mylang lint {{sources}}"
  },
  "dependencies": {
    "pattern": "import\\s+\"([^\"]+)\"",
    "resolver": "module_path",
    "manifest": "mylang.toml",
    "install_cmd": "mylang deps install"
  }
}
```

### Step 2: Place Spec File

```bash
# User specs (recommended for custom languages)
cp mylang.json ~/.builder/specs/

# Or project-local (for sharing with team)
cp mylang.json source/languages/specs/
```

### Step 3: Use Immediately

```builderfile
target("app") {
    language: mylang;  # Works instantly!
    sources: ["main.ml"];
}
```

```bash
bldr build //path/to:app
```

## Template Variables

Specs support variable substitution in commands:

| Variable | Description | Example |
|----------|-------------|---------|
| `{{sources}}` | Space-separated source files | `main.cr lib.cr` |
| `{{output}}` | Output file path | `bin/myapp` |
| `{{flags}}` | User-provided flags | `--release -O3` |
| `{{workspace}}` | Workspace root directory | `/path/to/project` |
| `{{manifest}}` | Dependency manifest path | `/path/to/shard.yml` |

## Benefits

### For Users
- ✅ Add languages in minutes, not hours
- ✅ No D programming knowledge required
- ✅ Share specs across projects
- ✅ Community-driven language support

### For Maintainers
- ✅ Reduce code duplication (150 lines → 20 lines)
- ✅ Accept language PRs without code review
- ✅ Enable ecosystem growth
- ✅ Lower contribution barrier

## Limitations

Spec-based languages work great for:
- ✅ Simple compiler toolchains
- ✅ Standard build patterns
- ✅ Regex-extractable imports
- ✅ Single-command builds

For complex cases, use full D handlers:
- ❌ Multi-stage pipelines
- ❌ Complex dependency resolution
- ❌ Custom caching logic
- ❌ Deep IDE integration

## Troubleshooting

### Language Not Found

```
Error: Language 'mylang' not found
```

**Solution:** Check spec file exists and has correct name:
```bash
ls ~/.builder/specs/mylang.json
```

### Compiler Not Found

```
Error: Compiler 'mylang' not found for MyLang
```

**Solution:** Install compiler or update `PATH`:
```bash
which mylang  # Should show path
export PATH=$PATH:/path/to/mylang/bin
```

### Invalid Spec

```
Error: Failed to parse language spec 'mylang.json'
```

**Solution:** Validate JSON syntax:
```bash
cat ~/.builder/specs/mylang.json | jq .
```

## See Also

- [Dynamic Languages Documentation](../../docs/features/dynamic-languages.md)
- [Language Specs README](../../source/languages/specs/README.md)
- [Spec Format Reference](../../docs/features/dynamic-languages.md#specification-format)

## Contributing

Found a bug or want to add a language spec?

1. Test your spec thoroughly
2. Submit a PR with just the JSON file
3. Include example Builderfile in description

No D knowledge needed!

