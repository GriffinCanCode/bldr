module infrastructure.utils.simd.context;

import infrastructure.utils.simd.capabilities;
import infrastructure.utils.simd.ops;
import infrastructure.utils.simd.bloom;
import infrastructure.errors : Errors, Internal;
import std.range;
import std.algorithm;

/// Context-aware SIMD operations wrapper
/// Provides SIMD operations that accept capabilities context
/// Replaces global-state-based operations with context passing
struct SIMDContext
{
    private SIMDCapabilities caps;
    
    /// Create context with SIMD capabilities
    this(SIMDCapabilities caps) pure nothrow @nogc
    {
        this.caps = caps;
    }
    
    /// Check if SIMD is available
    bool available() const pure nothrow
    {
        return caps !is null && caps.active;
    }
    
    /// Get SIMD level
    auto level() const
    {
        import infrastructure.utils.simd.detection : SIMDLevel;
        return caps !is null ? caps.level : SIMDLevel.None;
    }
    
    /// Parallel map with SIMD acceleration
    /// Uses capabilities context instead of global thread pool
    auto mapParallel(T, F)(T[] items, F func) @system
    {
        import std.traits : ReturnType;
        
        alias R = ReturnType!F;
        
        if (items.empty)
            return (R[]).init;
        
        if (items.length == 1)
            return [func(items[0])];
        
        // Use capabilities' thread pool if available
        if (caps !is null)
            return caps.parallelMap(items, func);
        
        // Fallback: sequential execution
        R[] results;
        results.reserve(items.length);
        foreach (item; items)
            results ~= func(item);
        return results;
    }
    
    /// Batch hash multiple byte arrays in parallel
    /// Context-aware version of SIMDParallel.hashBatch
    string[] hashBatch(const(ubyte[])[] inputs) @system
    {
        import infrastructure.utils.crypto.blake3;
        
        return mapParallel(
            cast(ubyte[][])inputs,
            (ubyte[] input) => Blake3.hashHex(cast(const(ubyte)[])input)
        );
    }
    
    /// Parallel XOR of multiple byte arrays
    /// Context-aware version of SIMDParallel.xorBatch
    ubyte[][] xorBatch(const(ubyte[])[] array1, const(ubyte[])[] array2) @system
    {
        import std.algorithm : min;
        import std.range : iota, array;
        
        if (array1.length != array2.length)
            throw Errors.internal("Arrays must have same length for batch XOR", Internal.AssertionFailed).build();
        
        return mapParallel(
            iota(array1.length).array,
            (size_t i) {
                auto len = min(array1[i].length, array2[i].length);
                auto result = new ubyte[len];
                SIMDOps.xor(result, array1[i][0..len], array2[i][0..len]);
                return result;
            }
        );
    }
    
    /// Parallel comparison of byte arrays
    /// Context-aware version of SIMDParallel.findDifferences
    size_t[] findDifferences(const(ubyte[])[] baseline, const(ubyte[])[] current) @system
    {
        import std.algorithm : min, max;
        import std.range : iota, array;
        
        if (baseline.length != current.length)
            return iota(min(baseline.length, current.length), 
                       max(baseline.length, current.length)).array;
        
        size_t[] differences;
        
        // Check each pair in parallel
        auto results = mapParallel(
            iota(baseline.length).array,
            (size_t i) {
                return SIMDOps.equals(
                    cast(void[])baseline[i],
                    cast(void[])current[i]
                ) ? -1 : cast(long)i;
            }
        );
        
        // Collect indices that differ
        foreach (idx; results)
        {
            if (idx >= 0)
                differences ~= cast(size_t)idx;
        }
        
        return differences;
    }
    
    /// Create Bloom filter optimized for SIMD batch operations
    /// Uses capabilities to determine optimal parameters
    BloomFilter createBloomFilter(size_t expectedItems, double errorRate = 0.01) @system
    {
        return BloomFilter.create(expectedItems, errorRate);
    }
    
    /// Batch Bloom filter lookup with SIMD acceleration
    /// Returns count of potential matches
    size_t bloomBatchLookup(ref const BloomFilter filter, scope const(ulong)[] hashes) @system
    {
        return filter.countMatches(hashes);
    }
}

/// Create SIMD context from capabilities
SIMDContext createSIMDContext(SIMDCapabilities caps) pure nothrow @nogc
{
    return SIMDContext(caps);
}

// Unit tests
unittest
{
    import std.stdio : writeln;
    
    // Test with real capabilities
    auto caps = SIMDCapabilities.detect(2);
    auto ctx = createSIMDContext(caps);
    
    assert(ctx.available() || !caps.active);
    
    // Test parallel map
    auto data = [1, 2, 3, 4, 5];
    auto results = ctx.mapParallel(data, (int x) => x * 2);
    assert(results == [2, 4, 6, 8, 10]);
    
    caps.shutdown();
    
    writeln("SIMD context tests passed!");
}

