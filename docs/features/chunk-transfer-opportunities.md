# Content-Defined Chunking Opportunities

## Overview

Content-defined chunking (CDC) breaks files into variable-sized chunks at content-determined boundaries using a rolling hash. This enables efficient incremental transfers where only changed chunks are transmitted.

## Current Implementation

### Core Module

Located in `source/infrastructure/utils/files/chunking.d`:

**ContentChunker** - Rabin fingerprint-based chunking:
- Rolling hash window: 64 bytes
- Minimum chunk: 2 KB
- Average chunk: 16 KB  
- Maximum chunk: 64 KB
- BLAKE3 hash per chunk

**ChunkManifest** - Tracks chunks for a file:
- File hash
- Chunk list (offset, length, hash)
- Total size
- Deduplication utilities

**ChunkTransfer** - Network transfer operations:
- `uploadChangedChunks()` - Incremental upload
- `downloadChunks()` - Download and reconstruct
- `uploadFileChunked()` - Initial chunked upload

**TransferStats** - Transfer metrics:
- Total/changed/transferred chunks
- Bytes transferred/saved
- Efficiency calculations

### Integration Points

**Implemented:**
1. **Distributed Cache** (`engine/caching/distributed/remote/client.d`)
   - `putFileChunked()` - Chunked uploads
   - `updateFileChunked()` - Incremental updates

2. **Artifact Manager** (`engine/runtime/remote/artifacts/manager.d`)
   - Large artifact uploads
   - Remote execution inputs

## Chunking Algorithm

```d
// Rabin fingerprint parameters
private enum ulong POLYNOMIAL = 0x3DA3358B4DC173;
private enum uint WINDOW_SIZE = 64;
private enum ulong MASK = (1UL << 14) - 1;  // ~16KB average

// Boundary detection
bool isBoundary = false;
if (chunkLen >= MIN_CHUNK)
{
    if ((fingerprint & MASK) == 0)
        isBoundary = true;
    if (chunkLen >= MAX_CHUNK)
        isBoundary = true;  // Force boundary
}
```

## Usage

### Basic Chunking

```d
import infrastructure.utils.files.chunking;

// Chunk a file
auto result = ContentChunker.chunkFile("large-file.bin");
writeln("Chunks: ", result.chunks.length);
writeln("Combined hash: ", result.combinedHash);

// Find changed chunks
auto changed = ContentChunker.findChangedChunks(oldChunks, newChunks);
```

### Incremental Upload

```d
import infrastructure.utils.files.chunking;

// Upload only changed chunks
auto stats = ChunkTransfer.uploadChangedChunks(
    filePath,
    localManifest,
    remoteManifest,
    (string chunkHash, const(ubyte)[] data) @trusted {
        return remoteStore.put(chunkHash, data);
    }
);

if (stats.isOk)
{
    auto s = stats.unwrap();
    writefln("Transferred %d/%d chunks", s.chunksTransferred, s.totalChunks);
    writefln("Saved %.1f%%", s.savingsPercent());
}
```

### Download and Reconstruct

```d
auto stats = ChunkTransfer.downloadChunks(
    outputPath,
    manifest,
    (string chunkHash) @trusted {
        return remoteStore.get(chunkHash);
    }
);
```

### Manifest Utilities

```d
ChunkManifest manifest;
manifest.fileHash = result.combinedHash;
manifest.chunks = result.chunks;
manifest.totalSize = fileSize;

// Find common chunks between manifests
auto common = manifest.findCommonChunks(other);

// Calculate deduplication savings
auto savings = manifest.calculateDedupSavings(other);
writefln("Potential savings: %d bytes", savings);
```

## Additional Integration Opportunities

The following areas could benefit from content-defined chunking:

### Graph Cache Storage

**Location**: `source/engine/graph/`

Large dependency graphs (1000+ targets) can reach 10+ MB. Small changes (adding one target) currently require re-uploading the entire graph.

**Potential benefit**: 80-95% bandwidth savings for incremental graph updates.

### Action Cache Sync

**Location**: `source/engine/caching/actions/`

Action cache can contain 50,000+ entries. Syncing across CI/CD workers wastes bandwidth when most actions are unchanged.

**Potential benefit**: 85-95% bandwidth savings for incremental sync.

### Parse Cache (AST Storage)

**Location**: `source/infrastructure/config/caching/`

Large Builderfile ASTs can reach 100KB-1MB. Remote sync of parse cache could benefit from chunking.

**Potential benefit**: 60-80% bandwidth savings.

### Test Fixtures

Test fixtures (10-100MB datasets) are re-downloaded for distributed test execution.

**Potential benefit**: 80-95% bandwidth savings when fixtures are shared.

## Transfer Statistics

```d
struct TransferStats
{
    size_t totalChunks;
    size_t changedChunks;
    size_t chunksTransferred;
    size_t bytesTransferred;
    size_t bytesSaved;
    
    double efficiency();      // 0.0 to 1.0
    double savingsPercent();  // Percentage saved
}
```

## Serialization

```d
// Serialize chunk result for caching
ubyte[] data = ContentChunker.serialize(result);

// Deserialize
auto restored = ContentChunker.deserialize(data);
```

Binary format:
```
[uint32: chunk_count]
[uint32: combined_hash_len][combined_hash]
For each chunk:
  [uint64: offset]
  [uint64: length]
  [uint32: hash_len][hash]
```

## Performance Characteristics

| Metric | Value |
|--------|-------|
| Average chunk size | 16 KB |
| Min chunk size | 2 KB |
| Max chunk size | 64 KB |
| Hash algorithm | BLAKE3 |
| Window size | 64 bytes |

Typical savings for incremental updates:
- Small changes: 90-95% bandwidth saved
- Medium changes: 70-85% bandwidth saved
- Large changes: 50-70% bandwidth saved

## Related

- [Chunk Transfer](chunk-transfer.md) - Detailed transfer protocol
- [Remote Cache](remotecache.md) - Distributed caching
- [BLAKE3](blake3.md) - Hash algorithm used
