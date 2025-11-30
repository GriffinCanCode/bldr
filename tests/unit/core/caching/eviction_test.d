module tests.unit.core.caching.eviction_test;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.algorithm;
import std.array;
import core.time;
import core.thread;
import engine.caching.policies.eviction;
import engine.caching.targets.cache;
import engine.caching.actions.action;
import tests.harness;
import tests.fixtures;

// Helper to create mock cache entries
struct MockCacheEntry
{
    string targetId;
    string buildHash;
    string metadataHash;
    string[string] sourceHashes;
    string[string] depHashes;
    SysTime timestamp;
    SysTime lastAccess;
}

// ==================== EVICTION POLICY BASIC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - No eviction when under limits");
    
    EvictionPolicy policy;
    policy.maxEntries = 100;
    policy.maxSize = 1_000_000;
    policy.maxAge = 30;
    
    MockCacheEntry[string] entries;
    
    // Add a few entries (well under limits)
    foreach (i; 0 .. 5)
    {
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(toEvict.length, 0, "Should not evict when under limits");
    
    writeln("\x1b[32m  ✓ No eviction under limits\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Evict oldest entries when over max entries");
    
    EvictionPolicy policy;
    policy.maxEntries = 3;
    policy.maxSize = 0;  // Disable size limit
    policy.maxAge = 365; // Disable age limit
    
    MockCacheEntry[string] entries;
    
    // Add 5 entries (over limit of 3)
    foreach (i; 0 .. 5)
    {
        Thread.sleep(1.msecs);  // Ensure different timestamps
        
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict 2 entries (5 - 3 = 2)
    Assert.equal(toEvict.length, 2, "Should evict excess entries");
    
    writeln("\x1b[32m  ✓ Evict oldest entries when over limit\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Age-based eviction");
    
    EvictionPolicy policy;
    policy.maxEntries = 100;
    policy.maxSize = 0;
    policy.maxAge = 1;  // 1 day max age
    
    MockCacheEntry[string] entries;
    
    // Add old entry (2 days old)
    auto oldTime = Clock.currTime() - dur!"days"(2);
    
    MockCacheEntry oldEntry;
    oldEntry.targetId = "old-target";
    oldEntry.buildHash = "old-hash";
    oldEntry.timestamp = oldTime;
    oldEntry.lastAccess = oldTime;
    entries["old-key"] = oldEntry;
    
    // Add fresh entry
    MockCacheEntry freshEntry;
    freshEntry.targetId = "fresh-target";
    freshEntry.buildHash = "fresh-hash";
    freshEntry.timestamp = Clock.currTime();
    freshEntry.lastAccess = Clock.currTime();
    entries["fresh-key"] = freshEntry;
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(toEvict.length, 1, "Should evict 1 old entry");
    Assert.isTrue(toEvict.canFind("old-key"), "Should evict the old entry");
    
    writeln("\x1b[32m  ✓ Age-based eviction works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - LRU eviction preserves recently accessed");
    
    EvictionPolicy policy;
    policy.maxEntries = 3;
    policy.maxSize = 0;
    policy.maxAge = 365;
    
    MockCacheEntry[string] entries;
    
    // Add 4 entries
    foreach (i; 0 .. 4)
    {
        Thread.sleep(2.msecs);
        
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        entries["key" ~ i.to!string] = entry;
    }
    
    // Access first entry again (make it most recent)
    Thread.sleep(5.msecs);
    entries["key0"].lastAccess = Clock.currTime();
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(toEvict.length, 1, "Should evict 1 entry");
    Assert.isFalse(toEvict.canFind("key0"), "Should not evict recently accessed entry");
    
    writeln("\x1b[32m  ✓ LRU preserves recently accessed entries\x1b[0m");
}

// ==================== SIZE-BASED EVICTION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Size-based eviction");
    
    EvictionPolicy policy;
    policy.maxEntries = 100;
    policy.maxSize = 5000;  // Small size limit
    policy.maxAge = 365;
    
    MockCacheEntry[string] entries;
    
    // Add entries that will exceed size limit
    foreach (i; 0 .. 10)
    {
        Thread.sleep(1.msecs);
        
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string ~ "_very_long_hash_to_increase_size";
        entry.metadataHash = "meta" ~ i.to!string ~ "_also_long";
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        // Add some source hashes to increase size
        foreach (j; 0 .. 5)
        {
            entry.sourceHashes["source" ~ j.to!string] = "sourcehash" ~ j.to!string;
        }
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    if (currentSize > policy.maxSize)
    {
        Assert.isTrue(toEvict.length > 0, "Should evict entries when over size limit");
        
        writeln("\x1b[32m  ✓ Size-based eviction works (evicted ", 
                toEvict.length, " entries)\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ⊘ Size limit not exceeded in test\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Calculate total size accuracy");
    
    EvictionPolicy policy;
    
    MockCacheEntry[string] entries;
    
    // Add known-size entries
    foreach (i; 0 .. 5)
    {
        MockCacheEntry entry;
        entry.targetId = "id";  // 2 bytes
        entry.buildHash = "hash";  // 4 bytes
        entry.metadataHash = "meta";  // 4 bytes
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto totalSize = policy.calculateTotalSize(entries);
    
    // Each entry should have overhead + string sizes
    Assert.isTrue(totalSize > 0, "Total size should be positive");
    Assert.isTrue(totalSize > entries.length * 10, "Size should include strings");
    
    writeln("\x1b[32m  ✓ Total size calculation works (", 
            totalSize, " bytes for ", entries.length, " entries)\x1b[0m");
}

// ==================== HYBRID EVICTION STRATEGIES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Hybrid: age + count limits");
    
    EvictionPolicy policy;
    policy.maxEntries = 5;
    policy.maxSize = 0;
    policy.maxAge = 2;  // 2 days
    
    MockCacheEntry[string] entries;
    
    // Add 3 old entries (should be evicted by age)
    auto oldTime = Clock.currTime() - dur!"days"(3);
    foreach (i; 0 .. 3)
    {
        MockCacheEntry entry;
        entry.targetId = "old" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = oldTime;
        entry.lastAccess = oldTime;
        
        entries["old" ~ i.to!string] = entry;
    }
    
    // Add 4 fresh entries (would exceed count limit)
    foreach (i; 0 .. 4)
    {
        Thread.sleep(1.msecs);
        
        MockCacheEntry entry;
        entry.targetId = "fresh" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        entries["fresh" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict all 3 old entries
    Assert.isTrue(toEvict.length >= 3, "Should evict at least old entries");
    
    // Check that old entries are in eviction list
    size_t oldEvicted = 0;
    foreach (key; toEvict)
    {
        if (key.startsWith("old"))
            oldEvicted++;
    }
    
    Assert.equal(oldEvicted, 3, "All old entries should be evicted");
    
    writeln("\x1b[32m  ✓ Hybrid age + count eviction works\x1b[0m");
}

// ==================== EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Empty cache");
    
    EvictionPolicy policy;
    policy.maxEntries = 10;
    policy.maxSize = 1000;
    policy.maxAge = 30;
    
    MockCacheEntry[string] entries;  // Empty
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(currentSize, 0);
    Assert.equal(toEvict.length, 0);
    
    writeln("\x1b[32m  ✓ Empty cache handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Single entry eviction");
    
    EvictionPolicy policy;
    policy.maxEntries = 0;  // Force eviction
    policy.maxSize = 0;
    policy.maxAge = 365;
    
    MockCacheEntry[string] entries;
    
    MockCacheEntry entry;
    entry.targetId = "single";
    entry.buildHash = "hash";
    entry.timestamp = Clock.currTime();
    entry.lastAccess = Clock.currTime();
    
    entries["single"] = entry;
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(toEvict.length, 1, "Should evict the single entry");
    Assert.equal(toEvict[0], "single");
    
    writeln("\x1b[32m  ✓ Single entry eviction works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - All entries same timestamp");
    
    EvictionPolicy policy;
    policy.maxEntries = 2;
    policy.maxSize = 0;
    policy.maxAge = 365;
    
    MockCacheEntry[string] entries;
    
    auto sameTime = Clock.currTime();
    
    // Add 4 entries with identical timestamps
    foreach (i; 0 .. 4)
    {
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = sameTime;
        entry.lastAccess = sameTime;
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict 2 entries (4 - 2 = 2)
    Assert.equal(toEvict.length, 2, "Should evict excess entries");
    
    writeln("\x1b[32m  ✓ Eviction with same timestamps handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Zero age limit disables age eviction");
    
    EvictionPolicy policy;
    policy.maxEntries = 100;
    policy.maxSize = 0;
    policy.maxAge = 0;  // Disabled
    
    MockCacheEntry[string] entries;
    
    // Add very old entry
    auto ancientTime = Clock.currTime() - dur!"days"(1000);
    
    MockCacheEntry entry;
    entry.targetId = "ancient";
    entry.buildHash = "hash";
    entry.timestamp = ancientTime;
    entry.lastAccess = ancientTime;
    
    entries["ancient"] = entry;
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // With age limit disabled, even ancient entries shouldn't be evicted
    // unless other limits are exceeded
    Assert.equal(toEvict.length, 0, "Should not evict when age limit is 0");
    
    writeln("\x1b[32m  ✓ Disabled age limit (0) works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Very large entry count");
    
    EvictionPolicy policy;
    policy.maxEntries = 500;
    policy.maxSize = 0;
    policy.maxAge = 365;
    
    MockCacheEntry[string] entries;
    
    // Add 1000 entries
    foreach (i; 0 .. 1000)
    {
        MockCacheEntry entry;
        entry.targetId = "target" ~ i.to!string;
        entry.buildHash = "hash" ~ i.to!string;
        entry.timestamp = Clock.currTime();
        entry.lastAccess = Clock.currTime();
        
        entries["key" ~ i.to!string] = entry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict 500 entries (1000 - 500)
    Assert.equal(toEvict.length, 500, "Should evict correct number");
    
    writeln("\x1b[32m  ✓ Large entry count eviction works\x1b[0m");
}

// ==================== EVICTION STATISTICS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Eviction statistics");
    
    EvictionPolicy policy;
    policy.maxEntries = 5;
    policy.maxSize = 10000;
    policy.maxAge = 7;
    
    MockCacheEntry[string] entries;
    
    // Add mix of old and new entries
    auto oldTime = Clock.currTime() - dur!"days"(10);
    
    foreach (i; 0 .. 3)
    {
        MockCacheEntry oldEntry;
        oldEntry.targetId = "old" ~ i.to!string;
        oldEntry.buildHash = "hash";
        oldEntry.timestamp = oldTime;
        oldEntry.lastAccess = oldTime;
        
        entries["old" ~ i.to!string] = oldEntry;
    }
    
    foreach (i; 0 .. 4)
    {
        MockCacheEntry newEntry;
        newEntry.targetId = "new" ~ i.to!string;
        newEntry.buildHash = "hash";
        newEntry.timestamp = Clock.currTime();
        newEntry.lastAccess = Clock.currTime();
        
        entries["new" ~ i.to!string] = newEntry;
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto stats = policy.getStats(entries, currentSize);
    
    Assert.equal(stats.totalEntries, 7);
    Assert.equal(stats.totalSize, currentSize);
    Assert.equal(stats.expiredEntries, 3, "Should detect 3 expired entries");
    
    if (entries.length > policy.maxEntries)
    {
        Assert.equal(stats.entriesAboveLimit, 
                     entries.length - policy.maxEntries,
                     "Should calculate entries above limit");
    }
    
    writeln("\x1b[32m  ✓ Eviction statistics accurate\x1b[0m");
}

// ==================== INTEGRATION WITH REAL CACHES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Integration with BuildCache");
    
    auto tempDir = scoped(new TempDir("eviction-integration"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxEntries = 3;
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add 5 entries (exceeds limit)
    foreach (i; 0 .. 5)
    {
        auto filename = "file" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void func() {}");
        auto path = buildPath(tempDir.getPath(), filename);
        
        cache.update("target" ~ i.to!string, [path], [], "hash" ~ i.to!string);
    }
    
    // Force flush (triggers eviction)
    cache.flush();
    
    auto stats = cache.getStats();
    
    // Should have evicted down to limit
    Assert.isTrue(stats.totalEntries <= config.maxEntries,
                  "Cache should respect max entries after eviction");
    
    cache.close();
    writeln("\x1b[32m  ✓ Eviction integration with BuildCache works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m EvictionPolicy - Integration with ActionCache");
    
    auto tempDir = scoped(new TempDir("eviction-action-integration"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    ActionCacheConfig config;
    config.maxEntries = 4;
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new ActionCache(cacheDir, config);
    
    // Add 6 actions
    foreach (i; 0 .. 6)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "int x = " ~ i.to!string ~ ";");
        auto path = buildPath(tempDir.getPath(), filename);
        
        ActionId actionId;
        actionId.targetId = "target";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        actionId.subId = filename;
        
        cache.update(actionId, [path], [], null, true);
    }
    
    // Force flush
    cache.flush();
    
    auto stats = cache.getStats();
    
    Assert.isTrue(stats.totalEntries <= config.maxEntries,
                  "Action cache should respect max entries");
    
    cache.close();
    writeln("\x1b[32m  ✓ Eviction integration with ActionCache works\x1b[0m");
}

