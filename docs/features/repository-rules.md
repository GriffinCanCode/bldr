# Repository Rules

External dependency management through declarative repository rules.

## Overview

Repository rules enable bldr to fetch, cache, and reference external dependencies (libraries, frameworks, tools) in a hermetic, reproducible manner. Repositories are declared in Builderfile, downloaded once, cryptographically verified, and cached locally.

### Features

- **Declarative**: Specify dependencies in Builderfile
- **Hermetic**: Cryptographic integrity verification (BLAKE3/SHA256)
- **Fast**: Content-addressable caching
- **Reproducible**: Same hash → identical bits
- **Cross-platform**: Works on macOS, Linux, Windows
- **Lazy**: Fetch only when needed

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Repository Rules                         │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │  Fetcher     │  │  Verifier    │  │    Cache        │  │
│  │              │  │              │  │                 │  │
│  │ HTTP/Git     │──│ BLAKE3       │──│ Content-based   │  │
│  │ Download     │  │ SHA256       │  │ Storage         │  │
│  └──────────────┘  └──────────────┘  └─────────────────┘  │
│          │                 │                    │          │
│          └─────────────────┴────────────────────┘          │
│                            │                               │
│                     ┌──────────────┐                       │
│                     │  Resolver    │                       │
│                     │              │                       │
│                     │ @repo//path  │                       │
│                     └──────────────┘                       │
│                            │                               │
└────────────────────────────┼───────────────────────────────┘
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

- `@repo` — Repository root
- `@repo//path:target` — Specific target
- `@repo//path/to/dir:target` — Nested paths

Compared to internal references:
- `//path:target` — Absolute workspace reference
- `:target` — Relative (same package)

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

```d
gitCommit: "a1b2c3d4...";
gitCommit: "v1.0.0";  // Tag also works
```

**`gitTag`** (string)
- Git tag name
- Alternative to `gitCommit`

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

## Caching

### Content-Addressable Storage

Repositories stored by content hash:

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

1. Always specify `integrity` for HTTP repositories
2. Pin Git commits (not branches) for reproducibility
3. Use HTTPS URLs to prevent MITM attacks
4. Verify hashes from official sources before adding
5. Document repository sources in comments

## Implementation

### Source Files

- **Types** (`infrastructure/repository/core/types.d`): Core data structures
  - `RepositoryRule`, `CachedRepository`, `ResolvedRepository`
  - `RepositoryKind` (Http, Git, Local)
  - `ArchiveFormat` (Auto, TarGz, Tar, Zip, TarXz, TarBz2)

- **Fetcher** (`infrastructure/repository/acquisition/fetcher.d`): Downloads and extracts
  - HTTP downloads with retry and exponential backoff
  - Archive extraction (tar.gz, zip, tar.xz, tar.bz2)
  - Git clone with commit/tag pinning
  - Local filesystem validation

- **Verifier** (`infrastructure/repository/acquisition/verifier.d`): Integrity verification
  - BLAKE3 hash verification (64-character hex)
  - SHA256 support

- **Cache** (`infrastructure/repository/storage/cache.d`): Local cache
  - Content-addressable storage
  - Metadata persistence (JSON)
  - Cache statistics

- **Resolver** (`infrastructure/repository/resolution/resolver.d`): Reference resolution
  - Lazy fetching (on-demand)
  - Path resolution for targets
  - `@repo//` syntax parsing

## Performance

### Time Complexity

- **Cache hit**: O(1) lookup
- **Cache miss**: O(download_time + extract_time)
- **Reference resolution**: O(1) after first fetch

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

## Advanced Use Cases

### Multiple Versions

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

```d
// Production
// repository("mylib") {
//     url: "https://github.com/me/mylib/archive/v1.0.tar.gz";
//     integrity: "...";
// }

// Development override
repository("mylib") {
    url: "/Users/me/dev/mylib";
}
```

### Mixed Internal/External Dependencies

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
3. Check URL hasn't changed

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

## Comparison

| Feature | bldr | Bazel | Buck2 | Cargo |
|---------|------|-------|-------|-------|
| HTTP Archive | ✓ | ✓ | ✓ | — |
| Git Clone | ✓ | ✓ | ✓ | ✓ |
| Integrity Hash | BLAKE3/SHA256 | SHA256 | SHA256 | SHA256 |
| Content-Addressable | ✓ | ✓ | ✓ | ✓ |
| Lazy Fetching | ✓ | ✓ | ✓ | ✓ |
| Language-Agnostic | ✓ | ✓ | ✓ | Rust only |

## See Also

- [Builderfile DSL](../architecture/DSL.md)
- [Content-Addressable Storage](./graphcache.md)
- [Hermetic Builds](./hermetic.md)
