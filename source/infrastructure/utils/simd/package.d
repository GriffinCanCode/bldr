module infrastructure.utils.simd;

/// SIMD Acceleration Package
/// Hardware-agnostic SIMD optimizations with runtime dispatch
/// 
/// Architecture:
///   detection.d    - CPU feature detection (AVX2/AVX-512/NEON/SSE)
///   dispatch.d     - Runtime dispatch to optimal BLAKE3 SIMD implementation
///   ops.d          - SIMD-accelerated memory operations
///   hash.d         - Specialized hash comparison operations
///   capabilities.d - SIMD service (eliminates global state)
///   context.d      - Context-aware SIMD operations
///   bench.d        - Comprehensive SIMD benchmarking suite
///   bloom.d        - SIMD-accelerated Bloom filter (betterC core)
///   strings.d      - SIMD-accelerated string comparison (AVX2/NEON)
///
/// Features:
///   - Runtime CPU detection (no compile-time only paths)
///   - Fallback chain: AVX-512 → AVX2 → SSE4.1 → SSE2 → Portable
///   - ARM support: NEON → Portable
///   - Context-based capabilities (no global state)
///   - Zero-copy dispatch through function pointers
///   - Constant-time comparisons for security
///   - Batch hash validation for performance
///
/// Performance Gains:
///   - BLAKE3: 2-4x faster on AVX2, 3-5x on AVX-512, 2-3x on NEON
///   - Memory Ops: 1.5-3x faster for large buffers
///   - Chunking: 3-8x faster with vectorized rolling hash
///   - Batch Hash Validation: 3-5x faster for multiple comparisons
///   - Bloom Filter: 2x throughput via SIMD vectorized probing
///     - AVX2: 4 hashes probed simultaneously
///     - AVX-512: 8 hashes probed simultaneously
///     - Cache lookup pre-filtering with doubled query throughput
///   - String Comparison: 4-8x faster for strings >= 32 bytes
///     - AVX2: 32 bytes compared per cycle
///     - AVX-512: 64 bytes compared per cycle
///     - NEON: 16 bytes compared per cycle
///     - Optimized for dependency resolution and path matching
///
/// Modern Usage (Context-Based - Recommended):
///   import infrastructure.utils.simd;
///   
///   // Initialize capabilities at startup (done by BuildServices)
///   auto caps = SIMDCapabilities.detect();
///   auto simdCtx = createSIMDContext(caps);
///   
///   // Use context for parallel operations
///   auto results = simdCtx.mapParallel(data, (x) => x * 2);
///   auto hashes = simdCtx.hashBatch(byteArrays);
///   
///   // Pass through BuildContext via IServiceContainer
///   BuildContext ctx;
///   ctx.services = services;  // IServiceContainer with SIMD
///   if (ctx.hasSIMD()) {
///       // SIMD-accelerated operations via ctx.simd
///   }
///
/// Legacy Usage (Global State - Deprecated):
///   import infrastructure.utils.simd;
///   
///   // CPU detection
///   CPU.printInfo();                      // Show CPU capabilities
///   
///   // SIMD memory operations
///   SIMDOps.copy(dest, src);              // Fast memcpy
///   SIMDOps.xor(result, a, b);            // Vectorized XOR
///   
///   // Specialized hash operations
///   SIMDHash.equals(hashA, hashB);        // Fast comparison
///   SIMDHash.constantTimeEquals(a, b);    // Timing-attack resistant

public import infrastructure.utils.simd.detection;
public import infrastructure.utils.simd.dispatch;
public import infrastructure.utils.simd.ops;
public import infrastructure.utils.simd.hash;
public import infrastructure.utils.simd.capabilities;
public import infrastructure.utils.simd.context;
public import infrastructure.utils.simd.bench;
public import infrastructure.utils.simd.bloom;
public import infrastructure.utils.simd.strings;

