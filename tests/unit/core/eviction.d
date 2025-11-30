module tests.unit.core.eviction;

import std.stdio;
import std.datetime;
import std.algorithm;
import engine.caching.policies.eviction;
import tests.harness;

// Mock cache entry structure for testing
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

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - No evictions needed when under limits");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 100;
    policy.maxSize = 1_000_000;
    policy.maxAge = 30;
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Add a few entries
    entries["target1"] = MockCacheEntry("target1", "hash1", "meta1", 
        ["src1": "h1"], ["dep1": "d1"], now, now);
    entries["target2"] = MockCacheEntry("target2", "hash2", "meta2", 
        ["src2": "h2"], ["dep2": "d2"], now, now);
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    Assert.equal(toEvict.length, 0);
    
    writeln("\x1b[32m  ✓ No evictions when under limits\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Evict entries exceeding max count (LRU)");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 3;
    policy.maxSize = 1_000_000_000;
    policy.maxAge = 0; // Disable age-based eviction
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Add 5 entries with different access times
    entries["target1"] = MockCacheEntry("target1", "hash1", "meta1", 
        null, null, now - 5.hours, now - 5.hours); // Oldest
    entries["target2"] = MockCacheEntry("target2", "hash2", "meta2", 
        null, null, now - 4.hours, now - 4.hours);
    entries["target3"] = MockCacheEntry("target3", "hash3", "meta3", 
        null, null, now - 3.hours, now - 3.hours);
    entries["target4"] = MockCacheEntry("target4", "hash4", "meta4", 
        null, null, now - 2.hours, now - 2.hours);
    entries["target5"] = MockCacheEntry("target5", "hash5", "meta5", 
        null, null, now - 1.hours, now - 1.hours); // Newest
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict 2 oldest entries (5 - 3 = 2)
    Assert.equal(toEvict.length, 2);
    Assert.isTrue(toEvict.canFind("target1"));
    Assert.isTrue(toEvict.canFind("target2"));
    
    writeln("\x1b[32m  ✓ LRU eviction by entry count works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Evict old entries based on age");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 1000;
    policy.maxSize = 1_000_000_000;
    policy.maxAge = 30; // 30 days max
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Add entries with various ages
    entries["recent"] = MockCacheEntry("recent", "hash1", "meta1", 
        null, null, now - 5.days, now);
    entries["old1"] = MockCacheEntry("old1", "hash2", "meta2", 
        null, null, now - 35.days, now - 35.days); // Too old
    entries["old2"] = MockCacheEntry("old2", "hash3", "meta3", 
        null, null, now - 45.days, now - 45.days); // Too old
    entries["borderline"] = MockCacheEntry("borderline", "hash4", "meta4", 
        null, null, now - 29.days, now);
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict the 2 old entries
    Assert.equal(toEvict.length, 2);
    Assert.isTrue(toEvict.canFind("old1"));
    Assert.isTrue(toEvict.canFind("old2"));
    Assert.isFalse(toEvict.canFind("recent"));
    Assert.isFalse(toEvict.canFind("borderline"));
    
    writeln("\x1b[32m  ✓ Age-based eviction works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Calculate total cache size");
    
    auto policy = EvictionPolicy();
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    entries["target1"] = MockCacheEntry("target1", "hash1234567890", "meta1234567890", 
        ["source1": "hash1", "source2": "hash2"], 
        ["dep1": "dhash1"], 
        now, now);
    entries["target2"] = MockCacheEntry("target2", "hash", "meta", 
        null, null, now, now);
    
    auto totalSize = policy.calculateTotalSize(entries);
    
    // Size should be greater than 0
    Assert.isTrue(totalSize > 0);
    
    // Adding more entries should increase size
    entries["target3"] = MockCacheEntry("target3", "hash3", "meta3", 
        ["s1": "h1", "s2": "h2", "s3": "h3"], null, now, now);
    auto newSize = policy.calculateTotalSize(entries);
    Assert.isTrue(newSize > totalSize);
    
    writeln("\x1b[32m  ✓ Cache size calculation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Eviction statistics");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 5;
    policy.maxSize = 500;
    policy.maxAge = 20;
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Add entries to exceed limits
    foreach (i; 0 .. 10)
    {
        import std.conv : to;
        auto key = "target" ~ i.to!string;
        auto age = (i < 3) ? now - 25.days : now - 5.days; // First 3 are expired
        entries[key] = MockCacheEntry(key, "hash", "meta", 
            ["src": "hash"], null, age, age);
    }
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto stats = policy.getStats(entries, currentSize);
    
    Assert.equal(stats.totalEntries, 10);
    Assert.isTrue(stats.totalSize > 0);
    Assert.equal(stats.entriesAboveLimit, 5); // 10 - 5 = 5 over limit
    Assert.equal(stats.expiredEntries, 3); // 3 entries older than 20 days
    
    writeln("\x1b[32m  ✓ Eviction statistics calculation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Size-based eviction (LRU)");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 1000;
    policy.maxSize = 500; // Very small size limit
    policy.maxAge = 0;
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Create entries with large hashes to exceed size limit
    entries["newest"] = MockCacheEntry("newest", "hash123456789012345", "meta123456789012345", 
        ["src1": "hash1234567890", "src2": "hash1234567890"], 
        null, now, now); // Most recent
    
    entries["oldest"] = MockCacheEntry("oldest", "hash123456789012345", "meta123456789012345", 
        ["src1": "hash1234567890", "src2": "hash1234567890"], 
        null, now - 2.hours, now - 2.hours); // Least recent
    
    entries["middle"] = MockCacheEntry("middle", "hash123456789012345", "meta123456789012345", 
        ["src1": "hash1234567890"], 
        null, now - 1.hours, now - 1.hours);
    
    auto currentSize = policy.calculateTotalSize(entries);
    
    // Should exceed size limit
    Assert.isTrue(currentSize > policy.maxSize);
    
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Should evict least recently used entries
    Assert.isTrue(toEvict.length > 0);
    
    // Oldest should be evicted first
    if (toEvict.length >= 1)
        Assert.isTrue(toEvict.canFind("oldest"));
    
    writeln("\x1b[32m  ✓ Size-based LRU eviction works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - Empty cache handling");
    
    auto policy = EvictionPolicy();
    MockCacheEntry[string] emptyEntries;
    
    auto toEvict = policy.selectEvictions(emptyEntries, 0);
    Assert.equal(toEvict.length, 0);
    
    auto totalSize = policy.calculateTotalSize(emptyEntries);
    Assert.equal(totalSize, 0);
    
    auto stats = policy.getStats(emptyEntries, 0);
    Assert.equal(stats.totalEntries, 0);
    Assert.equal(stats.totalSize, 0);
    Assert.equal(stats.expiredEntries, 0);
    
    writeln("\x1b[32m  ✓ Empty cache is handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.eviction - No double eviction of same entry");
    
    auto policy = EvictionPolicy();
    policy.maxEntries = 2;
    policy.maxSize = 300;
    policy.maxAge = 10;
    
    MockCacheEntry[string] entries;
    auto now = Clock.currTime();
    
    // Create entry that violates both age and count limits
    entries["old_and_excess1"] = MockCacheEntry("old_and_excess1", "hash1234567890", "meta1234567890", 
        ["src": "h"], null, now - 15.days, now - 15.days);
    entries["old_and_excess2"] = MockCacheEntry("old_and_excess2", "hash1234567890", "meta1234567890", 
        ["src": "h"], null, now - 12.days, now - 12.days);
    entries["excess3"] = MockCacheEntry("excess3", "hash1234567890", "meta1234567890", 
        ["src": "h"], null, now - 1.days, now - 1.days);
    entries["excess4"] = MockCacheEntry("excess4", "hash1234567890", "meta1234567890", 
        ["src": "h"], null, now, now);
    
    auto currentSize = policy.calculateTotalSize(entries);
    auto toEvict = policy.selectEvictions(entries, currentSize);
    
    // Each entry should appear at most once in eviction list
    import std.array : array;
    import std.algorithm : uniq, sort;
    auto uniqueEvictions = toEvict.dup.sort.uniq.array;
    Assert.equal(toEvict.length, uniqueEvictions.length);
    
    writeln("\x1b[32m  ✓ No double eviction of same entry\x1b[0m");
}

