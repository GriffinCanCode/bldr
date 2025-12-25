# SIMD Acceleration

## Overview

Builder uses SIMD (Single Instruction, Multiple Data) acceleration for hashing and memory operations. The system detects CPU capabilities at runtime and dispatches to the optimal implementation.

## Architecture

### Runtime Dispatch

```
CPU Detection → Feature Analysis → Implementation Selection → Execution
     ↓               ↓                      ↓                    ↓
  CPUID/hwcap   AVX512/AVX2/NEON    Function Pointers      SIMD Code
```

### Fallback Chain

```
x86/x64:  AVX-512 → AVX2 → SSE4.1 → SSE2 → Portable
ARM:      NEON → Portable
```

### Module Structure

```
source/infrastructure/utils/simd/
├── c/                      # C implementations with SIMD intrinsics
│   ├── cpu_detect.c/h      # Runtime CPU feature detection
│   ├── blake3_dispatch.c   # BLAKE3 SIMD dispatcher
│   ├── blake3_avx2.c       # AVX2 implementation
│   ├── blake3_avx512.c     # AVX-512 implementation
│   ├── blake3_sse2.c       # SSE2 baseline
│   ├── blake3_sse41.c      # SSE4.1 optimized
│   ├── blake3_neon.c       # ARM NEON
│   ├── simd_ops.c/h        # Memory operations (memcpy/memcmp/xor)
│   └── Makefile            # Per-file compilation with arch flags
├── detection.d             # D bindings for CPU detection
├── dispatch.d              # D bindings for BLAKE3 dispatch
├── ops.d                   # D bindings for SIMD operations
├── hash.d                  # Specialized hash comparison operations
├── capabilities.d          # SIMD service (context-based, no global state)
├── context.d               # Context-aware SIMD operations
├── bloom.d                 # SIMD-accelerated Bloom filter
├── bench.d                 # Benchmarking suite
└── package.d               # Public API exports
```

## Performance

### BLAKE3 Hashing

| CPU Feature | Approx Throughput | Relative | Notes |
|------------|-------------------|----------|-------|
| Portable | ~600 MB/s | 1.0x | Fallback |
| SSE2 | ~900 MB/s | 1.5x | x86_64 baseline |
| SSE4.1 | ~1.2 GB/s | 2.0x | 2007+ CPUs |
| AVX2 | ~2.4 GB/s | 4.0x | 2013+ Intel/AMD |
| AVX-512 | ~3.6 GB/s | 6.0x | Skylake-X+, EPYC |
| NEON | ~1.8 GB/s | 3.0x | ARM64/Apple Silicon |

### Memory Operations

| Operation | SIMD Threshold | Typical Speedup |
|-----------|----------------|-----------------|
| memcpy | 256 bytes | 1.5-2.5x |
| memcmp | 64 bytes | 2-3x |
| memset | 128 bytes | 2-3x |
| XOR | 32 bytes | 2-4x |

Below thresholds, scalar implementations are used to avoid overhead.

## API Usage

### Context-Based (Recommended)

```d
import infrastructure.utils.simd;

// Initialize capabilities at startup (done automatically by BuildServices)
auto caps = SIMDCapabilities.detect();
auto simdCtx = createSIMDContext(caps);

// Use context for operations
auto results = simdCtx.mapParallel(data, (x) => x * 2);
```

### CPU Detection

```d
import infrastructure.utils.simd.detection;

// Print CPU capabilities
CPU.printInfo();

// Query features
if (CPU.hasFeature(CPUFeature.AVX2)) {
    writeln("AVX2 available");
}

// Get active SIMD level
writeln("Using: ", CPU.simdLevelName());
// Output: "AVX2" or "NEON" or "SSE4.1" etc.
```

### Direct Operations

```d
import infrastructure.utils.simd.ops;

// Memory operations (SIMD when beneficial)
SIMDOps.copy(dest, src);
SIMDOps.equals(a, b);
SIMDOps.xor(result, a, b);

// Rolling hash for content chunking
auto hash = SIMDOps.rollingHash(data, windowSize);
```

### Benchmarking

```d
import infrastructure.utils.simd.bench;

// Run comprehensive SIMD benchmarks
SIMDBench.compareAll();

// Individual benchmarks
SIMDBench.benchmarkBlake3Compression();
SIMDBench.benchmarkMemoryOps();
SIMDBench.benchmarkHashThroughput();
SIMDBench.benchmarkBloomFilter();
SIMDBench.benchmarkRealWorld();
```

## Integration Points

### File Hashing (`infrastructure.utils.files.hash`)
- BLAKE3 hashing with automatic SIMD dispatch
- Memory-mapped file access with SIMD sampling

### Content Chunking (`infrastructure.utils.files.chunking`)
- SIMD-accelerated rolling hash (Rabin fingerprint)
- BLAKE3 for chunk hashing

### Build Cache (`engine.caching`)
- SIMD hash comparisons via `SIMDHash` module
- Fast cache validation

### Bloom Filter (`infrastructure.utils.simd.bloom`)
- SIMD-accelerated batch membership testing
- Used for cache prefiltering

## Compilation

### DUB Build

```bash
# Standard build (SIMD C code compiles automatically)
dub build

# Release build with optimizations
dub build --build=release
```

### Manual C Compilation

```bash
cd source/infrastructure/utils/simd/c

# Standard build
make

# Optimized for current CPU
make optimized

# Debug build
make debug

# Clean
make clean
```

## Hardware Support

### x86/x64 CPUs

| Feature | Year | CPUs | Status |
|---------|------|------|--------|
| SSE2 | 2001 | All x86_64 | ✅ Baseline |
| SSE4.1 | 2007 | Core 2+ | ✅ Supported |
| AVX2 | 2013 | Haswell+ | ✅ Supported |
| AVX-512 | 2017 | Skylake-X+ | ✅ Supported |

### ARM CPUs

| Feature | Architecture | CPUs | Status |
|---------|--------------|------|--------|
| NEON | ARMv7+ | Cortex-A8+ | ✅ Supported |
| ASIMD | ARMv8+ | All ARM64 | ✅ Supported |

### Tested Platforms

- Intel Core i5/i7/i9 (Haswell through current)
- AMD Ryzen (all generations)
- Apple M1/M2/M3
- AWS Graviton (ARM64)
- Raspberry Pi 4 (ARM Cortex-A72)

## Technical Details

### CPU Detection

**x86/x64**: Uses `CPUID` instruction to query vendor string, feature flags (SSE*/AVX*/AVX-512), and cache sizes.

**ARM**: Uses platform-specific methods:
- Linux: `getauxval(AT_HWCAP)` for feature bits
- macOS: `sysctlbyname()` for capabilities
- ARM64: NEON always available

### BLAKE3 Parallelism

| Implementation | Lanes | Parallel Blocks |
|----------------|-------|-----------------|
| Portable | 1 | 1 |
| AVX2 | 8x 32-bit | 8 |
| AVX-512 | 16x 32-bit | 16 |
| NEON | 4x 32-bit | 4 |

## Troubleshooting

### Build Issues

**Problem**: `blake3_hasher_init undefined reference`

**Solution**: Ensure C source files are compiled. Check `dub.json` includes all SIMD C files in `sourceFiles`.

**Problem**: AVX2 instructions on old CPU

**Solution**: Runtime dispatch handles this automatically. Old CPUs fall back to SSE2 or portable.

### Performance Issues

**Problem**: No speedup observed

**Checklist**:
1. Built with optimizations? (`dub build --build=release`)
2. SIMD actually active? (Check `CPU.simdLevelName()`)
3. Files large enough? (Benefit increases with size)
4. Check `CPU.printInfo()` for detected features

**Problem**: Slower than expected

**Possible causes**:
- Thermal throttling on laptop CPUs
- Background processes
- Memory bandwidth saturation
- Small file sizes (overhead dominant)

## See Also

- [Performance](./performance.md) - Build optimization guide
- [SIMD Hash Comparison](./simdhash.md) - Specialized hash operations
- [BLAKE3](./blake3.md) - Hash function details
