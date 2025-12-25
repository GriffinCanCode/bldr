module infrastructure.utils.simd.bloom;

/// SIMD-Accelerated Bloom Filter
/// 
/// Probabilistic data structure for O(1) membership testing with tunable false positive rate.
/// Uses SIMD-vectorized probing for 2x query throughput on AVX2/AVX-512.
/// 
/// Design:
/// - Split-block Bloom filter with double hashing
/// - Cache-aligned bit array for optimal memory access
/// - GC-free core (betterC compatible C layer)
/// - Context-aware integration with SIMDCapabilities
/// - AVX2/AVX-512 vectorized probing via gather instructions
/// 
/// Use Cases:
/// - Cache lookup pre-filter (skip 90% of hash lookups)
/// - Deduplication pre-check
/// - Distributed cache membership
/// - URL/path filtering
/// 
/// Performance:
/// - Insert: O(k) where k = hash functions
/// - Query: O(k) with early termination
/// - Batch: 2x faster via SIMD vectorized probing
///   - AVX2: 4 hashes probed simultaneously
///   - AVX-512: 8 hashes probed simultaneously
/// 
/// Example:
/// ```d
/// // Create filter for 100K items with 1% FPR
/// auto filter = BloomFilter.create(100_000, 0.01);
/// 
/// // Insert items
/// filter.insert("path/to/file.d");
/// filter.insertHash(precomputedHash);
/// 
/// // Query (may return false positives, never false negatives)
/// if (filter.mayContain("path/to/file.d")) {
///     // Item MIGHT be present - do expensive lookup
/// } else {
///     // Item DEFINITELY not present - skip lookup
/// }
/// 
/// // SIMD batch operations (2x throughput)
/// auto hashes = [hash1, hash2, hash3, hash4];
/// auto matches = filter.countMatches(hashes);  // SIMD-accelerated
/// 
/// // Direct SIMD probing for maximum performance
/// if (filter.probeSIMD(hash)) { /* SIMD-parallel bit testing */ }
/// ```

import infrastructure.utils.crypto.blake3 : Blake3;
import std.traits : isIntegral;

extern(C) @system nothrow @nogc {
    /// Opaque C filter structure
    struct bloom_filter_t {
        ulong* bits;
        size_t num_bits;
        size_t num_words;
        uint num_hashes;
        size_t num_items;
        bool owns_memory;
    }

    /// Filter statistics from C layer
    struct bloom_stats_t {
        size_t num_bits;
        size_t num_items;
        uint num_hashes;
        double fill_ratio;
        double false_positive_rate;
        size_t memory_bytes;
    }

    /// C API bindings
    void bloom_optimal_params(size_t expected, double error, size_t* bits, uint* hashes);
    int bloom_init(bloom_filter_t* filter, size_t num_bits, uint num_hashes);
    int bloom_init_with_buffer(bloom_filter_t* filter, ulong* buffer, size_t words, uint hashes);
    void bloom_free(bloom_filter_t* filter);
    void bloom_reset(bloom_filter_t* filter);

    void bloom_insert_hash(bloom_filter_t* filter, ulong hash);
    void bloom_insert_hashes(bloom_filter_t* filter, ulong h1, ulong h2);
    void bloom_insert(bloom_filter_t* filter, const(ubyte)* data, size_t len);

    bool bloom_may_contain_hash(const(bloom_filter_t)* filter, ulong hash);
    bool bloom_may_contain_hashes(const(bloom_filter_t)* filter, ulong h1, ulong h2);
    bool bloom_may_contain(const(bloom_filter_t)* filter, const(ubyte)* data, size_t len);

    void bloom_insert_batch(bloom_filter_t* filter, const(ulong)* hashes, size_t count);
    ulong bloom_may_contain_batch(const(bloom_filter_t)* filter, const(ulong)* hashes, size_t count);
    size_t bloom_count_matches(const(bloom_filter_t)* filter, const(ulong)* hashes, size_t count);

    bloom_stats_t bloom_get_stats(const(bloom_filter_t)* filter);
    double bloom_estimate_fpr(const(bloom_filter_t)* filter);
    size_t bloom_popcount(const(bloom_filter_t)* filter);
    int bloom_merge(bloom_filter_t* dest, const(bloom_filter_t)* src);

    size_t bloom_serialize_size(const(bloom_filter_t)* filter);
    int bloom_serialize(const(bloom_filter_t)* filter, ubyte* buffer, size_t size);
    int bloom_deserialize(bloom_filter_t* filter, const(ubyte)* buffer, size_t size);
    
    /// SIMD probing API (bloom_simd.c)
    enum BloomSIMDLevel { NONE, AVX2, AVX512 }
    BloomSIMDLevel bloom_get_simd_level();
    const(char)* bloom_simd_level_name(BloomSIMDLevel level);
    uint bloom_probe_avx2_4(const(bloom_filter_t)* filter, const(ulong)* hashes);
    uint bloom_probe_avx512_8(const(bloom_filter_t)* filter, const(ulong)* hashes);
    ulong bloom_probe_simd_batch(const(bloom_filter_t)* filter, const(ulong)* hashes, size_t count);
    size_t bloom_count_matches_simd(const(bloom_filter_t)* filter, const(ulong)* hashes, size_t count);
    bool bloom_probe_single_simd(const(bloom_filter_t)* filter, ulong hash);
}

/// D-friendly Bloom filter wrapper
/// Thread-safe for concurrent reads, not thread-safe for writes
struct BloomFilter
{
    private bloom_filter_t _filter;
    private bool _initialized;
    
    @disable this(this);  // Non-copyable (owns C memory)
    
    /// Create filter with optimal parameters for expected items and error rate
    /// 
    /// Params:
    ///   expectedItems = Expected number of unique items
    ///   errorRate = Target false positive rate (0.01 = 1%, 0.001 = 0.1%)
    /// 
    /// Returns: Initialized BloomFilter or null on failure
    static BloomFilter create(size_t expectedItems, double errorRate = 0.01) @system
    {
        BloomFilter bf;
        
        size_t numBits;
        uint numHashes;
        bloom_optimal_params(expectedItems, errorRate, &numBits, &numHashes);
        
        if (bloom_init(&bf._filter, numBits, numHashes) == 0)
            bf._initialized = true;
        
        return bf;
    }
    
    /// Create filter with explicit parameters
    static BloomFilter createExplicit(size_t numBits, uint numHashes) @system
    {
        BloomFilter bf;
        
        if (bloom_init(&bf._filter, numBits, numHashes) == 0)
            bf._initialized = true;
        
        return bf;
    }
    
    /// Destructor - frees C memory
    ~this() @system
    {
        if (_initialized)
            bloom_free(&_filter);
    }
    
    /// Check if filter is valid
    @property bool valid() const pure @safe nothrow @nogc => _initialized;
    
    // === Insert Operations ===
    
    /// Insert by pre-computed 64-bit hash
    void insertHash(ulong hash) @system
    {
        if (_initialized)
            bloom_insert_hash(&_filter, hash);
    }
    
    /// Insert by two hashes (for double hashing schemes)
    void insertHashes(ulong h1, ulong h2) @system
    {
        if (_initialized)
            bloom_insert_hashes(&_filter, h1, h2);
    }
    
    /// Insert raw bytes (computes hash internally via FNV-1a)
    void insert(scope const(ubyte)[] data) @system
    {
        if (_initialized && data.length > 0)
            bloom_insert(&_filter, data.ptr, data.length);
    }
    
    /// Insert string (convenience)
    void insert(scope const(char)[] str) @system
    {
        insert(cast(const(ubyte)[])str);
    }
    
    /// Insert using BLAKE3 hash (recommended for cryptographic use)
    void insertBlake3(scope const(ubyte)[] data) @system
    {
        if (!_initialized) return;
        
        auto hash = Blake3.hash(data, 16);  // 128-bit hash
        ulong h1 = *cast(ulong*)hash.ptr;
        ulong h2 = *cast(ulong*)(hash.ptr + 8);
        bloom_insert_hashes(&_filter, h1, h2);
    }
    
    /// Insert multiple hashes in batch (SIMD-accelerated)
    void insertBatch(scope const(ulong)[] hashes) @system
    {
        if (_initialized && hashes.length > 0)
            bloom_insert_batch(&_filter, hashes.ptr, hashes.length);
    }
    
    // === Query Operations ===
    
    /// Check if hash might be present (may return false positive)
    bool mayContainHash(ulong hash) const @system
    {
        return _initialized && bloom_may_contain_hash(&_filter, hash);
    }
    
    /// Check with two hashes
    bool mayContainHashes(ulong h1, ulong h2) const @system
    {
        return _initialized && bloom_may_contain_hashes(&_filter, h1, h2);
    }
    
    /// Check raw bytes
    bool mayContain(scope const(ubyte)[] data) const @system
    {
        return _initialized && data.length > 0 && 
               bloom_may_contain(&_filter, data.ptr, data.length);
    }
    
    /// Check string (convenience)
    bool mayContain(scope const(char)[] str) const @system
    {
        return mayContain(cast(const(ubyte)[])str);
    }
    
    /// Check using BLAKE3 hash
    bool mayContainBlake3(scope const(ubyte)[] data) const @system
    {
        if (!_initialized) return false;
        
        auto hash = Blake3.hash(data, 16);
        ulong h1 = *cast(ulong*)hash.ptr;
        ulong h2 = *cast(ulong*)(hash.ptr + 8);
        return bloom_may_contain_hashes(&_filter, h1, h2);
    }
    
    /// Batch query (SIMD-accelerated)
    /// Returns bitmask where bit i = mayContain(hashes[i])
    ulong mayContainBatch(scope const(ulong)[] hashes) const @system
    {
        if (!_initialized || hashes.length == 0) return 0;
        immutable count = hashes.length > 64 ? 64 : hashes.length;
        return bloom_may_contain_batch(&_filter, hashes.ptr, count);
    }
    
    /// Count matches in batch (SIMD-accelerated)
    size_t countMatches(scope const(ulong)[] hashes) const @system
    {
        if (!_initialized || hashes.length == 0) return 0;
        return bloom_count_matches(&_filter, hashes.ptr, hashes.length);
    }
    
    // === SIMD-Vectorized Probing ===
    
    /// Query with SIMD-parallel bit testing
    /// All k hash positions tested simultaneously using AVX2/AVX-512
    /// ~2x faster than scalar for cache pre-filtering
    bool probeSIMD(ulong hash) const @system
    {
        return _initialized && bloom_probe_single_simd(&_filter, hash);
    }
    
    /// Probe 4 hashes in parallel (AVX2)
    /// Returns 4-bit mask: bit i set if hashes[i] may be present
    uint probeAVX2(scope const(ulong)[4] hashes) const @system
    {
        return _initialized ? bloom_probe_avx2_4(&_filter, hashes.ptr) : 0;
    }
    
    /// Probe 8 hashes in parallel (AVX-512)
    /// Returns 8-bit mask: bit i set if hashes[i] may be present
    uint probeAVX512(scope const(ulong)[8] hashes) const @system
    {
        return _initialized ? bloom_probe_avx512_8(&_filter, hashes.ptr) : 0;
    }
    
    /// Batch probe with auto SIMD dispatch
    /// Automatically uses best SIMD path (AVX-512 > AVX2 > scalar)
    ulong probeSIMDBatch(scope const(ulong)[] hashes) const @system
    {
        if (!_initialized || hashes.length == 0) return 0;
        immutable count = hashes.length > 64 ? 64 : hashes.length;
        return bloom_probe_simd_batch(&_filter, hashes.ptr, count);
    }
    
    /// Count matches using SIMD-accelerated probing
    size_t countMatchesSIMD(scope const(ulong)[] hashes) const @system
    {
        if (!_initialized || hashes.length == 0) return 0;
        return bloom_count_matches_simd(&_filter, hashes.ptr, hashes.length);
    }
    
    // === Statistics ===
    
    /// Get filter statistics
    BloomStats stats() const @system
    {
        if (!_initialized) return BloomStats.init;
        
        auto cstats = bloom_get_stats(&_filter);
        return BloomStats(
            cstats.num_bits,
            cstats.num_items,
            cstats.num_hashes,
            cstats.fill_ratio,
            cstats.false_positive_rate,
            cstats.memory_bytes
        );
    }
    
    /// Current false positive rate estimate
    @property double estimatedFPR() const @system
    {
        return _initialized ? bloom_estimate_fpr(&_filter) : 1.0;
    }
    
    /// Number of bits set
    @property size_t bitsSet() const @system
    {
        return _initialized ? bloom_popcount(&_filter) : 0;
    }
    
    /// Total capacity in bits
    @property size_t capacity() const pure @safe nothrow @nogc
    {
        return _initialized ? _filter.num_bits : 0;
    }
    
    /// Items inserted
    @property size_t itemCount() const pure @safe nothrow @nogc
    {
        return _initialized ? _filter.num_items : 0;
    }
    
    /// Memory usage in bytes
    @property size_t memoryBytes() const pure @safe nothrow @nogc
    {
        return _initialized ? _filter.num_words * 8 : 0;
    }
    
    // === Operations ===
    
    /// Reset filter to empty state
    void reset() @system
    {
        if (_initialized)
            bloom_reset(&_filter);
    }
    
    /// Merge another filter into this one (OR operation)
    /// Filters must have same size
    bool merge(ref const BloomFilter other) @system
    {
        if (!_initialized || !other._initialized) return false;
        return bloom_merge(&_filter, &other._filter) == 0;
    }
    
    // === Serialization ===
    
    /// Serialize filter to bytes
    ubyte[] serialize() const @system
    {
        if (!_initialized) return null;
        
        immutable size = bloom_serialize_size(&_filter);
        auto buffer = new ubyte[size];
        
        if (bloom_serialize(&_filter, buffer.ptr, size) != 0)
            return null;
        
        return buffer;
    }
    
    /// Deserialize filter from bytes
    static BloomFilter deserialize(scope const(ubyte)[] data) @system
    {
        BloomFilter bf;
        
        if (data.length > 0 && bloom_deserialize(&bf._filter, data.ptr, data.length) == 0)
            bf._initialized = true;
        
        return bf;
    }
}

/// Bloom filter statistics
struct BloomStats
{
    size_t numBits;          /// Total bits in filter
    size_t numItems;         /// Items inserted
    uint numHashes;          /// Hash functions used
    double fillRatio;        /// Fraction of bits set (0.0-1.0)
    double falsePositiveRate; /// Estimated FPR
    size_t memoryBytes;      /// Memory usage
    
    /// Human-readable summary
    string toString() const @safe
    {
        import std.format : format;
        return format(
            "BloomFilter(bits=%,d, items=%,d, k=%d, fill=%.1f%%, fpr=%.4f%%, mem=%,d bytes)",
            numBits, numItems, numHashes, 
            fillRatio * 100, falsePositiveRate * 100, memoryBytes
        );
    }
}

/// Calculate optimal parameters for Bloom filter
/// Returns tuple of (numBits, numHashes)
auto optimalParams(size_t expectedItems, double errorRate = 0.01) @system
{
    size_t bits;
    uint hashes;
    bloom_optimal_params(expectedItems, errorRate, &bits, &hashes);
    
    struct Params { size_t bits; uint hashes; }
    return Params(bits, hashes);
}

/// SIMD capability level for Bloom filter operations
enum BloomSIMD { None, AVX2, AVX512 }

/// Get current SIMD level for Bloom filter probing
BloomSIMD getBloomSIMDLevel() @system nothrow @nogc
{
    return cast(BloomSIMD)bloom_get_simd_level();
}

/// Get human-readable SIMD level name
string bloomSIMDLevelName() @system
{
    import std.string : fromStringz;
    return cast(string)fromStringz(bloom_simd_level_name(bloom_get_simd_level()));
}

// === Unit Tests ===

version(unittest) @system:

unittest
{
    import std.stdio : writeln;
    
    // Test creation with optimal params
    auto filter = BloomFilter.create(1000, 0.01);
    assert(filter.valid);
    assert(filter.capacity > 0);
    
    writeln("Bloom filter created: ", filter.stats());
}

unittest
{
    // Test insert and query
    auto filter = BloomFilter.create(100, 0.01);
    
    filter.insert("hello");
    filter.insert("world");
    filter.insertHash(0xDEADBEEF);
    
    assert(filter.mayContain("hello"));
    assert(filter.mayContain("world"));
    assert(filter.mayContainHash(0xDEADBEEF));
    
    // Should NOT be present
    assert(!filter.mayContain("goodbye"));
    
    assert(filter.itemCount == 3);
}

unittest
{
    // Test batch operations
    auto filter = BloomFilter.create(1000, 0.01);
    
    ulong[] hashes = [0x1111, 0x2222, 0x3333, 0x4444];
    filter.insertBatch(hashes);
    
    auto mask = filter.mayContainBatch(hashes);
    assert(mask == 0b1111);  // All 4 should be present
    
    assert(filter.countMatches(hashes) == 4);
}

unittest
{
    // Test serialization
    auto filter = BloomFilter.create(100, 0.01);
    filter.insert("test1");
    filter.insert("test2");
    
    auto serialized = filter.serialize();
    assert(serialized.length > 0);
    
    auto restored = BloomFilter.deserialize(serialized);
    assert(restored.valid);
    assert(restored.mayContain("test1"));
    assert(restored.mayContain("test2"));
}

unittest
{
    // Test false positive rate
    import std.random : Random, uniform;
    import std.conv : to;
    
    auto filter = BloomFilter.create(10_000, 0.01);
    
    // Insert 10K items
    foreach (i; 0 .. 10_000)
        filter.insertHash(i);
    
    // Check false positives on items not inserted
    size_t falsePositives = 0;
    foreach (i; 20_000 .. 30_000) {
        if (filter.mayContainHash(i))
            falsePositives++;
    }
    
    double actualFPR = cast(double)falsePositives / 10_000;
    
    // Should be close to target (1%)
    assert(actualFPR < 0.02, "FPR too high: " ~ actualFPR.to!string);
}

unittest
{
    // Test merge
    auto filter1 = BloomFilter.create(100, 0.01);
    auto filter2 = BloomFilter.create(100, 0.01);
    
    filter1.insert("a");
    filter1.insert("b");
    
    filter2.insert("c");
    filter2.insert("d");
    
    assert(filter1.merge(filter2));
    
    assert(filter1.mayContain("a"));
    assert(filter1.mayContain("b"));
    assert(filter1.mayContain("c"));
    assert(filter1.mayContain("d"));
}

unittest
{
    // Test BLAKE3 hashing mode
    auto filter = BloomFilter.create(100, 0.01);
    
    filter.insertBlake3(cast(ubyte[])"sensitive-data");
    assert(filter.mayContainBlake3(cast(ubyte[])"sensitive-data"));
    assert(!filter.mayContainBlake3(cast(ubyte[])"other-data"));
}

unittest
{
    import std.stdio : writeln;
    
    // Test SIMD probing capabilities
    auto level = getBloomSIMDLevel();
    writeln("Bloom SIMD level: ", bloomSIMDLevelName());
    
    auto filter = BloomFilter.create(1000, 0.01);
    
    // Insert test hashes
    ulong[8] testHashes = [0x1111, 0x2222, 0x3333, 0x4444, 0x5555, 0x6666, 0x7777, 0x8888];
    foreach (h; testHashes)
        filter.insertHash(h);
    
    // Test SIMD single probe
    assert(filter.probeSIMD(0x1111));
    assert(!filter.probeSIMD(0xDEAD));
    
    // Test AVX2 batch (4 hashes)
    ulong[4] avx2Batch = [0x1111, 0x2222, 0xDEAD, 0x4444];
    auto avx2Result = filter.probeAVX2(avx2Batch);
    assert(avx2Result & 0b0001);  // 0x1111 present
    assert(avx2Result & 0b0010);  // 0x2222 present
    assert(!(avx2Result & 0b0100));  // 0xDEAD not present
    assert(avx2Result & 0b1000);  // 0x4444 present
    
    // Test AVX-512 batch (8 hashes)
    ulong[8] avx512Batch = testHashes;
    avx512Batch[4] = 0xBEEF;  // Replace one with non-present
    auto avx512Result = filter.probeAVX512(avx512Batch);
    assert(avx512Result & 0b00001111);  // First 4 present
    assert(!(avx512Result & 0b00010000));  // 0xBEEF not present
    
    // Test SIMD batch dispatch
    auto batchResult = filter.probeSIMDBatch(testHashes[]);
    assert(batchResult == 0xFF);  // All 8 present
    
    // Test SIMD count
    assert(filter.countMatchesSIMD(testHashes[]) == 8);
    
    writeln("SIMD Bloom probing tests passed");
}

unittest
{
    import std.stdio : writeln;
    
    // Test optimal params calculation
    auto params = optimalParams(1_000_000, 0.001);
    
    writeln("For 1M items @ 0.1% FPR: ", params.bits, " bits, ", params.hashes, " hashes");
    
    assert(params.bits > 0);
    assert(params.hashes >= 2 && params.hashes <= 16);
}

