# Repository Rules System

**External Dependency Management for Builder**

## Overview

The Repository Rules System is Builder's solution for managing external dependencies (libraries, frameworks, tools) in a hermetic, reproducible, and efficient manner. It replaces traditional approaches like Git submodules, system packages, and manual downloads with a declarative, content-addressable system.

## Motivation

### Problems with Traditional Approaches

**Git Submodules:**
- Mutable (branches can change)
- Slow (requires full git clone)
- No integrity verification
- Complex workflow (multiple git commands)
- Version conflicts across projects

**System Packages (apt/brew):**
- Non-hermetic (system-wide installation)
- Single version per system
- Platform-specific
- Requires admin privileges
- No reproducibility guarantees

**Manual Downloads:**
- No automation
- Manual version tracking
- No caching
- Team synchronization issues
- Security risks (no verification)

### Repository Rules Solution

- ✅ **Declarative**: Specify dependencies in Builderfile
- ✅ **Hermetic**: Cryptographic integrity verification
- ✅ **Fast**: Content-addressable caching
- ✅ **Reproducible**: Same hash → identical bits
- ✅ **Cross-platform**: Works on macOS, Linux, Windows
- ✅ **Lazy**: Fetch only when needed
- ✅ **Secure**: BLAKE3/SHA256 verification

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Repository Rules                          │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │  Fetcher     │  │  Verifier    │  │    Cache        │  │
│  │              │  │              │  │                 │  │
│  │ HTTP/Git     │──│ BLAKE3       │──│ Content-based   │  │
│  │ Download     │  │ SHA256       │  │ Storage         │  │
│  └──────────────┘  └──────────────┘  └─────────────────┘  │
│          │                 │                    │           │
│          └─────────────────┴────────────────────┘           │
│                            │                                │
│                     ┌──────────────┐                        │
│                     │  Resolver    │                        │
│                     │              │                        │
│                     │ @repo//path  │                        │
│                     └──────────────┘                        │
│                            │                                │
└────────────────────────────┼────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │ Build Graph     │
                    │                 │
                    │ Dependency      │
                    │ Resolution      │
                    └─────────────────┘
```

### Data Flow

1. **Declaration** → Parse `repository()` in Builderfile
2. **Registration** → Register rules in resolver
3. **Resolution** → Resolve `@repo//path:target` references
4. **Fetch** → Download if not cached
5. **Verify** → Compute and check integrity hash
6. **Extract** → Extract archive to cache
7. **Build** → Use cached repository in targets

## Usage

### Declaration Syntax

#### HTTP Archive

```d
repository("fmt") {
    url: "https://github.com/fmtlib/fmt/releases/download/10.2.1/fmt-10.2.1.zip";
    integrity: "312151a2d13c8327f5c9c586ac6cf7cddc1658e8f53edae0ec56509c8fa516c9";
    stripPrefix: "fmt-10.2.1";
}
```

#### Git Repository

```d
repository("protobuf") {
    url: "https://github.com/protocolbuffers/protobuf.git";
    gitCommit: "v25.1";
    integrity: "abc123...";
}
```

#### Local Filesystem

```d
repository("mylib-dev") {
    url: "/path/to/local/library";
}
```

### Reference Syntax

Use `@reponame//path:target` to reference external dependencies:

```d
target("my-app") {
    sources: ["main.cpp"];
    
    // External dependencies
    includes: [
        "@fmt//include",
        "@protobuf//src"
    ];
    
    deps: [
        "@fmt//:fmt",
        "@protobuf//:protobuf",
        ":local-target"  // Mix with internal deps
    ];
}
```

### Reference Format

- `@repo`: Repository root
- `@repo//path:target`: Specific target
- `@repo//path/to/dir:target`: Nested paths

Compared to internal references:
- `//path:target`: Absolute workspace reference
- `:target`: Relative (same package)

## Fields Reference

### Required Fields

**`url`** (string)
- HTTP/HTTPS URL for archives
- Git repository URL for git repos
- Filesystem path for local repos

```d
url: "https://github.com/project/releases/download/v1.0/archive.tar.gz";
```

**`integrity`** (string)
- Required for HTTP repositories
- BLAKE3 or SHA256 hash (64 hex characters)
- Ensures download integrity

```d
integrity: "abc123...";  // 64 hex chars
```

### Optional Fields

**`gitCommit`** (string)
- Git commit SHA or tag
- For Git repositories
- Mutually exclusive with `gitTag`

```d
gitCommit: "a1b2c3d4...";
gitCommit: "v1.0.0";  // Tag also works
```

**`gitTag`** (string)
- Git tag name
- Alternative to `gitCommit`
- More readable than commit SHA

```d
gitTag: "v1.0.0";
```

**`stripPrefix`** (string)
- Directory prefix to strip after extraction
- Common for archives with top-level directory

```d
stripPrefix: "project-1.0.0";
```

**`format`** (enum)
- Archive format: `Auto`, `TarGz`, `Tar`, `Zip`, `TarXz`, `TarBz2`
- Auto-detected from URL if not specified

```d
format: TarGz;
```

**`patches`** (map\<string, string\>)
- Future: Patches to apply after fetch
- Not yet implemented

## Caching

### Content-Addressable Storage

Repositories are stored by content hash:

```
.builder-cache/
├── repositories/
│   ├── fmt/
│   │   └── 312151a2.../
│   │       ├── CMakeLists.txt
│   │       └── include/
│   ├── protobuf/
│   │   └── abc123.../
│   │       └── src/
│   └── metadata.bin
```

### Cache Key Generation

```
cache_key = SHA256(url + integrity + gitCommit + gitTag)
```

Unique key ensures:
- Same repository + version → same cache entry
- Different versions → separate cache entries
- No collision risk

### Lazy Fetching

Repositories fetched only when:
1. Referenced by a target being built
2. Not already in cache
3. Explicitly requested

```bash
# Implicit fetch (during build)
bldr build :app-with-fmt

# Explicit fetch (no build)
builder repo fetch fmt
```

### Cache Management

```bash
# List cached repositories
builder repo list

# Show statistics
builder repo stats
# Output:
# Repositories: 5
# Total size: 45 MB
# Oldest: 2 days ago
# Newest: 5 minutes ago

# Clean specific repository
builder repo clean fmt

# Clean all repositories
builder repo clean --all

# Clean old repositories (>30 days)
builder repo clean --old
```

## Security

### Integrity Verification

Every HTTP download is verified:

```
1. Download → Fetch to temporary location
2. Hash → Compute BLAKE3/SHA256
3. Verify → Compare with expected integrity
4. Extract → Only if verification succeeds
5. Cache → Store with content-addressable key
```

If verification fails:

```
Error: Integrity check failed for fmt
Expected: 312151a2...
Got:      abc123...

The downloaded file may be corrupted or tampered with.
```

### Hermetic Builds

Repository rules enable hermetic builds:

- **Immutable**: Cached repositories never change
- **Reproducible**: Same hash → identical content
- **Verified**: Cryptographic guarantees
- **Sandboxed**: Can't access network or filesystem

### Best Practices

1. **Always specify `integrity`** for HTTP repositories
2. **Pin Git commits** (not branches) for reproducibility
3. **Use HTTPS URLs** to prevent MITM attacks
4. **Verify hashes** from official sources before adding
5. **Document repository sources** in comments

## Implementation Details

### Fetcher

**HTTP Fetching:**
- Uses `std.net.curl` for downloads
- Retry logic with exponential backoff (3 attempts)
- Supports all common archive formats
- Streaming downloads (no full-file buffering)

**Git Fetching:**
- Uses `git clone` with `--depth 1`
- Supports commit and tag pinning
- Shallow clones for speed

**Local Fetching:**
- Validates path exists and is directory
- No copying (direct reference)
- No integrity check (development only)

### Verifier

**BLAKE3 Hashing:**
- Hardware-accelerated (AVX2/NEON)
- 3-5x faster than SHA256
- 64-character hex output

**SHA256 Support:**
- For compatibility with existing systems
- Same 64-character hex format

### Cache

**Storage:**
- JSON metadata for cache entries
- Binary format for efficiency
- Automatic invalidation on corruption

**Eviction:**
- Manual eviction only (no automatic)
- Future: LRU + age-based + size-based

### Resolver

**Reference Resolution:**
1. Parse `@repo//path:target` syntax
2. Look up repository rule by name
3. Check cache first
4. Fetch if not cached
5. Return absolute filesystem path

**Integration:**
- Integrated with `DependencyResolver`
- Transparent to build system
- Works with existing target resolution

## Performance

### Time Complexity

- **Cache hit**: O(1) lookup
- **Cache miss**: O(download_time + extract_time)
- **Reference resolution**: O(1) after first fetch

### Space Complexity

- **Storage**: O(repository_size) per unique version
- **Deduplication**: Automatic via content-addressing
- **Metadata**: O(n) where n = number of cached repos

### Benchmarks

**Fetch Performance:**
```
fmt (10 MB):
  - Download: 2.5s (4 MB/s)
  - Verify:   0.3s (BLAKE3)
  - Extract:  0.8s
  - Total:    3.6s

Subsequent builds (cached):
  - Lookup:   <1ms
  - Total:    <1ms (1000x faster)
```

**Build Performance:**
```
Clean build (no cache):
  - Fetch 3 repos: 12s
  - Build:         45s
  - Total:         57s

Incremental build (cached):
  - Fetch:  0s (cached)
  - Build:  2s
  - Total:  2s (28x faster)
```

## CLI Commands

### Fetch

```bash
# Fetch specific repository
builder repo fetch fmt

# Fetch all repositories
builder repo fetch --all
```

### List

```bash
# List all cached repositories
builder repo list

# Output:
# fmt     312151a2...   10.2 MB   2 days ago
# json    abc123...     5.1 MB    1 hour ago
```

### Stats

```bash
# Show cache statistics
builder repo stats

# Output:
# Repositories: 5
# Total size: 45 MB
# Oldest fetch: 7 days ago
# Newest fetch: 5 minutes ago
```

### Clean

```bash
# Clean specific repository
builder repo clean fmt

# Clean all repositories
builder repo clean --all

# Clean old repositories (>30 days)
builder repo clean --old

# Dry run (show what would be cleaned)
builder repo clean --dry-run
```

### Hash

```bash
# Compute hash of file
builder repo hash file.tar.gz

# Compute hash from stdin
curl -L https://... | builder repo hash -

# Use SHA256 instead of BLAKE3
builder repo hash --sha256 file.tar.gz
```

## Advanced Use Cases

### Multiple Versions

Support multiple versions of same library:

```d
repository("llvm-16") {
    url: "https://.../llvm-16.0.6.tar.xz";
    integrity: "...";
}

repository("llvm-17") {
    url: "https://.../llvm-17.0.1.tar.xz";
    integrity: "...";
}

// Use different versions
target("legacy") {
    deps: ["@llvm-16//lib:Support"];
}

target("modern") {
    deps: ["@llvm-17//lib:Support"];
}
```

### Local Development Override

Override remote with local for development:

```d
// Production (comment out)
// repository("mylib") {
//     url: "https://github.com/me/mylib/archive/v1.0.tar.gz";
//     integrity: "...";
// }

// Development
repository("mylib") {
    url: "/Users/me/dev/mylib";
}
```

### Monorepo with External Deps

Combine internal and external dependencies:

```d
// External dependencies
repository("boost") { ... }
repository("fmt") { ... }

// Internal targets
target("core") {
    sources: ["src/core/**/*.cpp"];
    deps: ["@boost//libs:system"];
}

target("app") {
    sources: ["src/app/**/*.cpp"];
    deps: [
        ":core",              // Internal
        "@fmt//:fmt",         // External
        "@boost//libs:thread" // External
    ];
}
```

### Cross-Platform Dependencies

Handle platform-specific dependencies:

```d
// Common base
repository("common-lib") { ... }

// Platform-specific
repository("windows-sdk") {
    url: "https://.../windows-sdk.zip";
    integrity: "...";
}

repository("macos-sdk") {
    url: "https://.../macos-sdk.tar.gz";
    integrity: "...";
}

// Conditional usage
target("app") {
    deps: ["@common-lib//:lib"];
    
    // Use platform-specific deps in build logic
    when(windows) {
        deps: ["@windows-sdk//:sdk"];
    }
    when(macos) {
        deps: ["@macos-sdk//:sdk"];
    }
}
```

## Comparison to Other Systems

### vs Bazel `http_archive`

**Similarities:**
- HTTP download with integrity
- Content-addressable caching
- `@repo//` syntax

**Differences:**
- Builder uses BLAKE3 (faster)
- Unified with Git and local repos
- Simpler DSL syntax
- No Starlark required

### vs Buck2 External Dependencies

**Similarities:**
- Content-addressable storage
- Lazy fetching
- Hermetic builds

**Differences:**
- Builder: 26+ languages
- Builder: Process-based plugins
- Builder: More flexible DSL

### vs Cargo Dependencies

**Similarities:**
- Declarative dependencies
- Version resolution
- Cached downloads

**Differences:**
- Builder: Language-agnostic
- Builder: Manual hash specification (more secure)
- Builder: No central registry (decentralized)
- Cargo: Automatic semver resolution

### vs Maven/Gradle

**Similarities:**
- Central repository concept
- Dependency management
- Transitive dependencies

**Differences:**
- Builder: Not JVM-specific
- Builder: Explicit integrity hashes
- Builder: Faster (BLAKE3, content-addressing)
- Maven/Gradle: XML/Groovy DSL

## Troubleshooting

### Common Issues

**Repository Not Found:**
```
Error: Unknown repository: fmt
```
Solution: Add `repository("fmt") { ... }` declaration

**Integrity Verification Failed:**
```
Error: Integrity check failed
Expected: 312151a2...
Got:      abc123...
```
Solutions:
1. Verify hash from official source
2. Re-download (may be corrupted)
3. Compute hash: `bldr repo hash file.tar.gz`

**Archive Extraction Failed:**
```
Error: Failed to extract archive
```
Solutions:
1. Check format is supported
2. Verify tar/unzip installed
3. Check disk space

**Git Clone Failed:**
```
Error: Failed to clone Git repository
```
Solutions:
1. Check network connectivity
2. Verify Git installed
3. Check URL is correct
4. Verify commit/tag exists

**Cache Corruption:**
```
Warning: Invalid cache entry, removing...
```
Solution: Automatic re-fetch. Or: `bldr repo clean fmt && bldr build`

## Future Enhancements

1. **Patch Support**: Apply patches after fetch
2. **Mirrors**: Fallback URLs for reliability
3. **Registry**: Optional package registry (like crates.io)
4. **Version Resolution**: Semantic versioning and constraints
5. **Workspace Overlays**: Override repository files
6. **Compressed Caching**: Compress cached repositories
7. **CDN Integration**: Use CDN for popular packages
8. **Build File Generation**: Auto-generate build files for external deps
9. **Transitive Dependencies**: Automatic dependency resolution
10. **Lock Files**: Pin all transitive dependencies

## References

- [Repository Module Source](../../source/repository/)
- [Example](../../examples/repository-rules/)
- [Builderfile DSL Specification](../architecture/dsl.md)
- [Content-Addressable Storage](./graphcache.md)
- [Hermetic Builds](./hermetic.md)
- [BLAKE3 Hashing](./blake3.md)

