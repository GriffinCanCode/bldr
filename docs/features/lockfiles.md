# Lockfile Generation

**Module:** `infrastructure.analysis.lockfile`

## Overview

Lockfile generation provides deterministic dependency resolution for supported package managers. The system caches resolution results by manifest content hash and produces canonical, sorted output.

## Supported Package Managers

| Manager | Manifest | Lockfile | Format |
|---------|----------|----------|--------|
| npm | `package.json` | `package-lock.json` | JSON v3 |
| yarn | `package.json` | `yarn.lock` | YAML-like |
| pnpm | `package.json` | `pnpm-lock.yaml` | YAML |
| cargo | `Cargo.toml` | `Cargo.lock` | TOML |
| go | `go.mod` | `go.sum` | Checksum |
| maven | `pom.xml` | `dependency-lock.json` | JSON |

## Architecture

### Components

**Types** (`lockfile/types.d`):
- `ResolvedDependency` - Package with version and integrity hash
- `Lockfile` - Complete lockfile with metadata
- `LockfileDiff` - Diff between lockfiles
- `ILockfileGenerator` - Interface for generators

**Cache** (`lockfile/cache.d`):
- Content-addressable lockfile cache
- LRU eviction
- Binary serialization with versioning

**Generators** (`lockfile/generators/`):
- `npm.d` - npm/yarn/pnpm support
- `cargo.d` - Rust Cargo.lock
- `go.d` - Go modules go.sum
- `maven.d` - Maven/Gradle

### Factory

```d
auto generator = LockfileFactory.create("package.json", cache);
```

The factory detects package manager from manifest filename and auto-detects npm flavor (npm/yarn/pnpm) from existing lockfiles.

## Usage

### Basic Generation

```d
import infrastructure.analysis.lockfile;

// Create cache (optional)
auto cache = new LockfileCache(".builder-cache/lockfiles");

// Create generator
auto generator = LockfileFactory.create("package.json", cache);

// Generate lockfile
auto result = generator.generate("package.json");
if (result.isOk) {
    auto lockfile = result.unwrap();
    
    foreach (dep; lockfile.dependencies) {
        writefln("%s@%s", dep.name, dep.version_);
    }
    
    generator.write(lockfile, "package-lock.json");
}
```

### CI Mode (Frozen)

```d
auto options = GenerateOptions.ci();  // Sets frozen = true
auto result = generator.generate("package.json", options);

if (result.isErr) {
    stderr.writeln("Lockfile out of sync with manifest");
    return 1;
}
```

### Check Freshness

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
    writefln("Dependencies: %d", lockfile.dependencies.length);
}
```

### Compute Diff

```d
auto oldLock = generator.parse("package-lock.json.old").unwrap();
auto newLock = generator.parse("package-lock.json").unwrap();

auto diff = LockfileDiff.compute(oldLock, newLock);

if (diff.hasChanges()) {
    writefln("Added: %d, Removed: %d, Updated: %d",
        diff.added.length, diff.removed.length, diff.updated.length);
}
```

## Generator Interface

```d
interface ILockfileGenerator
{
    /// Generate lockfile from manifest
    BuildResult!Lockfile generate(string manifestPath, GenerateOptions options = GenerateOptions.init);
    
    /// Parse existing lockfile
    BuildResult!Lockfile parse(string lockfilePath);
    
    /// Write lockfile to disk
    BuildResult!void write(const ref Lockfile lockfile, string outputPath);
    
    /// Check if lockfile matches manifest
    bool isUpToDate(string manifestPath, string lockfilePath);
    
    /// Get expected lockfile name
    string lockfileName() const pure @safe;
    
    /// Package manager type
    PackageManagerType type() const pure @safe;
}
```

## Generation Options

```d
struct GenerateOptions
{
    bool frozen;           // Fail if lockfile would change
    bool update;           // Update all dependencies to latest
    bool production;       // Only production dependencies
    bool includeOptional;  // Include optional dependencies
    string[] exclude;      // Packages to exclude
    
    static GenerateOptions ci() pure @safe
    {
        GenerateOptions opts;
        opts.frozen = true;
        return opts;
    }
}
```

## Caching

Lockfiles are cached by manifest content hash:

```
.builder-cache/lockfiles/
├── index.bin              # Cache index
└── abc123def456.lock      # Cached lockfile
```

Cache key: `BLAKE3(manifest content)`

## Determinism

Output is deterministic:
- Dependencies sorted alphabetically
- Consistent whitespace (2-space indent for JSON)
- Unix line endings (LF)
- Platform-independent

## CLI Commands

```bash
# Generate lockfile
builder lockfile generate

# Check if up-to-date
builder lockfile check

# Frozen check (fails if out of sync)
builder lockfile check --frozen

# Show diff
builder lockfile diff
```

## Integration

### In Builderfile

```d
target("app") {
    language: typescript;
    sources: ["src/**/*.ts"];
    lockfile: "package-lock.json";
}
```

### Pre-build Hook

```d
pre_build: [
    "builder lockfile check --frozen"
];
```

## Error Handling

| Error | Cause | Solution |
|-------|-------|----------|
| `Manifest not found` | Missing package.json/Cargo.toml | Create manifest file |
| `Lockfile out of date` | Manifest changed | Run `builder lockfile generate` |
| `Unknown package manager` | Unsupported manifest | Use supported format |

## Extending

Implement `ILockfileGenerator` for new package managers:

```d
final class MyLockfileGenerator : ILockfileGenerator
{
    override BuildResult!Lockfile generate(string manifestPath, GenerateOptions options)
    {
        // Parse manifest, resolve dependencies, build Lockfile
    }
    
    override BuildResult!Lockfile parse(string lockfilePath)
    {
        // Parse existing lockfile format
    }
    
    override BuildResult!void write(const ref Lockfile lockfile, string outputPath)
    {
        // Write in appropriate format
    }
    
    override bool isUpToDate(string manifestPath, string lockfilePath)
    {
        // Compare manifest hash with stored hash
    }
    
    override string lockfileName() const pure @safe => "my-lock.json";
    override PackageManagerType type() const pure @safe => PackageManagerType.Unknown;
}
```

## See Also

- [Caching](caching.md)
- [Determinism](../architecture/determinism.md)
