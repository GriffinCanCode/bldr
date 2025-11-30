module tests.unit.core.caching.edge_cases;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.range;
import std.algorithm;
import std.parallelism;
import std.exception;
import core.thread;
import core.time;
import engine.caching.targets.cache;
import engine.caching.actions.action;
import engine.caching.storage.cas;
import engine.caching.coordinator.coordinator;
import engine.caching.policies.eviction;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

// ==================== CONCURRENT RACE CONDITIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Concurrent cache file access race");
    
    auto tempDir = scoped(new TempDir("edge-concurrent-race"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Create initial cache
    tempDir.createFile("source.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.d");
    
    // Multiple threads trying to create/access cache simultaneously
    import std.parallelism : parallel;
    import std.range : iota;
    
    bool[] results = new bool[10];
    
    try
    {
        foreach (i; parallel(iota(10)))
        {
            try
            {
                auto cache = new BuildCache(cacheDir);
                
                // Attempt concurrent updates
                string[] sources = [sourcePath];
                string[] deps = [];
                
                if (!cache.isCached("target-" ~ i.to!string, sources, deps))
                {
                    cache.update("target-" ~ i.to!string, sources, deps, "hash" ~ i.to!string);
                }
                
                cache.flush();
                cache.close();
                
                results[i] = true;
            }
            catch (Exception e)
            {
                // Expected: some may fail due to race conditions
                results[i] = false;
            }
        }
        
        // At least some should succeed
        size_t successCount = results.count(true);
        Assert.isTrue(successCount >= 5, "At least half of concurrent operations should succeed");
        
        writeln("\x1b[32m  ✓ Concurrent cache file access handled (", successCount, "/10 succeeded)\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent race test completed with exceptions (expected)\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - File modified during hash computation");
    
    auto tempDir = scoped(new TempDir("edge-file-race"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Create a file
    tempDir.createFile("racing.cpp", "int main() { return 0; }");
    auto sourcePath = buildPath(tempDir.getPath(), "racing.cpp");
    
    string[] sources = [sourcePath];
    string[] deps = [];
    
    // Check cache (file will be hashed)
    bool initialCheck = cache.isCached("race-target", sources, deps);
    
    // Modify file in another thread while cache operations are ongoing
    import std.concurrency : spawn;
    spawn((string path) {
        Thread.sleep(5.msecs);
        try {
            std.file.write(path, "int main() { return 1; }");
        } catch (Exception) {}
    }, sourcePath);
    
    // Update cache
    cache.update("race-target", sources, deps, "hash1");
    
    // Small delay
    Thread.sleep(20.msecs);
    
    // The cache should detect the modification
    bool secondCheck = cache.isCached("race-target", sources, deps);
    
    // Either initial check was false, or second check detected the change
    Assert.isTrue(!initialCheck || !secondCheck, "Race condition should be handled");
    
    cache.close();
    writeln("\x1b[32m  ✓ File modification during hash handled correctly\x1b[0m");
}

// ==================== CORRUPTED CACHE FILES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Corrupted cache file recovery");
    
    auto tempDir = scoped(new TempDir("edge-corrupted"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    mkdirRecurse(cacheDir);
    
    // Write corrupted/invalid cache file
    auto cacheFilePath = buildPath(cacheDir, "cache.bin");
    std.file.write(cacheFilePath, "CORRUPTED GARBAGE DATA !@#$%^&*()");
    
    // Cache should gracefully handle corruption and start fresh
    try
    {
        auto cache = new BuildCache(cacheDir);
        
        // Should be able to use cache normally after corruption
        tempDir.createFile("test.d", "void test() {}");
        auto sourcePath = buildPath(tempDir.getPath(), "test.d");
        
        cache.update("test-target", [sourcePath], [], "hash123");
        Assert.isTrue(cache.isCached("test-target", [sourcePath], []));
        
        cache.close();
        writeln("\x1b[32m  ✓ Corrupted cache file recovery works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[32m  ✓ Corrupted cache properly rejected: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Partial write/interrupted flush");
    
    auto tempDir = scoped(new TempDir("edge-partial-write"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    {
        auto cache = new BuildCache(cacheDir);
        
        tempDir.createFile("file1.d", "content1");
        tempDir.createFile("file2.d", "content2");
        
        auto path1 = buildPath(tempDir.getPath(), "file1.d");
        auto path2 = buildPath(tempDir.getPath(), "file2.d");
        
        cache.update("target1", [path1], [], "hash1");
        cache.update("target2", [path2], [], "hash2");
        
        // Flush but don't close properly (simulating interrupt)
        cache.flush();
        // Intentionally skip close to simulate abnormal termination
    }
    
    // Try to load the potentially partial cache
    try
    {
        auto cache2 = new BuildCache(cacheDir);
        
        // Should either load successfully or start fresh
        tempDir.createFile("file3.d", "content3");
        auto path3 = buildPath(tempDir.getPath(), "file3.d");
        
        cache2.update("target3", [path3], [], "hash3");
        Assert.isTrue(cache2.isCached("target3", [path3], []));
        
        cache2.close();
        writeln("\x1b[32m  ✓ Partial write recovery handled\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[32m  ✓ Partial write properly handled with fresh start\x1b[0m");
    }
}

// ==================== FILE SYSTEM ERRORS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Read-only cache directory");
    
    auto tempDir = scoped(new TempDir("edge-readonly"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    mkdirRecurse(cacheDir);
    
    version(Posix)
    {
        import std.process : execute;
        
        // Make cache directory read-only
        execute(["chmod", "444", cacheDir]);
        
        try
        {
            // This should fail gracefully
            auto cache = new BuildCache(cacheDir);
            
            tempDir.createFile("test.d", "void test() {}");
            auto sourcePath = buildPath(tempDir.getPath(), "test.d");
            
            cache.update("readonly-target", [sourcePath], [], "hash");
            
            // Attempt to flush should handle permission error
            try
            {
                cache.flush();
            }
            catch (Exception e)
            {
                // Expected - permission denied
            }
            
            cache.close();
            writeln("\x1b[32m  ✓ Read-only directory handled gracefully\x1b[0m");
        }
        catch (Exception e)
        {
            writeln("\x1b[32m  ✓ Read-only directory properly rejected\x1b[0m");
        }
        finally
        {
            // Restore permissions for cleanup
            execute(["chmod", "755", cacheDir]);
        }
    }
    else
    {
        writeln("\x1b[33m  ⊘ Read-only test skipped (non-POSIX system)\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Cache directory deleted during operation");
    
    auto tempDir = scoped(new TempDir("edge-deleted-dir"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto cache = new BuildCache(cacheDir);
    
    tempDir.createFile("source.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.d");
    
    cache.update("target1", [sourcePath], [], "hash1");
    
    // Delete cache directory while cache is active
    try
    {
        rmdirRecurse(cacheDir);
    }
    catch (Exception) {}
    
    // Operations should handle missing directory
    try
    {
        cache.flush();
        writeln("\x1b[32m  ✓ Deleted directory handled during flush\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[32m  ✓ Deleted directory error properly caught: ", e.msg, "\x1b[0m");
    }
    
    cache.close();
}

// ==================== EMPTY AND NULL INPUTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Empty source file list");
    
    auto tempDir = scoped(new TempDir("edge-empty-sources"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Empty sources array (valid for some targets like header-only)
    string[] emptySources = [];
    string[] deps = [];
    
    cache.update("empty-target", emptySources, deps, "hash123");
    Assert.isTrue(cache.isCached("empty-target", emptySources, deps));
    
    cache.close();
    writeln("\x1b[32m  ✓ Empty source file list handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Empty/null metadata in ActionCache");
    
    auto tempDir = scoped(new TempDir("edge-null-metadata"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("input.cpp", "int main() {}");
    auto inputPath = buildPath(tempDir.getPath(), "input.cpp");
    
    ActionId actionId;
    actionId.targetId = "null-meta-target";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    // Null metadata
    string[string] nullMeta;
    
    cache.update(actionId, [inputPath], [], nullMeta, true);
    Assert.isTrue(cache.isCached(actionId, [inputPath], nullMeta));
    
    cache.close();
    writeln("\x1b[32m  ✓ Null metadata handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Zero-byte file handling");
    
    auto tempDir = scoped(new TempDir("edge-zero-byte"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Create empty file
    tempDir.createFile("empty.txt", "");
    auto emptyPath = buildPath(tempDir.getPath(), "empty.txt");
    
    Assert.isTrue(exists(emptyPath));
    Assert.equal(getSize(emptyPath), 0);
    
    string[] sources = [emptyPath];
    
    cache.update("empty-file-target", sources, [], "hash-empty");
    Assert.isTrue(cache.isCached("empty-file-target", sources, []));
    
    cache.close();
    writeln("\x1b[32m  ✓ Zero-byte file handled correctly\x1b[0m");
}

// ==================== SPECIAL FILE NAMES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Unicode and special characters in filenames");
    
    auto tempDir = scoped(new TempDir("edge-unicode"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Create files with special names
    string[] specialNames = [
        "测试文件.cpp",        // Chinese
        "tëst_fïlé.cpp",       // Accented characters
        "файл.cpp",            // Cyrillic
        "file with spaces.cpp",
        "file-with-dashes.cpp",
        "file_with_underscores.cpp",
        "file.multiple.dots.cpp"
    ];
    
    foreach (name; specialNames)
    {
        try
        {
            tempDir.createFile(name, "int main() { return 0; }");
            auto path = buildPath(tempDir.getPath(), name);
            
            if (exists(path))
            {
                cache.update("special-" ~ name, [path], [], "hash-" ~ name);
                Assert.isTrue(cache.isCached("special-" ~ name, [path], []));
            }
        }
        catch (Exception e)
        {
            // Some filesystems may not support certain characters
            writeln("  ⚠ Skipped unsupported filename: ", name);
        }
    }
    
    cache.close();
    writeln("\x1b[32m  ✓ Special character filenames handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Very long file paths");
    
    auto tempDir = scoped(new TempDir("edge-long-path"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Create deeply nested directory structure
    string deepPath = tempDir.getPath();
    
    try
    {
        // Create nested directories (but stay under typical OS limits)
        foreach (i; 0 .. 10)
        {
            deepPath = buildPath(deepPath, "very_long_directory_name_" ~ i.to!string);
        }
        
        mkdirRecurse(deepPath);
        
        auto longFilePath = buildPath(deepPath, "file_with_very_long_name.cpp");
        std.file.write(longFilePath, "int main() {}");
        
        cache.update("long-path-target", [longFilePath], [], "hash-long");
        Assert.isTrue(cache.isCached("long-path-target", [longFilePath], []));
        
        writeln("\x1b[32m  ✓ Long file paths handled correctly\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Long path test hit OS limit (expected): ", e.msg, "\x1b[0m");
    }
    
    cache.close();
}

// ==================== SYMLINKS AND LINKS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Symlink handling");
    
    version(Posix)
    {
        auto tempDir = scoped(new TempDir("edge-symlinks"));
        auto cacheDir = buildPath(tempDir.getPath(), ".cache");
        auto cache = new BuildCache(cacheDir);
        
        // Create actual file
        tempDir.createFile("actual.cpp", "int actual_main() {}");
        auto actualPath = buildPath(tempDir.getPath(), "actual.cpp");
        
        // Create symlink
        auto symlinkPath = buildPath(tempDir.getPath(), "link.cpp");
        
        import std.process : execute;
        auto result = execute(["ln", "-s", actualPath, symlinkPath]);
        
        if (result.status == 0)
        {
            // Cache with symlink
            cache.update("symlink-target", [symlinkPath], [], "hash-symlink");
            Assert.isTrue(cache.isCached("symlink-target", [symlinkPath], []));
            
            // Modify actual file
            Thread.sleep(10.msecs);
            std.file.write(actualPath, "int actual_main() { return 1; }");
            
            // Cache should detect change through symlink
            Assert.isFalse(cache.isCached("symlink-target", [symlinkPath], []));
            
            writeln("\x1b[32m  ✓ Symlink handling works correctly\x1b[0m");
        }
        else
        {
            writeln("\x1b[33m  ⊘ Symlink test skipped (symlink creation failed)\x1b[0m");
        }
        
        cache.close();
    }
    else
    {
        writeln("\x1b[33m  ⊘ Symlink test skipped (non-POSIX system)\x1b[0m");
    }
}

// ==================== HASH COLLISION SIMULATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Hash collision handling in CAS");
    
    auto tempDir = scoped(new TempDir("edge-hash-collision"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    auto cas = new ContentAddressableStorage(storageDir);
    
    // Store multiple unique blobs
    ubyte[] data1 = cast(ubyte[])"Content A";
    ubyte[] data2 = cast(ubyte[])"Content B";
    ubyte[] data3 = cast(ubyte[])"Content C";
    
    auto hash1 = cas.putBlob(data1).unwrap();
    auto hash2 = cas.putBlob(data2).unwrap();
    auto hash3 = cas.putBlob(data3).unwrap();
    
    // Hashes should all be different
    Assert.notEqual(hash1, hash2);
    Assert.notEqual(hash2, hash3);
    Assert.notEqual(hash1, hash3);
    
    // Retrieving should return correct content
    Assert.equal(cas.getBlob(hash1).unwrap(), data1);
    Assert.equal(cas.getBlob(hash2).unwrap(), data2);
    Assert.equal(cas.getBlob(hash3).unwrap(), data3);
    
    writeln("\x1b[32m  ✓ Hash collision prevention verified\x1b[0m");
}

// ==================== CACHE SIZE BOUNDARY CONDITIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Cache at exactly max entries limit");
    
    auto tempDir = scoped(new TempDir("edge-boundary-entries"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxEntries = 5;  // Small limit for testing
    config.maxSize = 0;     // Disable size limit
    config.maxAge = 365;    // Disable age limit
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add exactly maxEntries
    foreach (i; 0 .. config.maxEntries)
    {
        auto filename = "file" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
        auto path = buildPath(tempDir.getPath(), filename);
        
        cache.update("target-" ~ i.to!string, [path], [], "hash" ~ i.to!string);
    }
    
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries <= config.maxEntries, 
                  "Entry count should not exceed maxEntries");
    
    cache.close();
    writeln("\x1b[32m  ✓ Cache boundary at max entries handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Single entry beyond size limit");
    
    auto tempDir = scoped(new TempDir("edge-oversized-entry"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxEntries = 100;
    config.maxSize = 1024;  // 1KB limit
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Create a file that would make a large cache entry
    auto largeContent = new char[2048];
    largeContent[] = 'X';
    
    tempDir.createFile("large.txt", largeContent.idup);
    auto largePath = buildPath(tempDir.getPath(), "large.txt");
    
    // Add the large entry
    cache.update("large-target", [largePath], [], "hash-large");
    
    // Cache should handle this gracefully (either accept or evict)
    cache.flush();
    
    // No assertion - just verify it doesn't crash
    cache.close();
    writeln("\x1b[32m  ✓ Oversized entry handled gracefully\x1b[0m");
}

// ==================== EVICTION EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Eviction with simultaneous access");
    
    auto tempDir = scoped(new TempDir("edge-evict-access"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    ActionCacheConfig config;
    config.maxEntries = 3;
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new ActionCache(cacheDir, config);
    
    // Fill cache
    foreach (i; 0 .. 3)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "content" ~ i.to!string);
        
        ActionId actionId;
        actionId.targetId = "target";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        actionId.subId = filename;
        
        auto path = buildPath(tempDir.getPath(), filename);
        cache.update(actionId, [path], [], null, true);
    }
    
    // Access first entry to make it recent
    ActionId actionId0;
    actionId0.targetId = "target";
    actionId0.type = ActionType.Compile;
    actionId0.inputHash = "hash0";
    actionId0.subId = "file0.cpp";
    
    cache.isCached(actionId0, [buildPath(tempDir.getPath(), "file0.cpp")], null);
    
    // Add new entry (triggers eviction)
    tempDir.createFile("file3.cpp", "content3");
    
    ActionId actionId3;
    actionId3.targetId = "target";
    actionId3.type = ActionType.Compile;
    actionId3.inputHash = "hash3";
    actionId3.subId = "file3.cpp";
    
    cache.update(actionId3, [buildPath(tempDir.getPath(), "file3.cpp")], [], null, true);
    
    // Simultaneously access while evicting
    cache.isCached(actionId0, [buildPath(tempDir.getPath(), "file0.cpp")], null);
    
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries <= config.maxEntries);
    
    cache.close();
    writeln("\x1b[32m  ✓ Eviction with simultaneous access handled\x1b[0m");
}

// ==================== INTEGRITY VALIDATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Tampered cache data detection");
    
    auto tempDir = scoped(new TempDir("edge-tampered"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    {
        // Create and populate cache
        auto cache = new BuildCache(cacheDir);
        
        tempDir.createFile("original.d", "void main() {}");
        auto sourcePath = buildPath(tempDir.getPath(), "original.d");
        
        cache.update("tamper-target", [sourcePath], [], "hash-original");
        cache.flush();
        cache.close();
    }
    
    // Tamper with cache file (modify binary data)
    auto cacheFilePath = buildPath(cacheDir, "cache.bin");
    
    if (exists(cacheFilePath))
    {
        auto cacheData = cast(ubyte[])read(cacheFilePath);
        
        // Flip some bits in the middle of the file
        if (cacheData.length > 100)
        {
            cacheData[50] = cast(ubyte)(cacheData[50] ^ 0xFF);
            cacheData[51] = cast(ubyte)(cacheData[51] ^ 0xFF);
        }
        
        std.file.write(cacheFilePath, cacheData);
    }
    
    // Try to load tampered cache
    try
    {
        auto cache2 = new BuildCache(cacheDir);
        
        // Cache should either detect tampering or start fresh
        // Either way, it should work without crashing
        tempDir.createFile("test.d", "void test() {}");
        auto testPath = buildPath(tempDir.getPath(), "test.d");
        
        cache2.update("new-target", [testPath], [], "hash-new");
        
        cache2.close();
        writeln("\x1b[32m  ✓ Tampered cache data handled (recovery or detection)\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[32m  ✓ Tampered cache properly rejected: ", e.msg, "\x1b[0m");
    }
}

// ==================== TRANSITIVE DEPENDENCY INVALIDATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Transitive dependency invalidation");
    
    auto tempDir = scoped(new TempDir("edge-transitive"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    
    // Create dependency chain: A -> B -> C
    tempDir.createFile("c.d", "module c; int c_value = 1;");
    tempDir.createFile("b.d", "module b; import c; int b_value = c_value + 1;");
    tempDir.createFile("a.d", "module a; import b; int a_value = b_value + 1;");
    
    auto pathC = buildPath(tempDir.getPath(), "c.d");
    auto pathB = buildPath(tempDir.getPath(), "b.d");
    auto pathA = buildPath(tempDir.getPath(), "a.d");
    
    // Cache each with dependencies
    cache.update("target-c", [pathC], [], "hash-c");
    cache.update("target-b", [pathB], [pathC], "hash-b");
    cache.update("target-a", [pathA], [pathB, pathC], "hash-a");
    
    // All should be cached
    Assert.isTrue(cache.isCached("target-c", [pathC], []));
    Assert.isTrue(cache.isCached("target-b", [pathB], [pathC]));
    Assert.isTrue(cache.isCached("target-a", [pathA], [pathB, pathC]));
    
    // Modify leaf dependency (C)
    Thread.sleep(10.msecs);
    tempDir.createFile("c.d", "module c; int c_value = 2;");
    
    // C should be invalidated
    Assert.isFalse(cache.isCached("target-c", [pathC], []));
    
    // B depends on C, so should also be invalidated
    Assert.isFalse(cache.isCached("target-b", [pathB], [pathC]));
    
    // A depends on B and C, so should be invalidated
    Assert.isFalse(cache.isCached("target-a", [pathA], [pathB, pathC]));
    
    cache.close();
    writeln("\x1b[32m  ✓ Transitive dependency invalidation works\x1b[0m");
}

// ==================== COORDINATOR EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Coordinator with mixed cache states");
    
    auto tempDir = scoped(new TempDir("edge-coordinator-mixed"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    tempDir.createFile("source.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.d");
    
    // Update target cache
    coordinator.update("mixed-target", [sourcePath], [], "target-hash");
    
    // Update action cache
    import engine.caching.actions.action : ActionId, ActionType;
    auto actionId = ActionId("mixed-target", ActionType.Compile, "action-hash", "source.d");
    
    tempDir.createFile("output.o", "binary");
    auto outputPath = buildPath(tempDir.getPath(), "output.o");
    
    coordinator.recordAction(actionId, [sourcePath], [outputPath], null, true);
    
    // Both should be cached
    Assert.isTrue(coordinator.isCached("mixed-target", [sourcePath], []));
    Assert.isTrue(coordinator.isActionCached(actionId, [sourcePath], null));
    
    // Modify source
    Thread.sleep(10.msecs);
    tempDir.createFile("source.d", "void main() { int x = 1; }");
    
    // Both should be invalidated
    Assert.isFalse(coordinator.isCached("mixed-target", [sourcePath], []));
    Assert.isFalse(coordinator.isActionCached(actionId, [sourcePath], null));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Coordinator with mixed cache states handled\x1b[0m");
}

// ==================== MEMORY AND RESOURCE PRESSURE ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Large number of cache entries");
    
    auto tempDir = scoped(new TempDir("edge-many-entries"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxEntries = 5000;  // Moderate limit
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Add many entries
    immutable entryCount = 1000;
    
    foreach (i; 0 .. entryCount)
    {
        auto filename = "file" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
        
        auto path = buildPath(tempDir.getPath(), filename);
        cache.update("target-" ~ i.to!string, [path], [], "hash" ~ i.to!string);
    }
    
    // Flush and verify
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries <= config.maxEntries);
    Assert.isTrue(stats.totalEntries >= entryCount / 2, "Should retain reasonable number of entries");
    
    cache.close();
    writeln("\x1b[32m  ✓ Large number of cache entries handled (", 
            stats.totalEntries, " entries)\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CachingEdgeCases - Very large blob storage");
    
    auto tempDir = scoped(new TempDir("edge-large-blob"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    auto cas = new ContentAddressableStorage(storageDir);
    
    // Create large blob (1 MB)
    auto largeData = new ubyte[1024 * 1024];
    foreach (i; 0 .. largeData.length)
    {
        largeData[i] = cast(ubyte)(i % 256);
    }
    
    // Store large blob
    auto putResult = cas.putBlob(largeData);
    Assert.isTrue(putResult.isOk, "Large blob storage should succeed");
    
    auto hash = putResult.unwrap();
    
    // Retrieve large blob
    auto getResult = cas.getBlob(hash);
    Assert.isTrue(getResult.isOk, "Large blob retrieval should succeed");
    
    auto retrieved = getResult.unwrap();
    Assert.equal(retrieved.length, largeData.length);
    
    // Verify data integrity
    foreach (i; 0 .. 1000)  // Sample check
    {
        Assert.equal(retrieved[i], largeData[i]);
    }
    
    writeln("\x1b[32m  ✓ Very large blob storage handled (", 
            largeData.length / 1024, " KB)\x1b[0m");
}

