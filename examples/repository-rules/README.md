# Repository Rules Example

This example demonstrates how to use **Repository Rules** to fetch and use external dependencies.

## Overview

Repository Rules enable you to declare external dependencies (libraries, tools, frameworks) in your Builderfile and have Builder automatically fetch, verify, and cache them.

## Key Features

1. **Declarative**: Specify dependencies in `Builderspace`
2. **Hermetic**: Cryptographic integrity verification (BLAKE3/SHA256)
3. **Cached**: Fetch once, use many times
4. **Flexible**: HTTP archives, Git repositories, or local paths

## Files

- `Builderspace`: Repository declarations
- `Builderfile`: Targets using external dependencies
- `main-fmt.cpp`: Example using fmt library
- `main-json.cpp`: Example using JSON library
- `main-both.cpp`: Example combining multiple external deps
- `utils.cpp/h`: Local library (internal dependency)

## Usage

### 1. Build All Targets

```bash
bldr build
```

On first build, Builder will:
1. Download `fmt` (10.2 MB archive)
2. Download `json` (Git repository)
3. Verify integrity with BLAKE3 hashes
4. Extract to `.builder-cache/repositories/`
5. Build targets using cached repositories

### 2. Build Specific Target

```bash
# Build single target
bldr build :app-with-fmt

# Build with external dependency
bldr build :app-with-json
```

### 3. Run Executables

```bash
# Run fmt example
./bin/app-with-fmt

# Run JSON example
./bin/app-with-json

# Run combined example
./bin/app-with-both
```

### 4. Manage Repository Cache

```bash
# List cached repositories
builder repo list

# Show cache statistics
builder repo stats

# Clean specific repository
builder repo clean fmt

# Clean all repositories
builder repo clean --all
```

## Repository Declaration

### HTTP Archive

```d
repository("fmt") {
    url: "https://github.com/fmtlib/fmt/releases/download/10.2.1/fmt-10.2.1.zip";
    integrity: "312151a2d13c8327f5c9c586ac6cf7cddc1658e8f53edae0ec56509c8fa516c9";
    stripPrefix: "fmt-10.2.1";  // Remove top-level directory
}
```

**Fields:**
- `url`: Download URL (HTTP/HTTPS)
- `integrity`: BLAKE3 or SHA256 hash (64 hex characters)
- `stripPrefix`: Optional directory prefix to strip after extraction

### Git Repository

```d
repository("json") {
    url: "https://github.com/nlohmann/json.git";
    gitTag: "v3.11.3";  // Or gitCommit for SHA
    integrity: "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d";
}
```

**Fields:**
- `url`: Git repository URL
- `gitTag`: Git tag name (or `gitCommit` for SHA)
- `integrity`: Commit/tag integrity hash

### Local Filesystem

```d
repository("mylib-dev") {
    url: "/path/to/local/library";
}
```

**Note:** No integrity check for local repositories (development only).

## Referencing External Dependencies

Use `@reponame//path:target` syntax:

```d
target("my-app") {
    sources: ["main.cpp"];
    includes: ["@fmt//include"];     // Include external headers
    deps: ["@fmt//:fmt"];             // Link external library
}
```

**Syntax:**
- `@repo`: Repository root
- `@repo//path:target`: Specific target in repository
- `@repo//include`: Include directory

## Benefits

### 1. Reproducible Builds

Same `integrity` hash → identical bits

```d
// This will always fetch the exact same version
repository("fmt") {
    url: "https://...";
    integrity: "312151a2...";  // Cryptographic guarantee
}
```

### 2. Fast Iteration

After first fetch, repositories are cached:

```bash
# First build: Downloads and verifies
$ bldr build
Fetching repository: fmt
Downloaded and verified: fmt (10.2 MB)
Building...

# Subsequent builds: Uses cache
$ bldr build
Repository already cached: fmt
Building... (instant!)
```

### 3. Offline Builds

Once cached, no network required:

```bash
# Disconnect from internet
$ bldr build  # Still works!
```

### 4. Team Consistency

Everyone gets same dependencies:

```bash
# Developer A
$ bldr build  # Downloads fmt 10.2.1

# Developer B
$ bldr build  # Gets exact same fmt 10.2.1
```

### 5. Security

Integrity verification prevents tampering:

```bash
# If download is corrupted or modified:
Error: Integrity check failed
Expected: 312151a2...
Got:      abc123...
```

## Comparison to Other Approaches

### vs Git Submodules

| Feature | Repository Rules | Git Submodules |
|---------|-----------------|----------------|
| **Mutability** | Immutable (pinned hashes) | Mutable (branches) |
| **Speed** | Fast (HTTP archives) | Slow (git clone) |
| **Verification** | Cryptographic (BLAKE3) | None |
| **Workflow** | Simple (declarative) | Complex (git commands) |

### vs Manual Downloads

| Feature | Repository Rules | Manual |
|---------|-----------------|--------|
| **Automation** | Automatic fetch | Manual download |
| **Versioning** | Built-in | Manual tracking |
| **Cache** | Automatic | None |
| **Team Sync** | Automatic | Manual coordination |

### vs System Packages

| Feature | Repository Rules | apt/brew |
|---------|-----------------|----------|
| **Hermetic** | Yes (isolated) | No (system-wide) |
| **Versions** | Multiple per project | One system-wide |
| **Portable** | Cross-platform | Platform-specific |
| **Speed** | Cached locally | Network fetch |

## Advanced Features

### Strip Prefix

Many archives have a top-level directory. Use `stripPrefix` to flatten:

```
fmt-10.2.1.zip
└── fmt-10.2.1/
    ├── CMakeLists.txt
    └── include/

// With stripPrefix: "fmt-10.2.1"
@fmt//CMakeLists.txt  ✓
@fmt//include/        ✓

// Without stripPrefix:
@fmt//fmt-10.2.1/CMakeLists.txt  ✗ (awkward)
```

### Multiple Versions

Support multiple versions of same library:

```d
repository("fmt-9") {
    url: "https://.../fmt-9.1.0.zip";
    integrity: "...";
}

repository("fmt-10") {
    url: "https://.../fmt-10.2.1.zip";
    integrity: "...";
}

// Use different versions
target("legacy-app") {
    deps: ["@fmt-9//:fmt"];
}

target("modern-app") {
    deps: ["@fmt-10//:fmt"];
}
```

### Local Development Override

Override remote repository with local path:

```d
// Production
repository("mylib") {
    url: "https://github.com/me/mylib/archive/v1.0.tar.gz";
    integrity: "...";
}

// Development (comment out production, use local)
repository("mylib") {
    url: "/Users/me/dev/mylib";  // Local development copy
}
```

## Computing Integrity Hashes

### From File

```bash
# BLAKE3
builder repo hash fmt-10.2.1.zip

# Output:
312151a2d13c8327f5c9c586ac6cf7cddc1658e8f53edae0ec56509c8fa516c9
```

### From URL

```bash
# Download and compute hash
curl -L https://github.com/fmtlib/fmt/releases/download/10.2.1/fmt-10.2.1.zip | \
  builder repo hash -

# Or use SHA256
shasum -a 256 fmt-10.2.1.zip
```

## Troubleshooting

### Repository Not Found

```
Error: Unknown repository: fmt
```

**Solution:** Add `repository("fmt") { ... }` to `Builderspace`

### Integrity Verification Failed

```
Error: Integrity check failed
Expected: 312151a2...
Got:      abc123...
```

**Solutions:**
1. Verify hash from official source
2. Re-download archive (might be corrupted)
3. Compute hash yourself: `bldr repo hash file.zip`

### Archive Extraction Failed

```
Error: Failed to extract archive
```

**Solutions:**
1. Check archive format is supported (tar.gz, zip, tar.xz, tar.bz2)
2. Verify tar/unzip tools are installed
3. Check disk space

### Cache Corruption

```
Warning: Invalid cache entry for fmt, removing...
```

**Solution:** Cache automatically re-fetches. Or manually:
```bash
bldr repo clean fmt
bldr build
```

## Best Practices

1. **Always specify `integrity`** for HTTP repositories
2. **Pin Git commits** (not branches) for reproducibility
3. **Use HTTPS URLs** to prevent MITM attacks
4. **Verify hashes** from official sources
5. **Document dependencies** in README
6. **Keep cache clean**: `bldr repo clean --old`

## Next Steps

- Read [Repository Rules Documentation](../../source/repository/README.md)
- See [Hermetic Builds](../../docs/features/hermetic.md)
- Check [BLAKE3 Hashing](../../docs/features/blake3.md)

