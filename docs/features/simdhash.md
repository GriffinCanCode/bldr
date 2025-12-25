# SIMD Hash Comparison

## Overview

The `SIMDHash` module provides specialized hash comparison operations with SIMD acceleration and constant-time comparison for security-sensitive operations.

**Module**: `infrastructure.utils.simd.hash`

## API Reference

### Standard Comparison

```d
bool SIMDHash.equals(const(char)[] a, const(char)[] b, size_t threshold = 32)
```

Fast hash comparison using SIMD for hashes >= threshold bytes.

**Behavior**:
- Uses SIMD for hashes >= threshold (default 32 bytes)
- May short-circuit on first difference
- Falls back to scalar for short strings

**Use Case**: Cache validation, general-purpose integrity checks

```d
import infrastructure.utils.simd.hash;

immutable hash1 = "7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069";
immutable hash2 = "7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069";

if (SIMDHash.equals(hash1, hash2)) {
    writeln("Cache hit");
}
```

### Constant-Time Comparison

```d
bool SIMDHash.constantTimeEquals(const(char)[] a, const(char)[] b)
```

Timing-attack resistant comparison that processes all bytes regardless of differences.

**Security Properties**:
- Never short-circuits
- Execution time independent of difference location
- Uses SIMD but accumulates differences without branching

**Use Case**: Authentication tokens, HMAC validation, API keys

```d
import infrastructure.utils.simd.hash;

immutable userToken = getUserToken();
immutable validToken = getExpectedToken();

// SECURE: Timing attack resistant
if (SIMDHash.constantTimeEquals(userToken, validToken)) {
    authenticateUser();
}

// INSECURE: Vulnerable to timing attacks
// if (userToken == validToken) { ... }  // Don't do this
```

### Batch Comparison

```d
bool[] SIMDHash.batchEquals(const(string)[] hashesA, const(string)[] hashesB)
```

Compare multiple hash pairs in parallel.

**Behavior**:
- Sequential for < 8 pairs (avoids parallelization overhead)
- Parallel for >= 8 pairs using work-stealing scheduler

**Use Case**: Validating multiple cache entries, bulk integrity checks

```d
import infrastructure.utils.simd.hash;

string[] cachedHashes = cache.getAllSourceHashes("myTarget");
string[] currentHashes = files.map!(f => FastHash.hashFile(f)).array;

auto matches = SIMDHash.batchEquals(cachedHashes, currentHashes);

if (matches.all!(m => m == true)) {
    writeln("All files unchanged - use cached build");
}
```

### Prefix Matching

```d
bool SIMDHash.hasPrefix(const(char)[] hash, const(char)[] prefix)
size_t[] SIMDHash.findWithPrefix(const(string)[] hashes, const(char)[] prefix)
```

Check if hash starts with prefix, or find all hashes with a given prefix.

**Use Case**: Bloom filters, hash table lookups, sharding

```d
import infrastructure.utils.simd.hash;

// Single prefix check
immutable hash = "7f83b1657ff1fc53b92dc18148a1d65d...";
if (SIMDHash.hasPrefix(hash, "7f83")) {
    writeln("Hash starts with 7f83");
}

// Batch prefix search
string[] allHashes = cache.getAllHashes();
auto matches = SIMDHash.findWithPrefix(allHashes, "abc");
writeln("Found ", matches.length, " hashes with prefix 'abc'");
```

### Similarity Detection

```d
size_t SIMDHash.countMatches(const(char)[] a, const(char)[] b)
```

Count matching bytes between two hashes.

**Use Case**: Fuzzy matching, similarity detection, deduplication heuristics

```d
import infrastructure.utils.simd.hash;

immutable hash1 = "7f83b165...";
immutable hash2 = "7f83c165...";  // One byte different

auto similarity = SIMDHash.countMatches(hash1, hash2);
writeln("Hashes share ", similarity, " out of ", hash1.length, " bytes");
```

## When to Use Constant-Time

**Use constant-time for**:
- Authentication tokens
- HMAC/signature validation
- Password hash comparison
- API keys and secrets
- Session identifiers

**Use standard comparison for**:
- Build cache validation (not security-sensitive)
- File content hashes (public data)
- Dependency resolution
- General integrity checks

## Integration Example

### Build Cache

```d
import infrastructure.utils.simd.hash;

// Replace manual threshold logic with SIMDHash
if (!SIMDHash.equals(hashResult.contentHash, oldContentHash))
    return false;
```

### Security Validator

```d
import infrastructure.utils.simd.hash;

bool verifyHMAC(const(char)[] computed, const(char)[] expected)
{
    return SIMDHash.constantTimeEquals(computed, expected);
}
```

## Implementation Details

### Constant-Time Implementation

The C implementation uses XOR accumulation without branching:

```c
int simd_constant_time_equals(const void* s1, const void* s2, size_t n) {
    uint8_t diff = 0;
    
    #if defined(__AVX2__)
    if (n >= 32) {
        __m256i acc = _mm256_setzero_si256();
        for (i = 0; i + 32 <= n; i += 32) {
            __m256i v1 = _mm256_loadu_si256((__m256i*)(p1 + i));
            __m256i v2 = _mm256_loadu_si256((__m256i*)(p2 + i));
            __m256i xor = _mm256_xor_si256(v1, v2);
            acc = _mm256_or_si256(acc, xor);  // Never branches
        }
        // ... reduce accumulator ...
    }
    #endif
    
    // Portable fallback - processes all bytes
    for (size_t i = 0; i < n; i++) {
        diff |= p1[i] ^ p2[i];
    }
    
    return diff;
}
```

### Batch Parallelism

Batch operations use `ParallelExecutor.mapWorkStealing()` for load balancing:

```d
auto pairs = ParallelExecutor.mapWorkStealing(
    iota(n),
    (size_t i) => tuple(i, equals(hashesA[i], hashesB[i]))
);
```

## Testing

Test file: `tests/unit/utils/simd_hash.d`

```bash
dub test --filter="simd_hash"
```

## See Also

- [SIMD Acceleration](./simd.md) - Core SIMD infrastructure
- [Performance](./performance.md) - Build optimization guide
