module engine.caching.policies.eviction;

import std.algorithm;
import std.array;
import std.datetime;
import std.range;

/// LRU cache eviction policy with configurable size limits
/// Uses exact LRU for small caches, clock algorithm (approximate LRU) for large ones
struct EvictionPolicy
{
    // Default configuration constants
    private enum size_t DEFAULT_MAX_SIZE = 1_073_741_824;  // 1 GB
    private enum size_t DEFAULT_MAX_ENTRIES = 10_000;      // 10,000 entries
    private enum size_t DEFAULT_MAX_AGE_DAYS = 30;         // 30 days
    private enum size_t ENTRY_OVERHEAD_BYTES = 100;        // Estimated structure overhead
    private enum size_t CLOCK_THRESHOLD = 50_000;          // Use clock algorithm above this
    
    size_t maxSize = DEFAULT_MAX_SIZE;         // Maximum cache size in bytes
    size_t maxEntries = DEFAULT_MAX_ENTRIES;   // Maximum number of entries
    size_t maxAge = DEFAULT_MAX_AGE_DAYS;      // Maximum age in days
    size_t clockThreshold = CLOCK_THRESHOLD;   // Threshold for approximate LRU
    
    // Clock algorithm state
    private size_t clockHand = 0;
    
    /// Determine which entries to evict
    /// Uses hybrid strategy: LRU + age-based + size-based
    /// For large caches (>clockThreshold), uses O(n) clock algorithm instead of O(n log n) sort
    string[] selectEvictions(T)(T[string] entries, size_t currentSize)
    {
        auto now = Clock.currTime();
        
        // 1. Collect expired entries first (always exact)
        auto toEvict = (maxAge > 0) 
            ? entries.byKeyValue
                .filter!(kv => (now - kv.value.timestamp).total!"days" > maxAge)
                .map!(kv => kv.key)
                .array
            : [];
        
        // Choose algorithm based on cache size
        if (entries.length > clockThreshold)
            selectEvictionsClock(entries, currentSize, toEvict);
        else
            selectEvictionsExact(entries, currentSize, toEvict);
        
        return toEvict;
    }
    
    /// Exact LRU eviction using sort - O(n log n)
    private void selectEvictionsExact(T)(T[string] entries, size_t currentSize, ref string[] toEvict)
    {
        auto sorted = entries.byKeyValue.array.sort!((a, b) => a.value.lastAccess < b.value.lastAccess);
        
        // Add entries if count exceeds limit
        if (entries.length > maxEntries)
        {
            toEvict ~= sorted[0 .. entries.length - maxEntries]
                .filter!(kv => !toEvict.canFind(kv.key))
                .map!(kv => kv.key)
                .array;
        }
        
        // Add entries if size exceeds limit
        if (maxSize > 0 && currentSize > maxSize)
        {
            size_t removed = 0;
            foreach (kv; sorted)
            {
                if (currentSize - removed <= maxSize) break;
                if (toEvict.canFind(kv.key)) continue;
                toEvict ~= kv.key;
                removed += estimateEntrySize(kv.value);
            }
        }
    }
    
    /// Approximate LRU using clock algorithm - O(n) worst case
    /// Uses lastAccess timestamp as implicit reference bit (accessed in last hour = referenced)
    private void selectEvictionsClock(T)(T[string] entries, size_t currentSize, ref string[] toEvict)
    {
        auto keys = entries.keys;
        if (keys.length == 0) return;
        
        size_t entriesToEvict = entries.length > maxEntries ? entries.length - maxEntries : 0;
        size_t sizeToFree = (maxSize > 0 && currentSize > maxSize) ? currentSize - maxSize : 0;
        if (entriesToEvict == 0 && sizeToFree == 0) return;
        
        auto now = Clock.currTime();
        auto recentThreshold = dur!"hours"(1);  // Consider "recently accessed" within 1 hour
        
        size_t evicted = 0, sizeFreed = 0;
        size_t maxSweeps = keys.length * 2;  // Max 2 full rotations
        
        for (size_t sweeps = 0; sweeps < maxSweeps && (evicted < entriesToEvict || sizeFreed < sizeToFree); sweeps++)
        {
            clockHand = clockHand % keys.length;
            auto key = keys[clockHand];
            
            if (!toEvict.canFind(key))
            {
                auto entry = entries[key];
                bool recentlyAccessed = (now - entry.lastAccess) < recentThreshold;
                
                if (recentlyAccessed && sweeps < keys.length)
                {
                    // First pass: skip recently accessed (they get a second chance)
                    // On second pass, evict regardless
                }
                else
                {
                    toEvict ~= key;
                    evicted++;
                    sizeFreed += estimateEntrySize(entry);
                }
            }
            clockHand++;
        }
    }
    
    /// Estimate the size of a cache entry in bytes
    size_t estimateEntrySize(T)(auto ref const T entry) const pure @nogc
    {
        size_t size = 0;
        
        // Fixed overhead
        size += ENTRY_OVERHEAD_BYTES;
        
        // Check if this is an ActionEntry (has actionId) or CacheEntry (has targetId)
        static if (__traits(hasMember, T, "actionId"))
        {
            // ActionEntry
            size += entry.actionId.targetId.length;
            size += entry.actionId.inputHash.length;
            size += entry.actionId.subId.length;
            size += entry.executionHash.length;
            
            foreach (input; entry.inputs)
                size += input.length;
            
            foreach (output; entry.outputs)
                size += output.length;
            
            foreach (key, value; entry.inputHashes)
                size += key.length + value.length;
            
            foreach (key, value; entry.outputHashes)
                size += key.length + value.length;
            
            foreach (key, value; entry.metadata)
                size += key.length + value.length;
        }
        else
        {
            // TestCacheEntry or other entry type
            static if (__traits(hasMember, T, "targetId"))
            {
                size += entry.targetId.length;
                size += entry.buildHash.length;
                size += entry.metadataHash.length;
                
                foreach (source, hash; entry.sourceHashes)
                    size += source.length + hash.length;
                
                foreach (dep, hash; entry.depHashes)
                    size += dep.length + hash.length;
            }
            else static if (__traits(hasMember, T, "testId"))
            {
                // TestCacheEntry
                size += entry.testId.length;
                size += entry.contentHash.length;
                size += entry.envHash.length;
            }
            else
            {
                // Unknown entry type, estimate based on result
                size += 256;  // Reasonable default
            }
        }
        
        return size;
    }
    
    /// Calculate total cache size
    size_t calculateTotalSize(T)(const T[string] entries) const pure
    {
        return entries.byValue.map!(e => estimateEntrySize(e)).sum;
    }
    
    /// Get eviction statistics
    struct EvictionStats
    {
        size_t totalEntries;
        size_t totalSize;
        size_t entriesAboveLimit;
        size_t sizeAboveLimit;
        size_t expiredEntries;
    }
    
    EvictionStats getStats(T)(T[string] entries, size_t currentSize)
    {
        EvictionStats stats;
        stats.totalEntries = entries.length;
        stats.totalSize = currentSize;
        stats.entriesAboveLimit = entries.length > maxEntries ? entries.length - maxEntries : 0;
        stats.sizeAboveLimit = currentSize > maxSize ? currentSize - maxSize : 0;
        
        if (maxAge > 0)
        {
            auto now = Clock.currTime();
            stats.expiredEntries = entries.values
                .count!(e => (now - e.timestamp).total!"days" > maxAge);
        }
        
        return stats;
    }
}

