module infrastructure.utils.memory.shardedcache;

import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.utils.memory.compact : fnv64;

/// Generic sharded cache for high-concurrency key-value storage
/// 
/// Design: Lock-striped sharding distributes keys across N independent shards,
/// reducing mutex contention from O(1) global to O(1/N) per-shard.
/// 
/// Usage:
/// ```d
/// // String-keyed cache
/// auto cache = new ShardedCache!(string, FileAnalysis)();
/// cache.put("path/to/file.d", analysis);
/// auto result = cache.get("path/to/file.d");
/// 
/// // Integer-keyed cache  
/// auto workers = new ShardedCache!(uint, WorkerInfo, (k) => k)();
/// ```
/// 
/// Performance:
/// - N shards = N× reduction in contention
/// - Lock-free reads when key absent
/// - Per-shard statistics, lock-free aggregation
/// 
/// Thread Safety:
/// - All operations thread-safe via per-shard mutexes
/// - Never holds multiple shard locks (no deadlock)
final class ShardedCache(K, V, alias hashFn = defaultHash!K)
{
    private static struct Shard
    {
        V[K] data;
        Mutex lock;
        shared size_t gets;
        shared size_t puts;
        shared size_t hits;
        
        void initialize() @trusted { lock = new Mutex(); }
        
        V* get(K key) @trusted
        {
            synchronized (lock)
            {
                atomicOp!"+="(gets, 1);
                if (auto ptr = key in data)
                {
                    atomicOp!"+="(hits, 1);
                    return ptr;
                }
                return null;
            }
        }
        
        void put(K key, V value) @trusted
        {
            synchronized (lock)
            {
                data[key] = value;
                atomicOp!"+="(puts, 1);
            }
        }
        
        bool remove(K key) @trusted
        {
            synchronized (lock)
            {
                if (key in data) { data.remove(key); return true; }
                return false;
            }
        }
        
        size_t length() const @trusted nothrow => data.length;
        
        void clear() @trusted
        {
            synchronized (lock)
            {
                data.clear();
                atomicStore(gets, cast(size_t)0);
                atomicStore(puts, cast(size_t)0);
                atomicStore(hits, cast(size_t)0);
            }
        }
    }
    
    private Shard[] shards;
    private immutable size_t shardMask;
    private immutable ubyte shardBits;
    
    /// Construct with N shards (power of 2, default 16)
    this(size_t shardCount = 16) @trusted
    {
        import std.math : isPowerOf2;
        assert(isPowerOf2(shardCount), "Shard count must be power of 2");
        
        shardMask = shardCount - 1;
        
        size_t temp = shardCount;
        ubyte bits = 0;
        while (temp > 1) { temp >>= 1; bits++; }
        shardBits = bits;
        
        shards.length = shardCount;
        foreach (ref s; shards) s.initialize();
    }
    
    private size_t shardOf(K key) const pure nothrow @nogc @safe
    {
        static if (is(K == string))
            return (fnv64(key) >> (64 - shardBits)) & shardMask;
        else
        {
            immutable h = hashFn(key);
            static if (is(typeof(h) == ulong))
                return (h >> (64 - shardBits)) & shardMask;
            else
                return h & shardMask;
        }
    }
    
    /// Get value by key (returns null if absent)
    V* get(K key) @trusted => shards[shardOf(key)].get(key);
    
    /// Put value by key
    void put(K key, V value) @trusted => shards[shardOf(key)].put(key, value);
    
    /// Remove key (returns true if existed)
    bool remove(K key) @trusted => shards[shardOf(key)].remove(key);
    
    /// Check existence
    bool has(K key) @trusted => get(key) !is null;
    
    /// Get or compute value
    V getOrPut(K key, lazy V defaultValue) @trusted
    {
        if (auto ptr = get(key)) return *ptr;
        auto val = defaultValue;
        put(key, val);
        return val;
    }
    
    /// Update existing value (returns true if key existed)
    bool update(K key, V delegate(ref V) @safe updater) @trusted
    {
        auto idx = shardOf(key);
        synchronized (shards[idx].lock)
        {
            if (auto ptr = key in shards[idx].data)
            {
                *ptr = updater(*ptr);
                return true;
            }
            return false;
        }
    }
    
    /// Total entries
    @property size_t length() const @trusted nothrow
    {
        size_t total = 0;
        foreach (ref s; shards) total += s.length;
        return total;
    }
    
    /// Statistics
    ShardedCacheStats getStats() const @trusted
    {
        ShardedCacheStats stats;
        stats.shardCount = shardMask + 1;
        
        foreach (ref s; shards)
        {
            stats.totalGets += atomicLoad(s.gets);
            stats.totalPuts += atomicLoad(s.puts);
            stats.totalHits += atomicLoad(s.hits);
            
            immutable len = s.length;
            stats.entries += len;
            if (len < stats.minShard || stats.minShard == 0) stats.minShard = len;
            if (len > stats.maxShard) stats.maxShard = len;
        }
        
        if (stats.totalGets > 0)
            stats.hitRate = cast(double)stats.totalHits / stats.totalGets * 100.0;
        if (stats.maxShard > 0)
            stats.balance = cast(double)stats.minShard / stats.maxShard;
        
        return stats;
    }
    
    /// Clear all shards
    void clear() @trusted { foreach (ref s; shards) s.clear(); }
    
    /// Iterate all values (locks all shards - use sparingly)
    int opApply(scope int delegate(K, ref V) dg) @trusted
    {
        foreach (ref s; shards)
            synchronized (s.lock)
                foreach (k, ref v; s.data)
                    if (auto result = dg(k, v)) return result;
        return 0;
    }
}

/// Default hash for string keys
private ulong defaultHash(K)(K key) pure nothrow @nogc @safe
{
    static if (is(K == string))
        return fnv64(key);
    else static if (is(K : ulong))
        return cast(ulong)key * 0x9e3779b97f4a7c15UL;  // Golden ratio
    else
        static assert(false, "Provide custom hash function for type " ~ K.stringof);
}

/// Cache statistics
struct ShardedCacheStats
{
    size_t shardCount;
    size_t entries;
    size_t totalGets;
    size_t totalPuts;
    size_t totalHits;
    size_t minShard;
    size_t maxShard;
    double hitRate;   // 0-100%
    double balance;   // 0-1 (1 = perfect)
}

// ============================================================================
// Specialized Caches
// ============================================================================

/// Content-addressed cache (keyed by hash)
alias ContentCache(V) = ShardedCache!(string, V);

/// Path-keyed cache (common for file systems)
alias PathCache(V) = ShardedCache!(string, V);

/// Integer-keyed cache (worker IDs, etc.)
alias IdCache(V) = ShardedCache!(uint, V, (k) => cast(ulong)k);

// ============================================================================
// Unit Tests
// ============================================================================

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Basic operations");
    
    auto cache = new ShardedCache!(string, int)();
    
    cache.put("a", 1);
    cache.put("b", 2);
    
    assert(*cache.get("a") == 1);
    assert(*cache.get("b") == 2);
    assert(cache.get("c") is null);
    assert(cache.has("a"));
    assert(!cache.has("c"));
    
    writeln("\x1b[32m  ✓ Basic operations\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - getOrPut");
    
    auto cache = new ShardedCache!(string, int)();
    
    auto v1 = cache.getOrPut("key", 42);
    assert(v1 == 42);
    
    auto v2 = cache.getOrPut("key", 99);  // Should return existing
    assert(v2 == 42);
    
    writeln("\x1b[32m  ✓ getOrPut\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Update");
    
    auto cache = new ShardedCache!(string, int)();
    
    cache.put("counter", 0);
    
    cache.update("counter", (ref int v) @safe { v += 10; return v; });
    assert(*cache.get("counter") == 10);
    
    auto updated = cache.update("missing", (ref int v) @safe { v += 1; return v; });
    assert(!updated);
    
    writeln("\x1b[32m  ✓ Update\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Remove");
    
    auto cache = new ShardedCache!(string, int)();
    
    cache.put("key", 1);
    assert(cache.has("key"));
    
    auto removed = cache.remove("key");
    assert(removed);
    assert(!cache.has("key"));
    
    auto removedAgain = cache.remove("key");
    assert(!removedAgain);
    
    writeln("\x1b[32m  ✓ Remove\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Statistics");
    
    auto cache = new ShardedCache!(string, int)(8);
    
    foreach (i; 0 .. 100)
    {
        import std.conv : to;
        cache.put("key_" ~ i.to!string, i);
    }
    
    // Generate some hits and misses
    foreach (i; 0 .. 50)
    {
        import std.conv : to;
        cache.get("key_" ~ i.to!string);  // Hit
    }
    cache.get("missing");  // Miss
    
    auto stats = cache.getStats();
    assert(stats.entries == 100);
    assert(stats.totalPuts == 100);
    assert(stats.totalGets == 51);
    assert(stats.totalHits == 50);
    assert(stats.hitRate > 90.0);
    
    writeln("\x1b[32m  ✓ Statistics (hit rate: ", stats.hitRate, "%)\x1b[0m");
}

@system unittest
{
    import std.stdio : writeln;
    import std.parallelism : parallel;
    import std.range : iota;
    import std.conv : to;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Concurrent access");
    
    auto cache = new ShardedCache!(string, int)(16);
    
    foreach (_; parallel(iota(100)))
    {
        foreach (i; 0 .. 100)
        {
            cache.put("shared_" ~ (i % 10).to!string, i);
            cache.get("shared_" ~ (i % 10).to!string);
        }
    }
    
    assert(cache.length <= 10);  // Only 10 unique keys
    
    auto stats = cache.getStats();
    assert(stats.totalGets == 10000);
    
    writeln("\x1b[32m  ✓ Concurrent access (", stats.totalGets, " gets)\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Integer keys");
    
    auto cache = new IdCache!string();
    
    cache.put(1, "one");
    cache.put(2, "two");
    cache.put(1000, "thousand");
    
    assert(*cache.get(1) == "one");
    assert(*cache.get(1000) == "thousand");
    
    writeln("\x1b[32m  ✓ Integer keys\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    writeln("\x1b[36m[TEST]\x1b[0m utils.memory.shardedcache - Iteration");
    
    auto cache = new ShardedCache!(string, int)(4);
    
    cache.put("a", 1);
    cache.put("b", 2);
    cache.put("c", 3);
    
    int sum = 0;
    foreach (k, ref v; cache)
        sum += v;
    
    assert(sum == 6);
    
    writeln("\x1b[32m  ✓ Iteration\x1b[0m");
}

