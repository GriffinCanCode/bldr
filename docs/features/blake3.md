# BLAKE3 Hashing

## Overview

Builder uses BLAKE3 for all hashing operations. BLAKE3 is a cryptographic hash function that is:

- **Fast**: Optimized for modern CPUs with SIMD support
- **Parallel**: Designed for parallel execution
- **Secure**: 128-bit collision resistance
- **Versatile**: Supports keyed hashing, key derivation, and arbitrary output lengths

## Architecture

### Module Structure

```
source/infrastructure/utils/crypto/
├── blake3_bindings.d      # Low-level C bindings (extern C)
├── blake3.d               # High-level D wrapper API
├── package.d              # Public API exports
└── c/
    ├── blake3.h           # C header
    ├── blake3_impl.h      # Internal implementation
    ├── blake3.c           # C implementation
    └── Makefile

source/infrastructure/utils/simd/c/
├── blake3_avx2.c          # AVX2 acceleration
├── blake3_avx512.c        # AVX-512 acceleration
├── blake3_sse2.c          # SSE2 acceleration
├── blake3_sse41.c         # SSE4.1 acceleration
├── blake3_neon.c          # ARM NEON acceleration
└── blake3_dispatch.c      # SIMD detection and dispatch
```

### Integration Points

BLAKE3 is used throughout the build system:

1. **File Hashing** (`infrastructure/utils/files/hash.d`) - FastHash API
2. **Cache Keys** (`engine/caching/`) - Build cache validation
3. **Action Caching** (`engine/caching/actions/`) - Action result hashing
4. **Chunk Hashing** (`infrastructure/utils/files/chunking.d`) - Content-defined chunking

## Building

**BLAKE3 is self-contained.** The C source code is included and compiles automatically:

```bash
# Build Builder (automatically compiles BLAKE3)
dub build

# Optimized build
dub build --build=release
```

No external dependencies required.

## API Usage

### High-Level API (Blake3 struct)

```d
import infrastructure.utils.crypto.blake3;

// One-shot hash of string
auto hash = Blake3.hashHex("hello world");
// Returns: 64-character hex string (32 bytes)

// One-shot hash of binary data
ubyte[] data = [1, 2, 3, 4, 5];
auto binaryHash = Blake3.hashHex(data);

// Incremental hashing
auto hasher = Blake3(0);
hasher.put("hello ");
hasher.put("world");
auto result = hasher.finishHex();

// Custom output length
auto hash16 = Blake3.hashHex("test", 16);  // 16 bytes = 32 hex chars
```

### Keyed Hashing (MAC)

```d
// Create a 32-byte key
ubyte[32] key = /* your secret key */;

// Hash with key
auto hasher = Blake3.keyed(key);
hasher.put("message to authenticate");
auto mac = hasher.finishHex();
```

### Key Derivation

```d
// Derive key from context
auto kdf = Blake3.deriveKey("application-specific-context");
kdf.put("master-secret");
auto derivedKey = kdf.finish(32);  // 32-byte derived key
```

### FastHash API

The `FastHash` struct provides file hashing with size-tiered strategies:

```d
import infrastructure.utils.files.hash;

// Hash a file (uses appropriate strategy based on size)
auto fileHash = FastHash.hashFile("large-file.bin");

// Hash a string
auto strHash = FastHash.hashString("content");

// Hash multiple files
auto combinedHash = FastHash.hashFiles(["file1.d", "file2.d"]);

// Async batch hashing (io_uring on Linux)
string[] hashes = FastHash.hashFilesAsync(paths);

// Two-tier hashing (metadata check before content hash)
auto result = FastHash.hashFileTwoTier("file.d", oldMetadataHash);
if (!result.contentHashed) {
    // File unchanged, no content hash needed
}

// Metadata hash (size + mtime)
auto metaHash = FastHash.hashMetadata("file.d");
```

### Size-Tiered Strategy

FastHash selects hashing strategy based on file size:

| Size | Strategy | Description |
|------|----------|-------------|
| ≤4 KB | Direct | Read entire file |
| ≤1 MB | Chunked | Stream in 4 KB chunks |
| ≤100 MB | Sampled | Head + tail + middle samples |
| >100 MB | Large Sampled | Memory-mapped with aggressive sampling |

**Note**: Sampled hashing is not suitable for cryptographic integrity validation. Use `hashFileComplete()` for security-critical use cases.

### Reset and Reuse

```d
auto hasher = Blake3(0);

// Hash first data
hasher.put("data1");
auto hash1 = hasher.finishHex();

// Reset for new hash
hasher.reset();
hasher.put("data2");
auto hash2 = hasher.finishHex();
```

## Hex Conversion Utilities

```d
// Byte array to hex string
string hex = toHexString(bytes);  // Lowercase

// Hex string to byte array
auto result = fromHexString(hex);
if (result.isOk)
    auto bytes = result.unwrap();
else
    writeln("Error: ", result.unwrapErr());
```

## Cache Invalidation

Switching hash algorithms invalidates existing build caches. BLAKE3 produces different hash values than SHA-256. On first build after migration:

```bash
bldr build
# Cache migrated automatically
```

## Security Considerations

### Collision Resistance

- **Security Level**: 128-bit collision resistance
- **Preimage Resistance**: 256-bit
- **Use Case**: Suitable for build systems, caching, file integrity

### Appropriate Uses

✅ **Good for**:
- Build systems and caching
- File integrity checks
- Content-addressed storage
- Checksums and validation
- Key derivation
- Message authentication (with key)

❌ **Not suitable for**:
- Password hashing (use Argon2)
- FIPS 140-2 compliance requirements

## Troubleshooting

### Build Errors

**Problem**: `blake3_hasher_init undefined reference`

**Solution**: Verify `dub.json` includes the C source files:
```json
"sourceFiles": ["source/infrastructure/utils/crypto/c/blake3.c"]
```

**Problem**: C compilation errors

**Solution**: Ensure you have a C compiler:
```bash
# macOS
xcode-select --install

# Ubuntu/Debian
sudo apt install build-essential
```

### Runtime Errors

**Problem**: Segfault in hash operations

**Solution**: Ensure proper initialization:
```d
auto hasher = Blake3(0);  // Required initialization
hasher.put(data);
```

## Related

- [Async I/O](async-io.md) - Batch file hashing
- [Caching](caching.md) - How hashes enable caching
- [SIMD Acceleration](simd.md) - CPU acceleration
