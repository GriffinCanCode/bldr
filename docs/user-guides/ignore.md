# .builderignore

## Overview

The `.builderignore` file specifies patterns for files and directories that Builder should skip during source scanning and dependency analysis. This significantly improves performance for projects with large dependency directories like `node_modules` or `venv`.

## Format

Uses `.gitignore` syntax:

```gitignore
# Comments start with #
node_modules/     # Directory pattern (trailing /)
*.pyc             # Glob pattern
!important.log    # Negation (include despite other rules)
```

**Supported syntax:**
- Comments: Lines starting with `#`
- Directory patterns: Ending with `/`
- Glob patterns: `*`, `?`, `**` wildcards
- Negation: Lines starting with `!`

## Example

```gitignore
# Builder Ignore File

# Version control
.git/
.svn/

# Builder cache
.builder-cache/

# JavaScript (critical - can have millions of files)
node_modules/
bower_components/

# Python
venv/
.venv/
__pycache__/
*.pyc

# Rust
target/

# JVM
.gradle/
.m2/
build/
*.class

# Custom
my-cache-dir/
*.tmp
```

## Built-in Patterns

Builder automatically ignores common directories without requiring a `.builderignore` file.

### Always Ignored (VCS)

- `.git/`, `.svn/`, `.hg/`, `.bzr/`

### Common Patterns

- `.builder-cache/`
- `.cache/`
- `tmp/`, `temp/`, `.tmp/`
- `.DS_Store`, `Thumbs.db`

### Language-Specific Patterns

**Critical (can cause hangs):**

| Language | Directories |
|----------|-------------|
| JavaScript/TypeScript | `node_modules/`, `bower_components/`, `.npm/`, `.yarn/`, `.pnp/`, `dist/`, `build/`, `.next/`, `.nuxt/` |

**High impact:**

| Language | Directories |
|----------|-------------|
| Python | `venv/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `*.pyc` |
| Rust | `target/` |
| Java/Kotlin/Scala | `target/`, `build/`, `.gradle/`, `.m2/`, `bin/`, `out/` |
| C#/F# | `bin/`, `obj/`, `packages/`, `.vs/` |

**Moderate impact:**

| Language | Directories |
|----------|-------------|
| Ruby | `vendor/bundle/`, `.bundle/` |
| PHP | `vendor/` |
| Go | `vendor/`, `bin/`, `pkg/` |
| Elixir | `deps/`, `_build/` |
| C/C++ | `build/`, `CMakeFiles/`, `cmake-build-*` |
| D | `.dub/` |
| Swift | `.build/`, `.swiftpm/` |
| R | `renv/`, `packrat/` |
| Nim | `nimcache/` |

**Low impact:**

| Language | Directories |
|----------|-------------|
| Lua | `lua_modules/`, `luarocks/` |
| Zig | `zig-cache/`, `zig-out/` |

## .gitignore Integration

Builder also reads patterns from `.gitignore` files in your project root. The `.builderignore` file takes precedence if both exist.

## Creation

### Automatic

```bash
bldr init
```

Generates a `.builderignore` with patterns for detected languages.

### Manual

```bash
touch .builderignore
```

Place in project root (same directory as `Builderfile` or `Builderspace`).

## Programmatic API

```d
import infrastructure.utils.files.ignore;

// Check if directory should be ignored (any language)
bool ignore = IgnoreRegistry.shouldIgnoreDirectoryAny("node_modules");

// Check for specific language
bool ignore = IgnoreRegistry.shouldIgnoreDirectory("target", TargetLanguage.Rust);

// Check file patterns
bool ignore = IgnoreRegistry.shouldIgnoreFile("test.pyc", TargetLanguage.Python);

// Get severity
auto severity = getIgnoreSeverity(TargetLanguage.JavaScript);
// Returns: IgnoreSeverity.Critical

// Combined checker (built-in + user patterns)
auto checker = new CombinedIgnoreChecker(".", TargetLanguage.Python);
if (checker.shouldIgnoreDirectory("my_dir"))
{
    // Skip scanning
}
```

### Severity Levels

```d
enum IgnoreSeverity
{
    None,      // No dependency directories
    Low,       // Small directories, minimal impact
    Moderate,  // Can cause slowdowns
    High,      // Major performance issues
    Critical   // Can cause system hangs
}
```

## Performance Impact

Properly configured ignore patterns dramatically improve Builder's performance:

| Language | Without Ignores | With Ignores | Improvement |
|----------|----------------|--------------|-------------|
| JavaScript (large project) | 45s | 2s | 22x |
| Python (with venv) | 12s | 1.5s | 8x |
| Rust (with target/) | 8s | 1s | 8x |
| Java (with .gradle) | 15s | 2s | 7.5x |

## Best Practices

1. **Always ignore dependency directories** — These can contain millions of files
2. **Ignore build artifacts** — They're regenerated anyway
3. **Keep patterns simple** — Complex globs can slow down matching
4. **Update after adding dependencies** — New package managers create new directories

## Troubleshooting

### Builder is scanning too many files

Add more patterns to `.builderignore`, especially dependency directories.

### Builder is skipping files it shouldn't

Check if patterns are too broad. Use more specific patterns.

### Changes aren't taking effect

Builder loads patterns at startup. Restart or re-run the command.

## See Also

- [CLI Reference](./CLI.md)
- [Configuration](../architecture/DSL.md)
