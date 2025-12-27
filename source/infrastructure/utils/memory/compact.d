module infrastructure.utils.memory.compact;

import core.atomic;
import core.sync.mutex : Mutex;
import std.traits : isCallable;

/// Compact reference: 8-byte handle combining index + hash for O(1) operations
/// 
/// Design: Flyweight pattern with hash-based fast-path comparison.
/// - 32-bit index: Up to 4B unique entries (more than enough for build targets)
/// - 32-bit hash: Fast equality pre-check, reduces full comparison by ~99%
/// 
/// Memory: 8 bytes vs typical 100+ bytes for string-based IDs
/// Performance:
/// - O(1) equality (8-byte compare, no string ops)
/// - O(1) hashing (return hash32 directly)
/// - O(1) registry lookup when full data needed
/// 
/// Thread Safety: Immutable after construction, no synchronization needed
struct CompactRef
{
    private uint _index;   // Registry index (uint.max = invalid)
    private uint _hash32;  // Truncated hash for fast comparison
    
    enum invalid = CompactRef(uint.max, 0);
    
    this(uint index, uint hash32) pure nothrow @safe @nogc
    {
        _index = index;
        _hash32 = hash32;
    }
    
    /// O(1) equality: compare 8 bytes directly
    bool opEquals(const CompactRef other) const pure nothrow @safe @nogc =>
        _index == other._index && _hash32 == other._hash32;
    
    /// O(1) hashing: use pre-computed hash32
    size_t toHash() const pure nothrow @safe @nogc => _hash32;
    
    /// Comparison for sorting (by index for determinism)
    int opCmp(const CompactRef other) const pure nothrow @safe @nogc
    {
        if (_index != other._index)
            return _index < other._index ? -1 : 1;
        if (_hash32 != other._hash32)
            return _hash32 < other._hash32 ? -1 : 1;
        return 0;
    }
    
    @property uint index() const pure nothrow @safe @nogc => _index;
    @property uint hash32() const pure nothrow @safe @nogc => _hash32;
    @property bool isValid() const pure nothrow @safe @nogc => _index != uint.max;
    
    /// Serialize to 8 bytes (little-endian)
    ubyte[8] serialize() const pure nothrow @trusted @nogc
    {
        ubyte[8] result;
        *cast(uint*)result[0 .. 4].ptr = _index;
        *cast(uint*)result[4 .. 8].ptr = _hash32;
        return result;
    }
    
    /// Deserialize from 8 bytes
    static CompactRef deserialize(const ubyte[8] data) pure nothrow @trusted @nogc
    {
        uint index = *cast(const(uint)*)data[0 .. 4].ptr;
        uint hash32 = *cast(const(uint)*)data[4 .. 8].ptr;
        return CompactRef(index, hash32);
    }
}

/// Thread-safe registry for compact reference resolution
/// 
/// Maps CompactRef index → original value T for full data recovery.
/// Uses Mutex for thread-safe access.
/// 
/// Capacity: Pre-allocated array for O(1) indexed lookup.
/// Growth: Doubles capacity when full (amortized O(1) insertion).
final class Registry(T)
{
    private T[] _values;
    private size_t[ulong] _hashToIndex;  // hash64 → index (deduplication)
    private shared size_t _count;
    private Mutex _mutex;
    
    /// Create registry with initial capacity
    this(size_t initialCapacity = 1024) @trusted
    {
        _values = new T[initialCapacity];
        _mutex = new Mutex();
    }
    
    /// Register value and get compact reference
    /// Thread-safe: uses mutex for synchronization
    /// 
    /// hashFn: Function to compute 64-bit hash from T
    /// Returns existing ref if already registered (deduplication)
    CompactRef register(alias hashFn)(T value) @trusted
        if (isCallable!hashFn)
    {
        immutable hash64 = hashFn(value);
        immutable hash32 = cast(uint)(hash64 & 0xFFFFFFFF);
        
        synchronized (_mutex)
        {
            // Check for existing entry (deduplication)
            if (auto existing = hash64 in _hashToIndex)
                return CompactRef(cast(uint)*existing, hash32);
            
            // Grow if needed
            immutable count = atomicLoad(_count);
            if (count >= _values.length)
                _values.length = _values.length * 2;
            
            // Register new entry
            immutable idx = cast(uint)count;
            _values[idx] = value;
            _hashToIndex[hash64] = idx;
            atomicOp!"+="(_count, 1);
            
            return CompactRef(idx, hash32);
        }
    }
    
    /// Resolve compact reference to original value
    /// Thread-safe: uses mutex for synchronization
    /// Returns T.init if ref is invalid
    T resolve(CompactRef ref_) @trusted
    {
        if (!ref_.isValid)
            return T.init;
        
        synchronized (_mutex)
        {
            immutable count = atomicLoad(_count);
            if (ref_.index >= count)
                return T.init;
            return _values[ref_.index];
        }
    }
    
    /// Batch resolve multiple refs (reduces lock acquisitions)
    T[] resolveMany(const CompactRef[] refs) @trusted
    {
        T[] results;
        results.reserve(refs.length);
        
        synchronized (_mutex)
        {
            immutable count = atomicLoad(_count);
            foreach (ref_; refs)
            {
                if (ref_.isValid && ref_.index < count)
                    results ~= _values[ref_.index];
                else
                    results ~= T.init;
            }
        }
        return results;
    }
    
    /// Get current entry count
    @property size_t count() @trusted nothrow =>
        atomicLoad(_count);
    
    /// Get capacity
    @property size_t capacity() @trusted nothrow
    {
        try
        {
            synchronized (_mutex)
                return _values.length;
        }
        catch (Exception) { return 0; }
    }
    
    /// Clear registry (invalidates all existing refs)
    void clear() @trusted
    {
        synchronized (_mutex)
        {
            _hashToIndex.clear();
            atomicStore(_count, cast(size_t)0);
        }
    }
}

/// Compute 64-bit hash using FNV-1a (fast, good distribution)
/// Suitable for string-like data
ulong fnv64(const(char)[] data) pure nothrow @safe @nogc
{
    enum ulong FNV_OFFSET = 14695981039346656037UL;
    enum ulong FNV_PRIME = 1099511628211UL;
    
    ulong hash = FNV_OFFSET;
    foreach (b; cast(const(ubyte)[])data)
    {
        hash ^= b;
        hash *= FNV_PRIME;
    }
    return hash;
}

/// Combine multiple hashes (for composite keys)
ulong hashCombine(ulong h1, ulong h2) pure nothrow @safe @nogc =>
    h1 ^ (h2 + 0x9e3779b97f4a7c15UL + (h1 << 6) + (h1 >> 2));

// ============================================================================
// Unit Tests
// ============================================================================

unittest
{
    // Test CompactRef basics
    auto r1 = CompactRef(0, 12345);
    auto r2 = CompactRef(0, 12345);
    auto r3 = CompactRef(1, 12345);
    
    assert(r1 == r2);
    assert(r1 != r3);
    assert(r1.toHash() == 12345);
    assert(r1.isValid);
    assert(!CompactRef.invalid.isValid);
}

unittest
{
    // Test CompactRef serialization
    auto original = CompactRef(42, 0xDEADBEEF);
    auto serialized = original.serialize();
    auto restored = CompactRef.deserialize(serialized);
    
    assert(restored == original);
    assert(restored.index == 42);
    assert(restored.hash32 == 0xDEADBEEF);
}

unittest
{
    // Test Registry basics
    auto registry = new Registry!string(16);
    
    auto ref1 = registry.register!fnv64("hello");
    auto ref2 = registry.register!fnv64("hello");  // Same value
    auto ref3 = registry.register!fnv64("world");
    
    // Deduplication
    assert(ref1 == ref2);
    assert(ref1 != ref3);
    
    // Resolution
    assert(registry.resolve(ref1) == "hello");
    assert(registry.resolve(ref3) == "world");
    assert(registry.count == 2);
}

unittest
{
    // Test batch resolution
    auto registry = new Registry!string(16);
    
    CompactRef[] refs;
    refs ~= registry.register!fnv64("a");
    refs ~= registry.register!fnv64("b");
    refs ~= registry.register!fnv64("c");
    
    auto resolved = registry.resolveMany(refs);
    assert(resolved == ["a", "b", "c"]);
}

unittest
{
    // Test FNV-64 hash
    assert(fnv64("hello") != fnv64("world"));
    assert(fnv64("") != fnv64("a"));
    
    // Determinism
    assert(fnv64("test") == fnv64("test"));
}

unittest
{
    // Test hash combining
    auto h1 = fnv64("workspace");
    auto h2 = fnv64("path");
    auto h3 = fnv64("name");
    
    auto combined1 = hashCombine(hashCombine(h1, h2), h3);
    auto combined2 = hashCombine(hashCombine(h1, h2), h3);
    
    assert(combined1 == combined2);  // Deterministic
    assert(combined1 != h1);         // Different from inputs
}

@system unittest
{
    import std.parallelism : parallel;
    import std.range : iota;
    import std.conv : to;
    
    // Thread safety test
    auto registry = new Registry!string(16);
    
    foreach (_; parallel(iota(100)))
    {
        auto r1 = registry.register!fnv64("concurrent");
        auto r2 = registry.register!fnv64("test");
        assert(registry.resolve(r1) == "concurrent");
        assert(registry.resolve(r2) == "test");
    }
    
    assert(registry.count == 2);  // Deduplication worked across threads
}

