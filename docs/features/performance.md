# Performance Optimizations

**Modules:**
- `infrastructure.utils.files.hash`
- `infrastructure.utils.files.glob`
- `infrastructure.utils.files.chunking`
- `infrastructure.utils.files.cdc`

## Overview

Builder implements several performance optimizations for file operations: size-tiered hashing, parallel file scanning, and content-defined chunking.

---

## Size-Tiered Hashing

**Module:** `infrastructure.utils.files.hash`

### Strategy

`FastHash.hashFile()` selects strategy based on file size:

| File Size | Strategy | Implementation |
|-----------|----------|----------------|
| ≤ 4 KB | Direct read | Single read, hash entire content |
| ≤ 1 MB | Chunked | Read in 4KB chunks, streaming hash |
| ≤ 100 MB | Sampled | Head + tail + middle samples |
| > 100 MB | Large sampled | Memory-mapped with aggressive sampling |

### Sampling Parameters

**Medium files (1-100 MB):**
```d
SAMPLE_HEAD = 262_144;   // 256 KB from start
SAMPLE_TAIL = 262_144;   // 256 KB from end
SAMPLE_COUNT = 8;        // Middle samples
SAMPLE_SIZE = 16_384;    // 16 KB per sample
```

**Large files (> 100 MB):**
```d
LARGE_HEAD_SIZE = 524_288;    // 512 KB from start
LARGE_TAIL_SIZE = 524_288;    // 512 KB from end
LARGE_SAMPLE_COUNT = 16;      // Middle samples
LARGE_SAMPLE_SIZE = 32_768;   // 32 KB per sample
```

### Usage

```d
import infrastructure.utils.files.hash;

// Automatic strategy selection
auto hash = FastHash.hashFile("large_file.bin");

// Full hash (no sampling) for security-critical use
auto fullHash = FastHash.hashFileComplete("file.bin");

// Two-tier checking (metadata first, content if needed)
auto result = FastHash.hashFileTwoTier("file.d", oldMetadataHash);
if (!result.contentHashed) {
    // Fast path: metadata unchanged
}

// Metadata-only hash
auto metaHash = FastHash.hashMetadata("file.d");  // mtime + size
```

### When to Use Full Hashing

Use `hashFileComplete()` for:
- Cryptographic verification
- Signature validation
- Tamper detection

Use `hashFile()` (sampled) for:
- Build cache invalidation
- Change detection
- Development workflows

---

## Parallel File Scanning

**Module:** `infrastructure.utils.files.glob`

### Implementation

`GlobMatcher` uses `std.parallelism` for directory traversal when matching `**` patterns:

1. Collect directories via BFS
2. Process directories in parallel
3. Thread-safe result merging via mutex

### Usage

```d
import infrastructure.utils.files.glob;

// Automatic parallel scanning for ** patterns
auto files = GlobMatcher.match(["**/*.d"], "./source");

// With exclusion tracking
auto result = GlobMatcher.matchWithExclusions(
    ["**/*.d", "!**/test/**"],
    "./source"
);
writeln("Matched: ", result.matches.length);
writeln("Excluded: ", result.excluded.length);
```

### Pattern Support

- `*` - Match any characters except `/`
- `**` - Match any path segments (triggers parallel scan)
- `?` - Match single character
- `!pattern` - Negation (exclusion)

---

## Content-Defined Chunking

**Modules:**
- `infrastructure.utils.files.chunking` - Rabin fingerprinting
- `infrastructure.utils.files.cdc` - FastCDC (Gear hash)

### Purpose

Split files at content-defined boundaries for:
- Incremental hashing (only rehash changed chunks)
- Deduplication
- Delta transfers

### Rabin Fingerprinting

**Module:** `infrastructure.utils.files.chunking`

```d
import infrastructure.utils.files.chunking;

// Chunk file
auto result = ContentChunker.chunkFile("large_file.bin");
writeln("Chunks: ", result.chunks.length);
writeln("Combined hash: ", result.combinedHash);

// Each chunk has offset, length, and hash
foreach (chunk; result.chunks)
    writefln("  %d-%d: %s", chunk.offset, chunk.length, chunk.hash);
```

**Parameters:**
```d
MIN_CHUNK = 2_048;   // 2 KB minimum
AVG_CHUNK = 16_384;  // 16 KB average  
MAX_CHUNK = 65_536;  // 64 KB maximum
```

### FastCDC (Gear Hash)

**Module:** `infrastructure.utils.files.cdc`

2-3x faster than Rabin fingerprinting:

```d
import infrastructure.utils.files.cdc;

// Configure for workload
auto chunker = FastCDC(FastCDC.Config.artifact());  // Build artifacts
// Or:
// FastCDC.Config.large()  - For 100MB+ files
// FastCDC.Config.small()  - Finer granularity

// Chunk file
auto result = chunker.chunkFile("large_file.bin");
writeln("Chunks: ", result.chunks.length);
```

**Configurations:**
```d
artifact() => Config(2048, 16384, 65536);   // 2KB-16KB-64KB
large()    => Config(8192, 65536, 262144);  // 8KB-64KB-256KB
small()    => Config(1024, 4096, 16384);    // 1KB-4KB-16KB
```

### Finding Changed Chunks

```d
auto oldResult = /* load from cache */;
auto newResult = chunker.chunkFile("file.bin");
auto changed = ContentChunker.findChangedChunks(oldResult, newResult);
writeln("Changed chunks: ", changed.length);
```

---

## Metadata Checking

### Three-Tier Strategy

```d
// Tier 1: Size check (~1 ns)
if (newSize != oldSize) return Changed;

// Tier 2: Metadata hash (size + mtime, ~10 ns)
if (FastHash.hashMetadata(path) != oldMetadataHash) {
    // Tier 3: Content hash (varies by size)
    return FastHash.hashFile(path) != oldContentHash;
}

return Unchanged;
```

### Usage

```d
// Two-tier check with FastHash
auto result = FastHash.hashFileTwoTier(path, oldMetadataHash);
if (result.metadataHash == oldMetadataHash) {
    // Fast path - no content hash needed
} else if (result.contentHash == oldContentHash) {
    // Metadata changed but content unchanged (e.g., touch)
} else {
    // Content actually changed
}
```

---

## Memory-Mapped I/O

Large files (> 100 MB) use memory mapping:

```d
auto mmfile = new MmFile(path, MmFile.Mode.read, 0, null);
scope(exit) destroy(mmfile);

auto data = cast(ubyte[])mmfile[];
// Direct access to file content via virtual memory
```

Benefits:
- Eliminates buffer copying
- Efficient random access
- Leverages OS page cache

Falls back to chunked reading if mmap fails.

---

## BLAKE3 Hashing

All hashing uses SIMD-accelerated BLAKE3:

```d
import infrastructure.utils.crypto.blake3;

auto hash = Blake3.hashHex(data);

// Streaming
auto hasher = Blake3(0);
hasher.put(chunk1);
hasher.put(chunk2);
auto result = hasher.finishHex();
```

BLAKE3 auto-selects optimal SIMD path: AVX-512, AVX2, NEON, or SSE.

---

## Configuration

### Hash Thresholds

In `infrastructure.utils.files.hash`:

```d
private enum size_t TINY_THRESHOLD = 4_096;           // 4 KB
private enum size_t SMALL_THRESHOLD = 1_048_576;      // 1 MB
private enum size_t MEDIUM_THRESHOLD = 104_857_600;   // 100 MB
```

### Chunking Parameters

In `infrastructure.utils.files.chunking`:

```d
private enum size_t MIN_CHUNK = 2_048;    // 2 KB
private enum size_t AVG_CHUNK = 16_384;   // 16 KB
private enum size_t MAX_CHUNK = 65_536;   // 64 KB
```

---

## Best Practices

### 1. Use Metadata First

```d
// Good: Check metadata before content
auto newMeta = FastHash.hashMetadata(path);
if (newMeta != oldMeta) {
    auto hash = FastHash.hashFile(path);
}

// Avoid: Always hashing content
auto hash = FastHash.hashFile(path);  // Slower
```

### 2. Batch Operations

```d
// Good: Hash multiple files with shared context
auto hashes = FastHash.hashFiles(paths, capabilities);

// Avoid: Sequential individual hashes
foreach (path; paths) {
    auto hash = FastHash.hashFile(path);
}
```

### 3. Cache Chunk Results

```d
// Store chunks for incremental updates
auto chunks = ContentChunker.chunkFile(path);
cache.store(path, serialize(chunks));

// Later: Only rehash changed chunks
auto oldChunks = deserialize(cache.get(path));
auto newChunks = ContentChunker.chunkFile(path);
auto changed = ContentChunker.findChangedChunks(oldChunks, newChunks);
```

### 4. Choose Right Chunking Config

```d
// Build artifacts (default)
FastCDC.Config.artifact()

// Large binaries, videos
FastCDC.Config.large()

// Source files, configs
FastCDC.Config.small()
```

---

## Limitations

### Sampled Hashing

Not suitable for:
- Cryptographic verification
- Security-critical checksums
- Malware detection

Changes in unsampled regions won't be detected (statistically rare).

### Content-Defined Chunking

- Initial chunking has overhead similar to full hash
- Storage overhead for chunk metadata
- Only beneficial for files that change frequently

---

## See Also

- [Incremental Analysis](incremental.md)
- [Caching Architecture](../architecture/cachedesign.md)
- [Persistent Workers](persistent-workers.md)
