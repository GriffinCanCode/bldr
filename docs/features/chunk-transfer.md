# Content-Defined Chunking for Network Transfer

**Status:** Implemented  
**Module:** `infrastructure.utils.files.cdc`, `engine.caching.storage.chunked`

## Overview

Content-defined chunking enables efficient network transfers for large build artifacts by splitting files at content-dependent boundaries. Only changed chunks are transferred, reducing bandwidth for incremental changes.

Builder uses **FastCDC** (gear-based rolling hash) for chunking, which is 2-3x faster than Rabin fingerprinting while achieving comparable deduplication ratios.

### SIMD Acceleration

FastCDC includes **SIMD-accelerated gear hash** for additional 2-3x speedup:

| Implementation | Speedup | Notes |
|---------------|---------|-------|
| AVX-512 | 2.5-3x | 8-way unrolled loop |
| AVX2 | 2-2.5x | 4-way parallel lookups |
| NEON | 1.5-2x | ARM64 vectorization |
| Portable | Baseline | Tight scalar loop |

SIMD is enabled by default and automatically dispatched at runtime based on CPU capabilities.

## Architecture

### FastCDC Algorithm

The chunking system uses gear-based rolling hash for fast boundary detection:

```d
// Fingerprint update: fp = (fp << 1) + gear[byte]
// Gear table: 256 pseudo-random 64-bit values (deterministic PRNG)

// Chunk size configurations
struct Config {
    size_t minSize;   // Minimum chunk size
    size_t avgSize;   // Target average chunk size
    size_t maxSize;   // Maximum chunk size
    
    // Presets:
    static Config artifact() => Config(2048, 16384, 65536);   // 2KB-16KB-64KB
    static Config large() => Config(8192, 65536, 262144);     // 8KB-64KB-256KB
    static Config small() => Config(1024, 4096, 16384);       // 1KB-4KB-16KB
}
```

### Normalized Chunking

FastCDC uses normalized chunking with two-phase boundary detection for more consistent chunk sizes:

1. **Phase 1** (minSize → avgSize): Stricter mask - fewer boundaries
2. **Phase 2** (avgSize → maxSize): Relaxed mask - more boundaries
3. **Phase 3**: Force boundary at maxSize

### Content-Defined Boundaries

Content-defined boundaries shift naturally with content changes, unlike fixed-size chunks:

```
File: ABCDEFGHIJKLMNOPQRSTUVWXYZ
Chunks: ABC|DEFGH|IJKLM|NOPQR|STUVWXYZ

After inserting "123" at position 5:
File: ABCDE123FGHIJKLMNOPQRSTUVWXYZ
Chunks: ABC|DE123FGH|IJKLM|NOPQR|STUVWXYZ

Only one chunk changed (DE123FGH)
```

## Components

### 1. FastCDC Engine (`infrastructure/utils/files/cdc.d`)

High-performance chunking for build artifacts:

```d
import infrastructure.utils.files.cdc;

auto cdc = FastCDC(FastCDC.Config.large());  // 8KB-64KB-256KB
auto result = cdc.chunkFile("output/app.exe");

// Result contains:
// - chunks: Array of Chunk (offset, length, hash)
// - totalSize: Original file size
// - combinedHash: BLAKE3 hash of all chunk hashes
```

**Chunk Structure:**
```d
struct Chunk {
    size_t offset;     // Byte offset in source
    size_t length;     // Chunk length
    ubyte[32] hash;    // BLAKE3 256-bit hash
}
```

### 2. ChunkedCAS (`engine/caching/storage/chunked.d`)

Content-addressable storage with automatic chunking for large blobs:

```d
import engine.caching.storage.chunked;

auto store = new ChunkedCAS(".builder-cache");

// Store - automatically chunks large data (>100MB)
auto hash = store.put(largeBinaryData).unwrap();

// Get manifest for delta transfer
auto manifest = store.getManifest(hash).unwrap();

// Find missing chunks (for upload)
auto missing = store.findMissingChunks(manifest.refs.map!(r => r.hash).array);

// Retrieve (automatically reassembles)
auto data = store.get(hash).unwrap();
```

**Storage Layout:**
```
.builder-cache/
├── blobs/      # Small blobs (whole-file storage)
├── chunks/     # Individual chunk storage (sharded by first 2 hex chars)
└── manifests/  # Chunk manifests for chunked blobs
```

### 3. Chunk Manifest

Stores metadata about chunked blobs without chunk contents:

```d
struct ChunkManifest {
    ubyte[32] blobHash;    // Original blob hash
    ubyte[32] rootHash;    // Merkle root of chunks
    size_t totalSize;      // Original size
    size_t chunkCount;     // Number of chunks
    ChunkRef[] refs;       // Chunk references (offset, length, hash)
}
```

### 4. Content Chunker (`infrastructure/utils/files/chunking.d`)

Original Rabin-based chunking (for smaller files):

```d
import infrastructure.utils.files.chunking;

auto result = ContentChunker.chunkFile("binary.o");

foreach (chunk; result.chunks) {
    writeln("Offset: ", chunk.offset,
            " Length: ", chunk.length,
            " Hash: ", chunk.hash);
}
```

**Rabin Parameters:**
```d
enum ulong POLYNOMIAL = 0x3DA3358B4DC173;
enum uint WINDOW_SIZE = 64;
enum size_t MIN_CHUNK = 2_048;   // 2 KB
enum size_t AVG_CHUNK = 16_384;  // 16 KB
enum size_t MAX_CHUNK = 65_536;  // 64 KB
```

## Use Cases

### Artifact Store Uploads

Large binary artifacts with incremental changes:

```d
// First upload: full file
auto upload1 = store.put(appBinary);  // Uploads 100 MB

// After small code change
auto upload2 = store.put(updatedAppBinary);  // Uploads ~5 MB (changed chunks only)
```

### Distributed Cache Transfers

CI/CD pipelines sharing cache across machines:

```d
// Machine A: Build and upload
auto hash = store.put(buildOutput).unwrap();

// Machine B: Download (finds missing chunks)
auto manifest = remoteStore.getManifest(hash).unwrap();
auto missing = localStore.findMissingChunks(manifest.refs.map!(r => r.hash).array);
// Only download missing chunks
```

## Performance

### Benchmark: Large Binary (150 MB with FastCDC)

| Scenario | Without CDC | With CDC | Bandwidth Saved |
|----------|-------------|----------|-----------------|
| Initial upload | 150 MB | 150 MB | 0% (baseline) |
| 1% code change | 150 MB | 3 MB | 98% |
| 5% code change | 150 MB | 10 MB | 93% |
| 10% code change | 150 MB | 18 MB | 88% |

### Chunking Throughput

- **FastCDC (SIMD)**: ~1.2-1.5 GB/s (AVX2 gear hash + BLAKE3)
- **FastCDC (scalar)**: ~500 MB/s (gear hash + BLAKE3)
- **Rabin**: ~200 MB/s

### Overhead

- **150 MB file**: ~300ms chunking time
- **Manifest storage**: ~50 KB per 150MB file
- **Chunk lookup**: O(1) hash table

### Threshold Selection

- Files < 1 MB: Regular transfer (chunking overhead not worth it)
- Files ≥ 1 MB: Chunking provides savings

## Implementation Details

### BLAKE3 Chunk Hashing

Each chunk is hashed with BLAKE3 for integrity and deduplication:

```d
auto hasher = Blake3(0);
hasher.put(chunkData);
auto hash = hasher.finish(32)[0 .. 32];  // 256-bit hash
```

### Chunk Verification

Downloaded chunks are verified:

```d
auto hasher = Blake3(0);
hasher.put(chunkData);
auto actualHash = hasher.finish(32)[0 .. 32];

if (actualHash != expectedHash)
    return Err("Chunk hash mismatch");
```

### Sharded Storage

Chunks are stored in sharded directories for filesystem performance:

```
chunks/
├── ab/
│   └── abc123...  # Full hash as filename
├── cd/
│   └── cde456...
└── ef/
    └── efg789...
```

## Statistics

The `ChunkedCAS` tracks deduplication statistics:

```d
struct ChunkStats {
    size_t chunkedBlobs;       // Large blobs stored as chunks
    size_t totalChunks;        // Total chunks created
    size_t chunksStored;       // Unique chunks stored
    size_t chunkBytesStored;   // Bytes in chunk storage
    size_t chunkHits;          // Chunk dedup hits
    size_t manifestsStored;    // Manifests created
    size_t blobHits;           // Full blob dedup hits
    
    double dedupRatio() => totalChunks > 0 ? 100.0 * chunkHits / totalChunks : 0.0;
}

auto stats = store.getStats();
writeln("Deduplication ratio: ", stats.dedupRatio(), "%");
```

## Limitations

### Not Optimal For

1. **Small files (< 1 MB)**: Overhead exceeds savings
2. **Completely new files**: No chunks to deduplicate
3. **Random binary changes**: Encrypted files, random data

### Edge Cases

**Adversarial Input:**
Random bytes with no patterns cause all boundaries to shift. The system falls back to regular transfer when savings are minimal.

**Chunk Boundary Shift:**
Insertions near file start can cascade boundary shifts. However, boundaries stabilize after the rolling window (64 bytes for Rabin, variable for FastCDC).

## Configuration

### Chunk Size Tuning

```d
// For large binaries (>100MB)
auto cdc = FastCDC(FastCDC.Config.large());  // 8KB-64KB-256KB

// For standard artifacts
auto cdc = FastCDC(FastCDC.Config.artifact());  // 2KB-16KB-64KB

// For fine-grained deduplication
auto cdc = FastCDC(FastCDC.Config.small());  // 1KB-4KB-16KB
```

### SIMD Control

```d
// Enable SIMD acceleration (default)
auto cdc = FastCDC.create(true);
assert(cdc.isSIMDEnabled());

// Disable SIMD (for benchmarking/testing)
auto cdcScalar = FastCDC.create(false);

// Check SIMD implementation
writeln("Using: ", FastCDC.simdImplName());  // "AVX2", "NEON", etc.

// Direct SIMD gear hash API
import infrastructure.utils.simd.gear : SIMDGear;

auto gear = SIMDGear.create(SIMDGear.Preset.artifact);
auto boundary = gear.findBoundary(data, remaining);
```

**Trade-offs:**
- **Smaller chunks**: More deduplication, more manifest overhead
- **Larger chunks**: Less deduplication, less overhead

## Delta Transfer Protocol

For large artifact transfers, Builder includes a full delta transfer protocol (`engine.caching.distributed.remote.delta`):

### DeltaTransfer Class

Enables 80-95% bandwidth savings for large artifact transfers:

```d
import engine.caching.distributed.remote.delta;

auto delta = new DeltaTransfer(transport, localStore);

// Upload with delta (only new chunks)
auto result = delta.upload(hash, data);
if (result.isOk) {
    auto stats = result.unwrap();
    writeln("Transferred: ", stats.bytesTransferred);
    writeln("Saved: ", stats.savingsPercent(), "%");
}

// Download with delta (reuses local chunks)
auto downloaded = delta.download(remoteHash);
```

**Protocol Flow:**
1. Client sends manifest hash to server
2. Server responds with list of missing chunks
3. Client uploads only missing chunks
4. Server stores manifest linking to chunks

### RsyncDelta

Rsync-style delta compression for binary diffs:

```d
auto rsync = new RsyncDelta(4096);  // 4KB block size

// Generate signatures from base data (server-side)
auto sigs = rsync.generateSignatures(oldData);

// Compute delta instructions (client-side)
auto delta = rsync.computeDelta(newData, sigs);

// Apply delta to reconstruct (server-side)
auto newData = rsync.applyDelta(oldData, delta);
```

### Transfer Statistics

```d
struct TransferResult {
    string blobHash;
    size_t totalSize;
    size_t bytesTransferred;
    size_t bytesSaved;
    size_t chunksTotal;
    size_t chunksTransferred;
    Duration duration;
    
    double savingsPercent();   // (totalSize - bytesTransferred) / totalSize
    double efficiency();       // (chunksTotal - chunksTransferred) / chunksTotal
    double throughput();       // bytes/sec
}
```

## See Also

- [Remote Caching](./remotecache.md)
- [CAS Design](../architecture/cachedesign.md)
- [Distributed Builds](./distributed.md)
- [Action Caching](./caching.md)

## References

- [FastCDC Paper (USENIX ATC '16)](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia)
- [Rabin Fingerprinting](https://en.wikipedia.org/wiki/Rabin_fingerprint)
- [rsync Algorithm](https://rsync.samba.org/tech_report/)
