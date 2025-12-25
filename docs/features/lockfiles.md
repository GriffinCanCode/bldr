# Deterministic Lockfile Generation

## Overview

Lockfile generation provides reproducible builds through deterministic dependency resolution across all supported package managers. Inspired by pnpm's content-addressable approach, the system:

- **Caches Resolutions**: Resolution results cached by manifest content hash
- **Ensures Determinism**: Sorted, canonical output regardless of platform
- **Supports Incremental Updates**: Only re-resolve changed dependencies
- **Enables CI Mode**: Fail builds if lockfile would change

## Architecture

### Components

1. **Types** (`source/infrastructure/analysis/lockfile/types.d`)
   - `ResolvedDependency`: Package with exact version and integrity hash
   - `Lockfile`: Complete lockfile with metadata and dependencies
   - `LockfileDiff`: Diff between two lockfiles (added/removed/updated)
   - `ILockfileGenerator`: Interface for all package manager generators

2. **Cache** (`source/infrastructure/analysis/lockfile/cache.d`)
   - Content-addressable lockfile cache
   - LRU eviction for size management
   - Binary serialization with schema versioning

3. **Generators** (`source/infrastructure/analysis/lockfile/generators/`)
   - `npm.d`: npm/yarn/pnpm (package-lock.json, yarn.lock, pnpm-lock.yaml)
   - `cargo.d`: Rust (Cargo.lock)
   - `go.d`: Go modules (go.sum)
   - `maven.d`: Java/Kotlin (dependency-lock.json)

### Supported Package Managers

| Manager | Manifest        | Lockfile            | Format    |
|---------|-----------------|---------------------|-----------|
| npm     | package.json    | package-lock.json   | JSON v3   |
| yarn    | package.json    | yarn.lock           | YAML-like |
| pnpm    | package.json    | pnpm-lock.yaml      | YAML      |
| cargo   | Cargo.toml      | Cargo.lock          | TOML      |
| go      | go.mod          | go.sum              | Checksum  |
| maven   | pom.xml         | dependency-lock.json| JSON      |

## Usage

### Basic Lockfile Generation

```d
import infrastructure.analysis.lockfile;

// Create cache (optional but recommended)
auto cache = new LockfileCache(".builder-cache/lockfiles");

// Create generator for manifest type
auto generator = LockfileFactory.create("package.json", cache);

// Generate lockfile
auto result = generator.generate("package.json");
if (result.isOk) {
    auto lockfile = result.unwrap();
    
    // Access resolved dependencies
    foreach (dep; lockfile.dependencies) {
        writefln("%s@%s", dep.name, dep.version_);
    }
    
    // Write to disk
    generator.write(lockfile, "package-lock.json");
}
```

### CI Mode (Frozen Lockfile)

```d
// Fail if lockfile would change
auto options = GenerateOptions.ci();
auto result = generator.generate("package.json", options);

if (result.isErr) {
    // Lockfile out of sync with manifest
    stderr.writeln("Error: Lockfile is out of date!");
    return 1;
}
```

### Check If Up-to-Date

```d
if (!generator.isUpToDate("package.json", "package-lock.json")) {
    writeln("Lockfile needs regeneration");
}
```

### Parse Existing Lockfile

```d
auto lockResult = generator.parse("package-lock.json");
if (lockResult.isOk) {
    auto lockfile = lockResult.unwrap();
    writefln("Lockfile has %d dependencies", lockfile.count());
}
```

### Compute Diff Between Lockfiles

```d
auto oldLock = generator.parse("package-lock.json.old").unwrap();
auto newLock = generator.parse("package-lock.json").unwrap();

auto diff = LockfileDiff.compute(oldLock, newLock);

if (diff.hasChanges()) {
    writefln("Added: %d, Removed: %d, Updated: %d",
        diff.added.length, diff.removed.length, diff.updated.length);
    
    foreach (dep; diff.added)
        writefln("  + %s@%s", dep.name, dep.version_);
    
    foreach (dep; diff.removed)
        writefln("  - %s@%s", dep.name, dep.version_);
    
    foreach (dep; diff.updated)
        writefln("  ~ %s@%s", dep.name, dep.version_);
}
```

## Caching Strategy

### Content-Addressable Cache

Lockfiles are cached by manifest content hash:

```
.builder-cache/lockfiles/
├── index.bin              # Cache index (binary)
├── abc123def456.lock      # Cached lockfile
└── 789xyz000111.lock
```

### Cache Flow

```
┌─────────────────┐
│ Read Manifest   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Compute Hash    │ ◀─── BLAKE3 content hash
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌───────────────┐
│ Cache Lookup    │────▶│ Cache Hit     │ ◀─── <1ms
└────────┬────────┘     └───────────────┘
         │ miss
         ▼
┌─────────────────┐
│ Resolve Deps    │ ◀─── Parse manifest + resolve
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Store in Cache  │
└─────────────────┘
```

### Performance

| Operation              | Time       | Notes                    |
|------------------------|------------|--------------------------|
| Cache hit              | <1ms       | Hash lookup only         |
| Parse lockfile         | 5-50ms     | Depends on dep count     |
| Generate (cached deps) | 50-200ms   | No network calls         |
| Full resolution        | 1-30s      | Network-dependent        |

## Determinism Guarantees

### Sorted Output

Dependencies are always sorted alphabetically by name:

```json
{
  "packages": {
    "node_modules/lodash": { ... },
    "node_modules/react": { ... },
    "node_modules/vue": { ... }
  }
}
```

### Canonical Formatting

- Consistent whitespace (2-space indent for JSON)
- No trailing whitespace
- Unix line endings (LF)

### Platform Independence

Same lockfile generated regardless of:
- Operating system (Windows, macOS, Linux)
- File system (case-sensitive or not)
- Locale settings

## Integration with Build System

### In Builderfile

```d
target("app") {
    language: typescript;
    sources: ["src/**/*.ts"];
    
    // Lockfile automatically checked/generated
    lockfile: "package-lock.json";
}
```

### Pre-build Hook

```d
// Check lockfile before build
pre_build: [
    "builder lockfile check --frozen"
];
```

## CLI Commands

```bash
# Generate lockfile
builder lockfile generate

# Check if lockfile is up-to-date
builder lockfile check

# Check in CI mode (fails if out of sync)
builder lockfile check --frozen

# Show diff from previous lockfile
builder lockfile diff
```

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Manifest not found` | Missing package.json/Cargo.toml | Create manifest file |
| `Lockfile out of date` | Manifest changed | Run `builder lockfile generate` |
| `Unknown package manager` | Unsupported manifest | Use supported format |

### Error Example

```d
auto result = generator.generate("package.json");
if (result.isErr) {
    auto error = result.unwrapErr();
    stderr.writeln("Lockfile generation failed: ", error.message());
}
```

## Configuration

### Cache Location

Default: `.builder-cache/lockfiles/`

Override via environment:
```bash
export BUILDER_LOCKFILE_CACHE=/path/to/cache
```

### Cache Size

Default: 1000 entries (LRU eviction)

```d
auto cache = new LockfileCache("/path/to/cache");
cache.prune(500);  // Reduce to 500 entries
```

## Extending for New Package Managers

Implement `ILockfileGenerator`:

```d
final class MyLockfileGenerator : ILockfileGenerator
{
    override BuildResult!Lockfile generate(string manifestPath, GenerateOptions options) @system
    {
        // Parse manifest
        // Resolve dependencies
        // Build Lockfile struct
        // Return result
    }
    
    override BuildResult!Lockfile parse(string lockfilePath) @system
    {
        // Parse existing lockfile
    }
    
    override BuildResult!void write(const ref Lockfile lockfile, string outputPath) @system
    {
        // Write lockfile to disk
    }
    
    override bool isUpToDate(string manifestPath, string lockfilePath) @system
    {
        // Check if lockfile matches manifest
    }
    
    override string lockfileName() const pure @safe
    {
        return "my-lock.json";
    }
    
    override PackageManagerType type() const pure @safe
    {
        return PackageManagerType.Unknown;
    }
}
```

## Related Features

- [Caching](caching.md) - Action-level caching
- [Determinism](determinism.md) - Reproducible builds
- [Remote Execution](remote-execution.md) - Distributed builds

