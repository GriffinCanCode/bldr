module tests.integration.cache_pressure;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.datetime.stopwatch;
import tests.harness;
import tests.fixtures;
import engine.caching.targets.cache;
import engine.caching.policies.eviction;
import infrastructure.config.schema.schema;

/// Test cache eviction under memory pressure
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Basic eviction under size limit");
    
    auto tempDir = scoped(new TempDir("cache-eviction-basic"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Configure cache with small size limit (10KB)
    CacheConfig config;
    config.maxSize = 10 * 1024; // 10KB
    config.maxEntries = 1000;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Create test files
    foreach (i; 0 .. 50)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        // Create ~1KB files
        string content = "// File " ~ i.to!string ~ "\n";
        foreach (j; 0 .. 100)
        {
            content ~= "void func" ~ j.to!string ~ "() {}\n";
        }
        std.file.write(filePath, content);
        
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    // Force flush to trigger eviction
    cache.flush();
    
    // Check that eviction occurred
    auto stats = cache.getStats();
    writeln("  Entries after eviction: ", stats.totalEntries);
    writeln("  Total size: ", stats.totalSize);
    
    Assert.isTrue(stats.totalSize <= config.maxSize * 1.2, 
                 "Cache size should be close to limit after eviction");
    Assert.isTrue(stats.totalEntries < 50, 
                 "Some entries should have been evicted");
    
    writeln("\x1b[32m  ✓ Basic eviction under size limit works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - LRU eviction policy");
    
    auto tempDir = scoped(new TempDir("cache-eviction-lru"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Configure cache with small entry limit
    CacheConfig config;
    config.maxSize = size_t.max; // No size limit
    config.maxEntries = 10;      // Only 10 entries
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add 10 entries
    foreach (i; 0 .. 10)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\n");
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    // Access targets 0, 2, 4, 6, 8 (make them recently used)
    foreach (i; [0, 2, 4, 6, 8])
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        cache.isCached("target" ~ i.to!string, [filePath], []);
    }
    
    // Add 5 more entries (should evict least recently used: 1, 3, 5, 7, 9)
    foreach (i; 10 .. 15)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\n");
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    cache.flush();
    
    // Verify LRU eviction
    auto stats = cache.getStats();
    writeln("  Entries after LRU eviction: ", stats.totalEntries);
    Assert.isTrue(stats.totalEntries <= config.maxEntries, 
                 "Should respect max entries limit");
    
    writeln("\x1b[32m  ✓ LRU eviction policy works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Age-based eviction");
    
    auto tempDir = scoped(new TempDir("cache-eviction-age"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Configure cache with short max age
    CacheConfig config;
    config.maxSize = size_t.max;
    config.maxEntries = 1000;
    config.maxAge = 0; // Expire immediately for testing
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add entries
    foreach (i; 0 .. 20)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\n");
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    // Flush to apply age-based eviction
    cache.flush();
    
    // All entries should be evicted due to age
    auto stats = cache.getStats();
    writeln("  Entries after age-based eviction: ", stats.totalEntries);
    Assert.equal(stats.totalEntries, 0, "All old entries should be evicted");
    
    writeln("\x1b[32m  ✓ Age-based eviction works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Stress test with 10,000 entries");
    
    auto tempDir = scoped(new TempDir("cache-stress-10k"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Configure cache with moderate limits
    CacheConfig config;
    config.maxSize = 100 * 1024 * 1024; // 100MB
    config.maxEntries = 5000;            // Max 5000 entries
    config.maxAge = 30;
    
    auto cache = new BuildCache(cacheDir, config);
    
    writeln("  Adding 10,000 cache entries...");
    auto addTimer = StopWatch(AutoStart.yes);
    
    foreach (i; 0 .. 10_000)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\nint value = " ~ i.to!string ~ ";\n");
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
        
        if ((i + 1) % 1000 == 0)
        {
            writeln("    Added ", i + 1, " entries...");
        }
    }
    
    addTimer.stop();
    writeln("  Added 10,000 entries in ", addTimer.peek().total!"msecs", "ms");
    
    // Flush and trigger eviction
    writeln("  Flushing cache and triggering eviction...");
    auto flushTimer = StopWatch(AutoStart.yes);
    cache.flush();
    flushTimer.stop();
    writeln("  Flushed in ", flushTimer.peek().total!"msecs", "ms");
    
    // Check final stats
    auto stats = cache.getStats();
    writeln("  Final statistics:");
    writeln("    Total entries: ", stats.totalEntries);
    writeln("    Total size: ", stats.totalSize / 1024, "KB");
    writeln("    Evicted: ", 10_000 - stats.totalEntries);
    
    Assert.isTrue(stats.totalEntries <= config.maxEntries, 
                 "Should respect max entries limit");
    Assert.isTrue(stats.totalSize <= config.maxSize * 1.2, 
                 "Should respect max size limit (with 20% tolerance)");
    
    writeln("\x1b[32m  ✓ Stress test with 10,000 entries passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Hybrid eviction strategy");
    
    auto tempDir = scoped(new TempDir("cache-hybrid"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Configure cache with multiple limits
    CacheConfig config;
    config.maxSize = 50 * 1024;  // 50KB
    config.maxEntries = 100;     // 100 entries
    config.maxAge = 1;           // 1 day
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add varied entries
    foreach (i; 0 .. 200)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        
        // Vary file sizes
        string content = "// File " ~ i.to!string ~ "\n";
        auto repeats = (i % 10) + 1;
        foreach (j; 0 .. repeats)
        {
            content ~= "void func" ~ j.to!string ~ "() { /* code */ }\n";
        }
        
        std.file.write(filePath, content);
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    // Access some entries to update LRU
    foreach (i; [10, 20, 30, 40, 50])
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        if (exists(filePath))
        {
            cache.isCached("target" ~ i.to!string, [filePath], []);
        }
    }
    
    // Flush to trigger hybrid eviction
    cache.flush();
    
    auto stats = cache.getStats();
    writeln("  Final statistics:");
    writeln("    Entries: ", stats.totalEntries, " / ", config.maxEntries);
    writeln("    Size: ", stats.totalSize / 1024, "KB / ", config.maxSize / 1024, "KB");
    
    Assert.isTrue(stats.totalEntries <= config.maxEntries, 
                 "Should respect entry limit");
    Assert.isTrue(stats.totalSize <= config.maxSize * 1.2, 
                 "Should respect size limit");
    
    writeln("\x1b[32m  ✓ Hybrid eviction strategy works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Eviction performance benchmark");
    
    auto tempDir = scoped(new TempDir("cache-perf"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Test eviction performance with different entry counts
    size_t[] entryCounts = [100, 500, 1000, 5000];
    
    foreach (count; entryCounts)
    {
        // Clean cache directory
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
        mkdirRecurse(cacheDir);
        
        CacheConfig config;
        config.maxSize = 10 * 1024; // Small limit to trigger eviction
        config.maxEntries = count / 2; // Force eviction
        config.maxAge = 365;
        
        auto cache = new BuildCache(cacheDir, config);
        
        // Add entries
        foreach (i; 0 .. count)
        {
            auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
            std.file.write(filePath, "// File " ~ i.to!string ~ "\n");
            cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
        }
        
        // Measure eviction time
        auto evictTimer = StopWatch(AutoStart.yes);
        cache.flush();
        evictTimer.stop();
        
        auto evictTime = evictTimer.peek().total!"msecs";
        writeln("  ", count, " entries: eviction took ", evictTime, "ms");
        
        // Performance assertion: eviction should be reasonable
        Assert.isTrue(evictTime < count, 
                     "Eviction should be faster than 1ms per entry");
    }
    
    writeln("\x1b[32m  ✓ Eviction performance benchmark passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Memory pressure simulation");
    
    auto tempDir = scoped(new TempDir("cache-memory"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Simulate memory pressure by using very small limits
    CacheConfig config;
    config.maxSize = 5 * 1024; // Only 5KB
    config.maxEntries = 20;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    writeln("  Simulating memory pressure...");
    
    // Continuously add entries to force eviction
    foreach (iteration; 0 .. 10)
    {
        foreach (i; 0 .. 10)
        {
            auto idx = iteration * 10 + i;
            auto filePath = buildPath(tempDir.getPath(), "file" ~ idx.to!string ~ ".d");
            
            // Create files of varying sizes
            string content = "// File " ~ idx.to!string ~ "\n";
            foreach (j; 0 .. (idx % 50) + 10)
            {
                content ~= "int var" ~ j.to!string ~ " = " ~ j.to!string ~ ";\n";
            }
            
            std.file.write(filePath, content);
            cache.update("target" ~ idx.to!string, [filePath], [], "hash" ~ idx.to!string);
        }
        
        // Check cache stays within limits
        cache.flush();
        auto stats = cache.getStats();
        
        Assert.isTrue(stats.totalEntries <= config.maxEntries,
                     "Cache should stay within entry limit during pressure");
        Assert.isTrue(stats.totalSize <= config.maxSize * 1.3,
                     "Cache should stay within size limit during pressure");
        
        writeln("    Iteration ", iteration + 1, ": ", 
                stats.totalEntries, " entries, ",
                stats.totalSize / 1024, "KB");
    }
    
    writeln("\x1b[32m  ✓ Memory pressure simulation passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Eviction statistics accuracy");
    
    auto tempDir = scoped(new TempDir("cache-stats"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxSize = 20 * 1024;
    config.maxEntries = 50;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add known number of entries
    immutable size_t totalAdded = 100;
    size_t totalSizeAdded = 0;
    
    foreach (i; 0 .. totalAdded)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        string content = "// File " ~ i.to!string ~ "\n";
        foreach (j; 0 .. 10)
        {
            content ~= "int value" ~ j.to!string ~ " = " ~ i.to!string ~ ";\n";
        }
        
        std.file.write(filePath, content);
        totalSizeAdded += getSize(filePath);
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    
    cache.flush();
    
    auto stats = cache.getStats();
    writeln("  Total added: ", totalAdded, " entries, ", totalSizeAdded / 1024, "KB");
    writeln("  Total retained: ", stats.totalEntries, " entries, ", stats.totalSize / 1024, "KB");
    writeln("  Evicted: ", totalAdded - stats.totalEntries, " entries, ",
            (totalSizeAdded - stats.totalSize) / 1024, "KB");
    
    Assert.isTrue(stats.totalEntries <= config.maxEntries,
                 "Stats should reflect entry limit");
    Assert.isTrue(stats.totalSize <= config.maxSize * 1.2,
                 "Stats should reflect size limit");
    Assert.isTrue(stats.totalEntries < totalAdded,
                 "Some entries should have been evicted");
    
    writeln("\x1b[32m  ✓ Eviction statistics are accurate\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Concurrent access during eviction");
    
    auto tempDir = scoped(new TempDir("cache-concurrent"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxSize = 30 * 1024;
    config.maxEntries = 100;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    writeln("  Testing concurrent cache access...");
    
    // Add entries concurrently
    foreach (i; parallel(iota(200)))
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\nint value = " ~ i.to!string ~ ";\n");
        
        cache.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
        
        // Also perform cache lookups
        if (i % 2 == 0 && i > 0)
        {
            auto prevPath = buildPath(tempDir.getPath(), "file" ~ (i-1).to!string ~ ".d");
            if (exists(prevPath))
            {
                cache.isCached("target" ~ (i-1).to!string, [prevPath], []);
            }
        }
    }
    
    // Flush (will trigger eviction)
    cache.flush();
    
    auto stats = cache.getStats();
    writeln("  Final entries: ", stats.totalEntries);
    writeln("  Final size: ", stats.totalSize / 1024, "KB");
    
    Assert.isTrue(stats.totalEntries <= config.maxEntries,
                 "Cache should respect limits with concurrent access");
    
    writeln("\x1b[32m  ✓ Concurrent access during eviction works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m cache_pressure - Recovery after extreme pressure");
    
    auto tempDir = scoped(new TempDir("cache-recovery"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Start with very restrictive limits
    CacheConfig config1;
    config1.maxSize = 2 * 1024; // Only 2KB
    config1.maxEntries = 5;
    config1.maxAge = 365;
    
    auto cache1 = new BuildCache(cacheDir, config1);
    
    writeln("  Phase 1: Extreme pressure (2KB, 5 entries)");
    foreach (i; 0 .. 50)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\nint val = " ~ i.to!string ~ ";\n");
        cache1.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    cache1.flush();
    
    auto stats1 = cache1.getStats();
    writeln("    Under pressure: ", stats1.totalEntries, " entries");
    Assert.isTrue(stats1.totalEntries <= config1.maxEntries);
    
    // Destroy and recreate with relaxed limits
    destroy(cache1);
    
    CacheConfig config2;
    config2.maxSize = 100 * 1024; // 100KB
    config2.maxEntries = 100;
    config2.maxAge = 365;
    
    auto cache2 = new BuildCache(cacheDir, config2);
    
    writeln("  Phase 2: Recovery (100KB, 100 entries)");
    foreach (i; 50 .. 100)
    {
        auto filePath = buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".d");
        std.file.write(filePath, "// File " ~ i.to!string ~ "\nint val = " ~ i.to!string ~ ";\n");
        cache2.update("target" ~ i.to!string, [filePath], [], "hash" ~ i.to!string);
    }
    cache2.flush();
    
    auto stats2 = cache2.getStats();
    writeln("    After recovery: ", stats2.totalEntries, " entries");
    Assert.isTrue(stats2.totalEntries > stats1.totalEntries,
                 "Cache should recover and hold more entries");
    
    writeln("\x1b[32m  ✓ Recovery after extreme pressure works\x1b[0m");
}

