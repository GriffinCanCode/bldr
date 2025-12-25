module engine.distributed.coordinator.hash;

import std.algorithm : filter, map, sort;
import std.array : array;
import std.conv : to;
import core.sync.rwmutex : ReadWriteMutex;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;
import infrastructure.utils.crypto.blake3 : Blake3;

/// Affinity key for consistent hashing (language + toolchain)
struct AffinityKey
{
    string language;   // e.g., "D", "Rust", "TypeScript"
    string toolchain;  // e.g., "dmd", "rustc-1.75", "tsc-5.0"
    
    this(string language, string toolchain = "") pure nothrow @safe
    {
        this.language = language;
        this.toolchain = toolchain;
    }
    
    /// Create from language enum value
    static AffinityKey fromLanguage(T)(T lang, string toolchain = "") @safe
        if (is(T == enum))
    {
        return AffinityKey(lang.to!string, toolchain);
    }
    
    /// Compute 64-bit hash using BLAKE3 (first 8 bytes of hash)
    ulong toHash() const @trusted
    {
        // Use BLAKE3 for cryptographically strong, well-distributed hashing
        auto b = Blake3(0);
        b.put(language);
        b.put(":");  // Separator to avoid collisions
        b.put(toolchain);
        auto hashBytes = b.finish(8);  // Only need 8 bytes for ulong
        
        // Convert first 8 bytes to ulong (little-endian)
        ulong result = 0;
        foreach (i, byte_; hashBytes)
            result |= cast(ulong)byte_ << (i * 8);
        return result;
    }
    
    string toString() const pure @safe => language ~ (toolchain.length > 0 ? ":" ~ toolchain : "");
    bool opEquals(const AffinityKey other) const pure nothrow @safe => language == other.language && toolchain == other.toolchain;
}

/// Jump Consistent Hash implementation (Google, 2014)
/// O(ln n) time, O(1) space, excellent distribution
/// Reference: https://arxiv.org/abs/1406.2294
struct JumpHash
{
    /// Compute bucket index for given key and number of buckets
    /// Returns value in [0, numBuckets)
    static size_t hash(ulong key, size_t numBuckets) pure nothrow @safe @nogc
    {
        if (numBuckets <= 1) return 0;
        
        long b = -1, j = 0;
        while (j < numBuckets)
        {
            b = j;
            key = key * 2862933555777941757UL + 1;
            j = cast(long)((b + 1) * (cast(double)(1L << 31) / cast(double)((key >> 33) + 1)));
        }
        return cast(size_t)b;
    }
}

/// Weighted node for consistent hash ring
private struct WeightedNode
{
    WorkerId id;
    uint weight;        // Higher = more virtual nodes
    uint virtualNodes;  // Actual virtual node count
}

/// Ketama-style consistent hash ring (optional alternative to Jump Hash)
/// Better for heterogeneous worker capacities with varying weights
final class KetamaRing
{
    private struct RingEntry { ulong hash; WorkerId worker; }
    
    private RingEntry[] ring;
    private WorkerId[] workerList;
    private ReadWriteMutex mutex;
    
    private enum VIRTUAL_NODES_PER_WEIGHT = 40;  // Virtual nodes per weight unit
    
    this() @trusted { mutex = new ReadWriteMutex(); }
    
    /// Add worker with weight (higher = more traffic)
    void addWorker(WorkerId id, uint weight = 1) @trusted
    {
        if (weight == 0) weight = 1;
        
        synchronized (mutex.writer)
        {
            immutable virtualCount = weight * VIRTUAL_NODES_PER_WEIGHT;
            
            foreach (i; 0 .. virtualCount)
            {
                // Hash worker ID with virtual node index
                immutable hash = computeNodeHash(id, i);
                ring ~= RingEntry(hash, id);
            }
            
            workerList ~= id;
            ring.sort!((a, b) => a.hash < b.hash);
        }
    }
    
    /// Remove worker from ring
    void removeWorker(WorkerId id) @trusted
    {
        import std.algorithm : remove;
        
        synchronized (mutex.writer)
        {
            ring = ring.remove!(e => e.worker == id);
            workerList = workerList.remove!(w => w == id);
        }
    }
    
    /// Get worker for given affinity key
    Result!(WorkerId, string) getWorker(AffinityKey key) @trusted
    {
        synchronized (mutex.reader)
        {
            if (ring.length == 0)
                return Err!(WorkerId, string)("No workers in ring");
            
            immutable keyHash = key.toHash();
            
            // Binary search for first entry >= keyHash (ring walk)
            size_t lo = 0, hi = ring.length;
            while (lo < hi)
            {
                immutable mid = lo + (hi - lo) / 2;
                if (ring[mid].hash < keyHash) lo = mid + 1;
                else hi = mid;
            }
            
            // Wrap around to start of ring if past end
            immutable idx = lo < ring.length ? lo : 0;
            return Ok!(WorkerId, string)(ring[idx].worker);
        }
    }
    
    /// Get N distinct workers for replication
    WorkerId[] getWorkers(AffinityKey key, size_t count) @trusted
    {
        import std.algorithm : uniq;
        
        synchronized (mutex.reader)
        {
            if (ring.length == 0 || count == 0) return [];
            
            WorkerId[] result;
            result.reserve(count);
            
            immutable keyHash = key.toHash();
            
            // Find starting position
            size_t lo = 0, hi = ring.length;
            while (lo < hi)
            {
                immutable mid = lo + (hi - lo) / 2;
                if (ring[mid].hash < keyHash) lo = mid + 1;
                else hi = mid;
            }
            
            // Walk ring collecting distinct workers
            size_t idx = lo < ring.length ? lo : 0;
            size_t seen = 0;
            
            while (result.length < count && seen < ring.length)
            {
                import std.algorithm : canFind;
                if (!result.canFind(ring[idx].worker))
                    result ~= ring[idx].worker;
                
                idx = (idx + 1) % ring.length;
                seen++;
            }
            
            return result;
        }
    }
    
    /// Get all workers in ring
    WorkerId[] allWorkers() @trusted
    {
        synchronized (mutex.reader) return workerList.dup;
    }
    
    size_t workerCount() @trusted
    {
        synchronized (mutex.reader) return workerList.length;
    }
    
    private static ulong computeNodeHash(WorkerId id, size_t virtualIndex) @trusted
    {
        // Use BLAKE3 for cryptographically strong distribution
        auto b = Blake3(0);
        
        // Hash worker ID (8 bytes)
        ubyte[8] idBytes;
        ulong val = id.value;
        foreach (i; 0 .. 8) { idBytes[i] = cast(ubyte)(val & 0xFF); val >>= 8; }
        b.put(idBytes[]);
        
        // Hash virtual index (8 bytes)
        ubyte[8] idxBytes;
        val = virtualIndex;
        foreach (i; 0 .. 8) { idxBytes[i] = cast(ubyte)(val & 0xFF); val >>= 8; }
        b.put(idxBytes[]);
        
        // Get 8-byte hash and convert to ulong
        auto hashBytes = b.finish(8);
        ulong result = 0;
        foreach (i, byte_; hashBytes)
            result |= cast(ulong)byte_ << (i * 8);
        return result;
    }
}

/// Affinity-aware worker selector using consistent hashing
/// Combines Jump Hash for efficiency with load awareness
final class AffinitySelector
{
    private WorkerId[] workers;           // Ordered worker list for Jump Hash
    private uint[WorkerId] workerIndices; // Worker -> index mapping
    private ReadWriteMutex mutex;
    
    // Affinity cache: tracks which workers have warm caches for which affinities
    private WorkerId[][AffinityKey] affinityCache;
    private size_t maxAffinityCacheSize = 1024;
    
    this() @trusted { mutex = new ReadWriteMutex(); }
    
    /// Register worker (appends to end, maintains stable ordering)
    void addWorker(WorkerId id) @trusted
    {
        synchronized (mutex.writer)
        {
            if (id in workerIndices) return;  // Already registered
            workerIndices[id] = cast(uint)workers.length;
            workers ~= id;
        }
    }
    
    /// Remove worker (marks slot as dead, doesn't reorder)
    /// Uses tombstone approach to maintain hash stability
    void removeWorker(WorkerId id) @trusted
    {
        synchronized (mutex.writer)
        {
            if (auto idx = id in workerIndices)
            {
                // Mark as dead by setting to broadcast (0)
                workers[*idx] = WorkerId.broadcast();
                workerIndices.remove(id);
                
                // Clean up affinity cache
                foreach (key, ref workerList; affinityCache)
                {
                    import std.algorithm : remove;
                    workerList = workerList.remove!(w => w == id);
                }
            }
        }
    }
    
    /// Select worker using Jump Hash with affinity
    /// Returns primary worker for given affinity key
    Result!(WorkerId, string) selectWorker(AffinityKey affinity) @trusted
    {
        WorkerId selected;
        bool found = false;
        
        synchronized (mutex.reader)
        {
            if (workers.length == 0)
                return Err!(WorkerId, string)("No workers available");
            
            // Count active workers
            size_t activeCount = 0;
            foreach (w; workers)
                if (!w.isBroadcast()) activeCount++;
            
            if (activeCount == 0)
                return Err!(WorkerId, string)("No active workers");
            
            // Jump Hash into active worker space
            immutable keyHash = affinity.toHash();
            immutable targetIdx = JumpHash.hash(keyHash, activeCount);
            
            // Map to actual worker (skip tombstones)
            size_t activeIdx = 0;
            foreach (w; workers)
            {
                if (w.isBroadcast()) continue;
                if (activeIdx == targetIdx)
                {
                    selected = w;
                    found = true;
                    break;
                }
                activeIdx++;
            }
        }
        
        if (!found)
            return Err!(WorkerId, string)("Worker selection failed");
        
        // Record affinity hit outside of reader lock
        synchronized (mutex.writer)
            recordAffinityHitUnsafe(affinity, selected);
        
        return Ok!(WorkerId, string)(selected);
    }
    
    /// Select worker with fallback options (for load balancing)
    /// Returns array of workers in preference order
    WorkerId[] selectWithFallbacks(AffinityKey affinity, size_t count = 3) @trusted
    {
        synchronized (mutex.reader)
        {
            if (workers.length == 0) return [];
            
            WorkerId[] result;
            result.reserve(count);
            
            immutable keyHash = affinity.toHash();
            
            // Get active workers
            WorkerId[] active;
            foreach (w; workers)
                if (!w.isBroadcast()) active ~= w;
            
            if (active.length == 0) return [];
            
            // Primary from Jump Hash
            immutable primaryIdx = JumpHash.hash(keyHash, active.length);
            result ~= active[primaryIdx];
            
            // Secondary/tertiary from offset Jump Hash (different seeds)
            foreach (i; 1 .. count)
            {
                if (result.length >= active.length) break;
                
                immutable offsetKey = keyHash ^ (cast(ulong)i * 0x9E3779B97F4A7C15);
                immutable idx = JumpHash.hash(offsetKey, active.length);
                
                import std.algorithm : canFind;
                if (!result.canFind(active[idx]))
                    result ~= active[idx];
            }
            
            return result;
        }
    }
    
    /// Check if worker has affinity for given key (warm cache likely)
    bool hasAffinity(WorkerId worker, AffinityKey affinity) @trusted
    {
        synchronized (mutex.reader)
        {
            if (auto cached = affinity in affinityCache)
            {
                import std.algorithm : canFind;
                return (*cached).canFind(worker);
            }
            return false;
        }
    }
    
    /// Record affinity hit for cache warming tracking
    /// Must be called with writer lock held
    private void recordAffinityHitUnsafe(AffinityKey affinity, WorkerId worker) @trusted
    {
        if (auto cached = affinity in affinityCache)
        {
            import std.algorithm : canFind;
            if (!(*cached).canFind(worker))
            {
                if ((*cached).length < 3)  // Max 3 workers per affinity
                    *cached ~= worker;
            }
        }
        else
        {
            // Evict if cache full
            if (affinityCache.length >= maxAffinityCacheSize)
            {
                // Simple LRU: remove first entry
                foreach (key; affinityCache.byKey)
                {
                    affinityCache.remove(key);
                    break;
                }
            }
            affinityCache[affinity] = [worker];
        }
    }
    
    /// Record affinity hit (acquires writer lock)
    void recordAffinityHit(AffinityKey affinity, WorkerId worker) @trusted
    {
        synchronized (mutex.writer)
            recordAffinityHitUnsafe(affinity, worker);
    }
    
    /// Get workers known to have affinity for a key
    WorkerId[] getAffinityWorkers(AffinityKey affinity) @trusted
    {
        synchronized (mutex.reader)
        {
            if (auto cached = affinity in affinityCache)
                return (*cached).dup;
            return [];
        }
    }
    
    size_t workerCount() @trusted
    {
        synchronized (mutex.reader)
        {
            size_t count = 0;
            foreach (w; workers)
                if (!w.isBroadcast()) count++;
            return count;
        }
    }
    
    /// Get all active workers
    WorkerId[] allWorkers() @trusted
    {
        synchronized (mutex.reader)
        {
            WorkerId[] result;
            foreach (w; workers)
                if (!w.isBroadcast()) result ~= w;
            return result;
        }
    }
    
    /// Compact worker list (removes tombstones, call during low activity)
    void compact() @trusted
    {
        synchronized (mutex.writer)
        {
            WorkerId[] compacted;
            workerIndices.clear();
            
            foreach (w; workers)
            {
                if (!w.isBroadcast())
                {
                    workerIndices[w] = cast(uint)compacted.length;
                    compacted ~= w;
                }
            }
            
            workers = compacted;
        }
    }
}

/// Helper: Extract affinity key from command/environment
AffinityKey extractAffinity(string command, string[string] env) @safe
{
    import std.string : indexOf;
    import std.algorithm : startsWith;
    
    // Check environment for explicit affinity
    if (auto lang = "BLDR_LANGUAGE" in env)
    {
        auto toolchain = "BLDR_TOOLCHAIN" in env;
        return AffinityKey(*lang, toolchain ? *toolchain : "");
    }
    
    // Infer from command
    if (command.length > 0)
    {
        // Common compiler/toolchain patterns
        if (command.startsWith("dmd") || command.startsWith("ldc2") || command.startsWith("gdc"))
        {
            auto spaceIdx = command.indexOf(' ');
            return AffinityKey("D", command[0 .. spaceIdx > 0 ? spaceIdx : command.length]);
        }
        if (command.startsWith("rustc") || command.startsWith("cargo"))
            return AffinityKey("Rust", "");
        if (command.startsWith("tsc") || command.startsWith("esbuild") || command.startsWith("swc"))
            return AffinityKey("TypeScript", "");
        if (command.startsWith("node") || command.startsWith("npm") || command.startsWith("npx"))
            return AffinityKey("JavaScript", "");
        if (command.startsWith("go "))
            return AffinityKey("Go", "");
        if (command.startsWith("javac") || command.startsWith("java"))
            return AffinityKey("Java", "");
        if (command.startsWith("kotlinc"))
            return AffinityKey("Kotlin", "");
        if (command.startsWith("gcc") || command.startsWith("clang") || command.startsWith("g++") || command.startsWith("clang++"))
            return AffinityKey("Cpp", "");
        if (command.startsWith("python") || command.startsWith("pip"))
            return AffinityKey("Python", "");
        if (command.startsWith("zig"))
            return AffinityKey("Zig", "");
        if (command.startsWith("swift"))
            return AffinityKey("Swift", "");
    }
    
    return AffinityKey("Generic", "");
}

// Unit tests
unittest
{
    // Jump Hash consistency test
    immutable key = 12345678UL;
    immutable bucket5 = JumpHash.hash(key, 5);
    immutable bucket10 = JumpHash.hash(key, 10);
    
    // Key should map to same bucket when scaling up (Jump Hash property)
    assert(bucket5 < 5);
    assert(bucket10 < 10);
    
    // Jump Hash distribution test
    size_t[10] counts;
    foreach (i; 0 .. 10000)
        counts[JumpHash.hash(i, 10)]++;
    
    // Should be roughly uniform (within 20% of expected)
    foreach (c; counts)
        assert(c > 800 && c < 1200, "Poor distribution: " ~ c.to!string);
}

@system unittest
{
    // AffinityKey BLAKE3 hashing test
    auto key1 = AffinityKey("Rust", "rustc-1.75");
    auto key2 = AffinityKey("Rust", "rustc-1.75");
    auto key3 = AffinityKey("D", "dmd");
    
    // Same keys should produce same hash
    assert(key1.toHash() == key2.toHash());
    // Different keys should produce different hashes
    assert(key1.toHash() != key3.toHash());
}

@system unittest
{
    // AffinitySelector basic test
    auto selector = new AffinitySelector();
    
    selector.addWorker(WorkerId(1));
    selector.addWorker(WorkerId(2));
    selector.addWorker(WorkerId(3));
    
    auto affinity = AffinityKey("Rust", "rustc-1.75");
    
    // Should consistently return same worker
    auto result1 = selector.selectWorker(affinity);
    auto result2 = selector.selectWorker(affinity);
    assert(result1.isOk && result2.isOk);
    assert(result1.unwrap() == result2.unwrap());
    
    // Fallbacks should return multiple workers
    auto fallbacks = selector.selectWithFallbacks(affinity, 3);
    assert(fallbacks.length == 3);
}

unittest
{
    // Affinity extraction test
    auto dAffinity = extractAffinity("dmd -O main.d", null);
    assert(dAffinity.language == "D");
    
    auto rustAffinity = extractAffinity("cargo build --release", null);
    assert(rustAffinity.language == "Rust");
    
    string[string] env = ["BLDR_LANGUAGE": "TypeScript", "BLDR_TOOLCHAIN": "tsc-5.0"];
    auto envAffinity = extractAffinity("npm run build", env);
    assert(envAffinity.language == "TypeScript");
    assert(envAffinity.toolchain == "tsc-5.0");
}

