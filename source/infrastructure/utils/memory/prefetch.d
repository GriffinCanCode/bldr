module infrastructure.utils.memory.prefetch;

/// Memory prefetch hints for cache optimization
/// 
/// Provides CPU cache prefetch instructions for reducing memory latency
/// in graph traversal and other pointer-chasing workloads.
/// 
/// Usage:
/// ```d
/// // Prefetch next node before processing current
/// foreach (idx; node.dependencyIndices)
/// {
///     prefetch(&_nodeArray[idx]);
///     // Process current node while prefetch loads next
/// }
/// ```
/// 
/// Locality hints:
/// - T0: Temporal data - prefetch to all cache levels (high reuse)
/// - T1: Temporal data - prefetch to L2 and higher (medium reuse)
/// - T2: Temporal data - prefetch to L3 and higher (low reuse)
/// - NTA: Non-temporal - minimize cache pollution (single use)

/// Prefetch locality hint
enum PrefetchLocality : ubyte
{
    NonTemporal = 0,  // NTA - minimize cache pollution
    T2 = 1,           // Low temporal locality
    T1 = 2,           // Medium temporal locality (L2)
    T0 = 3,           // High temporal locality (all levels)
}

/// Prefetch data for read access
/// 
/// Issues a prefetch hint to bring data into cache before it's needed.
/// No-op if address is null or on unsupported architectures.
pragma(inline, true)
void prefetch(T)(const(T)* addr, PrefetchLocality locality = PrefetchLocality.T0) @system nothrow @nogc
{
    if (addr is null) return;
    prefetchRaw(cast(const(void)*)addr, locality);
}

/// Prefetch raw pointer
pragma(inline, true)
void prefetchRaw(const(void)* addr, PrefetchLocality locality = PrefetchLocality.T0) @system nothrow @nogc
{
    if (addr is null) return;
    
    version (X86_64)
    {
        // x86-64 prefetch instructions
        final switch (locality)
        {
            case PrefetchLocality.NonTemporal:
                asm @trusted nothrow @nogc { prefetchnta [addr]; }
                break;
            case PrefetchLocality.T2:
                asm @trusted nothrow @nogc { prefetcht2 [addr]; }
                break;
            case PrefetchLocality.T1:
                asm @trusted nothrow @nogc { prefetcht1 [addr]; }
                break;
            case PrefetchLocality.T0:
                asm @trusted nothrow @nogc { prefetcht0 [addr]; }
                break;
        }
    }
    else version (X86)
    {
        // x86 32-bit prefetch
        final switch (locality)
        {
            case PrefetchLocality.NonTemporal:
                asm @trusted nothrow @nogc { prefetchnta [addr]; }
                break;
            case PrefetchLocality.T2:
                asm @trusted nothrow @nogc { prefetcht2 [addr]; }
                break;
            case PrefetchLocality.T1:
                asm @trusted nothrow @nogc { prefetcht1 [addr]; }
                break;
            case PrefetchLocality.T0:
                asm @trusted nothrow @nogc { prefetcht0 [addr]; }
                break;
        }
    }
    else version (AArch64)
    {
        // ARM64 prefetch - PRFM instruction
        // Uses PLDL1KEEP for T0, PLDL2KEEP for T1/T2, PLDL1STRM for NTA
        asm @trusted nothrow @nogc
        {
            "prfm pldl1keep, [%0]" : : "r" (addr);
        }
    }
    else
    {
        // No-op on unsupported architectures
    }
}

/// Prefetch for write access (exclusive cache line ownership)
pragma(inline, true)
void prefetchWrite(T)(T* addr) @system nothrow @nogc
{
    if (addr is null) return;
    
    version (X86_64)
    {
        asm @trusted nothrow @nogc { prefetchw [addr]; }
    }
    else version (X86)
    {
        asm @trusted nothrow @nogc { prefetchw [addr]; }
    }
    else version (AArch64)
    {
        asm @trusted nothrow @nogc
        {
            "prfm pstl1keep, [%0]" : : "r" (addr);
        }
    }
}

/// Batch prefetch - prefetch multiple addresses with stride
/// Useful for prefetching next N nodes in graph traversal
/// Note: For calibrated lookahead, use prefetchBatchCalibrated from calibration module
pragma(inline, true)
void prefetchBatch(T)(const(T)* base, const(uint)[] indices, size_t lookahead = 4) @system nothrow @nogc
{
    if (base is null || indices.length == 0) return;
    
    immutable count = indices.length < lookahead ? indices.length : lookahead;
    foreach (i; 0 .. count)
        prefetch(base + indices[i], PrefetchLocality.T1);
}

/// Prefetch array elements ahead of current position
/// Call at start of loop iteration to prefetch future iterations
/// Note: For calibrated distance, use prefetchAheadCalibrated from calibration module
pragma(inline, true)
void prefetchAhead(T)(const(T)[] arr, size_t currentIdx, size_t distance = 8) @system nothrow @nogc
{
    if (arr.length == 0) return;
    
    immutable targetIdx = currentIdx + distance;
    if (targetIdx < arr.length)
        prefetch(&arr[targetIdx], PrefetchLocality.T0);
}

// ═══════════════════════════════════════════════════════════════════════
// Calibrated Prefetch (re-exported from calibration module)
// ═══════════════════════════════════════════════════════════════════════

public import infrastructure.utils.memory.calibration : 
    CacheCalibration, CacheParams, 
    prefetchAheadCalibrated, prefetchBatchCalibrated, 
    prefetchMultiLevel, AdaptivePrefetcher;

unittest
{
    // Basic prefetch test
    int[100] data;
    foreach (i; 0 .. 100)
        data[i] = cast(int)i;
    
    // Should not crash
    prefetch(&data[50]);
    prefetchWrite(&data[50]);
    prefetch(cast(int*)null);  // Null safety
    
    // Batch prefetch
    uint[] indices = [10, 20, 30, 40];
    prefetchBatch(data.ptr, indices);
    
    // Ahead prefetch
    prefetchAhead(data[], 0, 8);
}

