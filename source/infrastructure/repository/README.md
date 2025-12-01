# Repository Rules System

**External Dependency Management for Builder**

## Overview

The Repository Rules System enables Builder to fetch, cache, and reference external dependencies (libraries, tools, frameworks) through a declarative DSL. Repositories are downloaded once, cryptographically verified, and cached locally for fast hermetic builds.

## Architecture

### Core Components

1. **Types** (`types.d`): Core data structures
   - `RepositoryRule`: Declaration of an external repository
   - `CachedRepository`: Metadata for cached repositories
   - `ResolvedRepository`: Runtime resolution result
   - `RepositoryKind`: HTTP, Git, or Local

2. **Fetcher** (`fetcher.d`): Downloads and extracts repositories
   - HTTP downloads with retry logic and exponential backoff
   - Archive extraction (tar.gz, zip, tar.xz, tar.bz2)
   - Git clone with commit/tag pinning
   - Local filesystem validation

3. **Verifier** (`verifier.d`): Cryptographic integrity verification
   - BLAKE3 hash verification (64-character hex)
   - SHA256 support
   - Content-addressable security guarantees

4. **Cache** (`cache.d`): Local repository cache
   - Content-addressable storage by hash
   - Metadata persistence (JSON)
   - Cache statistics and management
   - Automatic invalidation

5. **Resolver** (`resolver.d`): Resolves `@repo//` references
   - Lazy fetching (on-demand)
   - Path resolution for targets
   - Reference validation

## Usage

### Define Repositories

In `Builderspace` or `Builderfile`:

```d
// HTTP archive with integrity verification
repository("llvm") {
    url: "https://github.com/llvm/llvm-project/releases/download/llvmorg-17.0.1/llvm-17.0.1.tar.xz";
    integrity: "abc123...";  // BLAKE3 or SHA256 hash (64 hex chars)
    stripPrefix: "llvm-17.0.1";  // Strip top-level directory
}

// Git repository with commit pinning
repository("protobuf") {
    url: "https://github.com/protocolbuffers/protobuf.git";
    gitCommit: "v25.1";
    integrity: "def456...";
}

// Local filesystem (for development)
repository("mylib-dev") {
    url: "/path/to/local/library";
}
```

### Reference in Targets

Use `@reponame//path:target` syntax:

```d
target("my-app") {
    type: executable;
    sources: ["main.cpp"];
    deps: [
        "@llvm//lib:Support",
        "@protobuf//src:protobuf",
        ":local-target"
    ];
}
```

### Supported Fields

- **`url`** (required): Download URL or filesystem path
- **`integrity`** (required for HTTP): BLAKE3/SHA256 hash (64 hex characters)
- **`gitCommit`**: Git commit SHA or tag (for Git repos)
- **`gitTag`**: Git tag name (alternative to gitCommit)
- **`stripPrefix`**: Strip directory prefix after extraction
- **`format`**: Archive format (auto-detected: tar.gz, zip, tar.xz, tar.bz2)
- **`patches`**: Map of patch name to content (future)

## Reference Format

External dependencies use `@` prefix:

- `@repo`: Reference to repository root
- `@repo//path:target`: Reference to specific target in repository
- `@repo//path/to/dir:target`: Nested path with target

Internal (workspace) dependencies use `//` prefix:

- `//path:target`: Absolute workspace reference
- `:target`: Relative reference (same package)

## Caching Strategy

### Content-Addressable Storage

Repositories are stored by content hash:

```
.builder-cache/
├── repositories/
│   ├── llvm/
│   │   └── abc123.../
│   │       ├── CMakeLists.txt
│   │       └── lib/
│   ├── protobuf/
│   │   └── def456.../
│   │       └── src/
│   └── metadata.bin
```

### Cache Key Generation

Cache keys derived from:
- Repository URL
- Integrity hash
- Git commit/tag
- All combined and hashed with SHA256

### Lazy Fetching

Repositories are fetched only when:
1. Not in cache
2. Referenced by a target being built
3. Explicitly requested

### Cache Invalidation

Cache entries invalidated when:
- Local path no longer exists
- Metadata is corrupt
- User explicitly clears cache: `bldr repo clean`

## Security Model

### Integrity Verification

Every HTTP download is cryptographically verified:

1. **Download**: Fetch archive to temporary location
2. **Verify**: Compute BLAKE3/SHA256 and compare with `integrity`
3. **Extract**: Only extract if verification succeeds
4. **Cache**: Store with content-addressable key

### Hermetic Builds

Repository rules enable hermetic builds:
- **Reproducible**: Same `integrity` hash → identical bits
- **Immutable**: Cached repositories never change
- **Verified**: Cryptographic guarantees against tampering
- **Sandboxed**: Repositories can't access network or filesystem

### Best Practices

1. **Always specify `integrity`** for HTTP repositories
2. **Pin Git commits** (not branches) for reproducibility
3. **Use HTTPS URLs** to prevent MITM attacks
4. **Verify hashes** from official sources before adding

## CLI Commands

```bash
# List cached repositories
builder repo list

# Show cache statistics
builder repo stats

# Clean specific repository
builder repo clean llvm

# Clean all cached repositories
builder repo clean --all

# Fetch repository without building
builder repo fetch llvm
```

## Performance Characteristics

### Time Complexity
- **Cache hit**: O(1) lookup
- **Cache miss**: O(download_time + extract_time)
- **Reference resolution**: O(1) after first fetch

### Space Complexity
- **Storage**: O(repository_size) per unique version
- **Deduplication**: Automatic via content-addressing
- **Metadata**: O(n) where n = number of cached repos

### Optimizations
- **Parallel downloads**: Multiple repositories fetched concurrently
- **Chunk transfer**: Large archives use chunked HTTP
- **SIMD hashing**: BLAKE3 accelerated with AVX2/NEON
- **Zero-copy extraction**: Direct archive → cache directory

## Advanced Features

### Strip Prefix

Many archives have a top-level directory:

```
llvm-17.0.1.tar.gz
└── llvm-17.0.1/
    ├── CMakeLists.txt
    └── lib/
```

Use `stripPrefix` to flatten:

```d
repository("llvm") {
    url: "https://.../llvm-17.0.1.tar.gz";
    integrity: "abc123...";
    stripPrefix: "llvm-17.0.1";  // Remove top level
}
// Result: @llvm//CMakeLists.txt (not @llvm//llvm-17.0.1/CMakeLists.txt)
```

### Local Development

Override remote repositories with local paths:

```d
repository("mylib") {
    url: "/Users/me/dev/mylib";  // Local development copy
}
```

No integrity check for local repositories (development only).

### Git Submodules Alternative

Repository rules replace Git submodules:

**Git Submodules Problems:**
- Mutable (branches change)
- Slow (clone entire history)
- No integrity verification
- Complex workflow

**Repository Rules Benefits:**
- Immutable (pinned commits/hashes)
- Fast (shallow clone or archive)
- Cryptographic verification
- Simple declarative syntax

## Integration Points

### Build Graph

Repositories integrated into dependency graph:

```
@llvm//lib:Support
    ↓
//src:my-app
    ↓
//lib:utils
```

### Incremental Compilation

Repository changes trigger rebuilds:
- File modification detection
- Dependency tracking
- Selective invalidation

### Distributed Builds

Repositories cached on workers:
- Content-addressable transfer
- Automatic synchronization
- Bandwidth optimization

### LSP Support

Full IDE integration:
- Autocomplete for `@repo//` references
- Go-to-definition across repositories
- Error diagnostics

## Comparison to Other Systems

### Bazel `http_archive`

Similar:
- HTTP download with integrity
- Content-addressable caching
- `@repo//` syntax

Differences:
- Builder uses BLAKE3 (faster than SHA256)
- Unified with Git and local repos
- Simpler DSL syntax

### Buck2 External Dependencies

Similar:
- Content-addressable storage
- Lazy fetching

Differences:
- Builder integrates with 26+ languages
- Process-based plugin architecture
- More flexible DSL

### Cargo Dependencies

Similar:
- Centralized package registry concept
- Version resolution

Differences:
- Builder is language-agnostic
- Manual hash specification (more secure)
- No central registry (decentralized)

## Future Enhancements

1. **Patch Support**: Apply patches after fetch
2. **Mirrors**: Fallback URLs for reliability
3. **Registry**: Optional package registry (like crates.io)
4. **Version Resolution**: Semantic versioning and constraints
5. **Workspace Overlays**: Override repository files
6. **Compressed Caching**: Compress cached repositories
7. **CDN Integration**: Use CDN for popular packages
8. **Build Files Generation**: Auto-generate build files for external deps

## Troubleshooting

### Repository Not Found

```
Error: Unknown repository: llvm
```

**Solution**: Add `repository("llvm") { ... }` declaration

### Integrity Verification Failed

```
Error: Integrity check failed
Expected: abc123...
Got:      def456...
```

**Solution**:
1. Verify hash from official source
2. Re-download archive
3. Compute hash: `bldr repo hash file.tar.gz`

### Archive Extraction Failed

```
Error: Failed to extract archive
```

**Solution**:
1. Check archive format is supported
2. Verify tar/unzip tools installed
3. Check disk space availability

### Cache Corruption

```
Warning: Invalid cache entry for llvm, removing...
```

**Solution**: Cache will automatically re-fetch. Or manually:
```bash
builder repo clean llvm
bldr build
```

## Implementation Notes

### Thread Safety

All repository operations are thread-safe:
- Cache metadata protected by mutex
- Atomic file operations
- No race conditions on concurrent fetches

### Error Handling

Comprehensive Result monad usage:
- Network errors: Automatic retry with backoff
- Verification errors: Immediate failure
- Cache errors: Graceful degradation

### Memory Management

Efficient memory usage:
- Streaming downloads (no full-file buffering)
- On-demand metadata loading
- Buffer pooling for serialization

## References

- [Builderfile DSL Specification](../docs/architecture/dsl.md)
- [Content-Addressable Storage](../docs/features/graphcache.md)
- [Hermetic Builds](../docs/features/hermetic.md)
- [BLAKE3 Hashing](../docs/features/blake3.md)

