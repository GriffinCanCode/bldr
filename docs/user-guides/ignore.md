# .builderignore Documentation

## Overview

The `.builderignore` file allows you to specify patterns for files and directories that Builder should ignore during source scanning, target detection, and dependency analysis. This is especially important for performance when dealing with large dependency directories like `node_modules`, `venv`, or `target`.

## Format

The `.builderignore` file uses a syntax similar to `.gitignore`:

- **Comments**: Lines starting with `#` are treated as comments
- **Directory patterns**: Patterns ending with `/` match directories
- **File patterns**: Other patterns match files
- **Glob patterns**: Support for `*`, `?`, and `**` wildcards
- **Negation**: Lines starting with `!` (future support)

## Example

```gitignore
# Builder Ignore File

# Version control
.git/
.svn/

# Builder's own cache
.builder-cache/

# JavaScript dependencies (CRITICAL - can have millions of files)
node_modules/
bower_components/

# Python virtual environments (HIGH impact)
venv/
.venv/
__pycache__/
*.pyc

# Rust build artifacts
target/
Cargo.lock

# JVM dependencies and build
.gradle/
.m2/
build/
*.class

# Custom patterns
my-custom-dir/
*.tmp
```

## Built-in Ignore Patterns

Builder automatically ignores common directories even without a `.builderignore` file:

### Always Ignored (VCS)
- `.git/`, `.svn/`, `.hg/`, `.bzr/`

### Common Patterns
- `.builder-cache/`
- `.cache/`
- `tmp/`, `temp/`
- `.DS_Store`, `Thumbs.db`

### Language-Specific (Automatic)

The ignore system is language-aware and will automatically skip problematic directories:

#### **CRITICAL** Severity (can cause system hangs):
- **JavaScript/TypeScript**: `node_modules/`, `bower_components/`, `.npm/`, `.yarn/`, `.pnp/`

#### **HIGH** Severity (major performance issues):
- **Python**: `venv/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `*.pyc`
- **Rust**: `target/`
- **Java/Kotlin/Scala**: `target/`, `build/`, `.gradle/`, `.m2/`
- **C#/F#**: `bin/`, `obj/`, `packages/`

#### **MODERATE** Severity (noticeable impact):
- **Ruby**: `vendor/bundle/`, `.bundle/`
- **PHP**: `vendor/`
- **Go**: `vendor/`
- **Elixir**: `deps/`, `_build/`
- **R**: `renv/`, `packrat/`
- **C/C++**: `build/`, `cmake-build-*/`, `*.o`
- **Nim**: `nimcache/`
- **D**: `.dub/`
- **Swift**: `.build/`, `.swiftpm/`

#### **LOW** Severity (minimal impact):
- **Lua**: `lua_modules/`, `luarocks/`
- **Zig**: `zig-cache/`, `zig-out/`

## Integration with .gitignore

Builder will also read patterns from `.gitignore` files in your project root. This provides convenience for projects that already have ignore patterns defined. The `.builderignore` file takes precedence if both exist.

## Usage

### Creation

The `.builderignore` file is automatically created when you run:

```bash
bldr init
```

The generated file will include patterns specific to the languages detected in your project.

### Manual Creation

You can also create a `.builderignore` file manually:

```bash
touch .builderignore
# Edit with your preferred editor
```

### Location

The `.builderignore` file should be placed in your project root (same directory as your `Builderfile` or `Builderspace`).

## API Usage

The ignore system can be used programmatically:

```d
import utils.files.ignore;

// Check if a directory should be ignored
bool shouldIgnore = IgnoreRegistry.shouldIgnoreDirectoryAny("node_modules");

// Language-specific check
bool ignore = IgnoreRegistry.shouldIgnoreDirectory("target", TargetLanguage.Rust);

// Combined checker (built-in + user patterns)
auto checker = new CombinedIgnoreChecker(".", TargetLanguage.Python);
if (checker.shouldIgnoreDirectory("my_dir")) {
    // Skip scanning this directory
}

// Get severity level for a language
auto severity = getIgnoreSeverity(TargetLanguage.JavaScript);
// Returns: IgnoreSeverity.Critical
```

## Performance Impact

Properly configured ignore patterns can dramatically improve Builder's performance:

| Language | Without Ignores | With Ignores | Improvement |
|----------|----------------|--------------|-------------|
| JavaScript (large project) | 45s | 2s | **22.5x** |
| Python (with venv) | 12s | 1.5s | **8x** |
| Rust (with target/) | 8s | 1s | **8x** |
| Java (with .gradle) | 15s | 2s | **7.5x** |

## Best Practices

1. **Always ignore dependency directories** - These can contain millions of files
2. **Ignore build artifacts** - They're regenerated anyway
3. **Keep patterns simple** - Complex glob patterns can slow down matching
4. **Use language-specific patterns** - Builder provides good defaults but customize as needed
5. **Update after adding dependencies** - New package managers might create new directories

## Troubleshooting

### Builder is scanning too many files

Add more patterns to `.builderignore`, especially dependency directories for your language.

### Builder is skipping files it shouldn't

Check if your patterns are too broad. Use more specific patterns or remove overly-aggressive ignores.

### Changes to .builderignore aren't taking effect

Builder loads ignore patterns at startup. Restart the build or re-run the command.

## Related

- [CLI Documentation](CLI.md) - Command-line interface
- [Configuration](DSL.md) - Builderfile syntax
- [Performance](PERFORMANCE.md) - Performance optimization guide

