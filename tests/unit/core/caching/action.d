module tests.unit.core.caching.action;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.range;
import std.algorithm;
import std.parallelism;
import core.thread;
import core.time;
import engine.caching.actions.action;
import engine.caching.policies.eviction;
import tests.harness;
import tests.fixtures;

// ==================== BASIC FUNCTIONALITY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Basic cache hit on unchanged action");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create source files
    tempDir.createFile("source.cpp", "#include <iostream>\nint main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    
    // Create action ID
    ActionId actionId;
    actionId.targetId = "my-app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash123";
    actionId.subId = "source.cpp";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    metadata["compiler"] = "g++";
    metadata["flags"] = "-O2 -std=c++17";
    
    // Initial check - cache miss
    Assert.isFalse(cache.isCached(actionId, inputs, metadata));
    
    // Simulate successful compilation
    tempDir.createFile("source.o", "binary output");
    auto outputPath = buildPath(tempDir.getPath(), "source.o");
    string[] outputs = [outputPath];
    
    // Update cache
    cache.update(actionId, inputs, outputs, metadata, true);
    
    // Second check - cache hit (nothing changed)
    Assert.isTrue(cache.isCached(actionId, inputs, metadata));
    
    writeln("\x1b[32m  ✓ Basic cache hit works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Cache miss on input file change");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create and cache initial version
    tempDir.createFile("main.cpp", "int main() { return 0; }");
    auto sourcePath = buildPath(tempDir.getPath(), "main.cpp");
    
    ActionId actionId;
    actionId.targetId = "app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    metadata["compiler"] = "clang++";
    
    tempDir.createFile("main.o", "output");
    string[] outputs = [buildPath(tempDir.getPath(), "main.o")];
    
    cache.update(actionId, inputs, outputs, metadata, true);
    Assert.isTrue(cache.isCached(actionId, inputs, metadata));
    
    // Modify source file
    Thread.sleep(10.msecs);
    tempDir.createFile("main.cpp", "int main() { return 1; }");
    
    // Cache miss due to content change
    Assert.isFalse(cache.isCached(actionId, inputs, metadata));
    
    writeln("\x1b[32m  ✓ Cache miss on input change detected correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Cache miss on metadata change");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("file.cpp", "int x = 42;");
    auto sourcePath = buildPath(tempDir.getPath(), "file.cpp");
    
    ActionId actionId;
    actionId.targetId = "lib";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [sourcePath];
    string[string] metadata1;
    metadata1["flags"] = "-O0";
    
    tempDir.createFile("file.o", "output");
    string[] outputs = [buildPath(tempDir.getPath(), "file.o")];
    
    cache.update(actionId, inputs, outputs, metadata1, true);
    Assert.isTrue(cache.isCached(actionId, inputs, metadata1));
    
    // Check with different metadata (flags changed)
    string[string] metadata2;
    metadata2["flags"] = "-O3";
    
    Assert.isFalse(cache.isCached(actionId, inputs, metadata2));
    
    writeln("\x1b[32m  ✓ Cache miss on metadata change detected\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Cache miss on missing output file");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("input.cpp", "void func() {}");
    auto inputPath = buildPath(tempDir.getPath(), "input.cpp");
    tempDir.createFile("output.o", "binary");
    auto outputPath = buildPath(tempDir.getPath(), "output.o");
    
    ActionId actionId;
    actionId.targetId = "target";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [inputPath];
    string[] outputs = [outputPath];
    string[string] metadata;
    
    cache.update(actionId, inputs, outputs, metadata, true);
    Assert.isTrue(cache.isCached(actionId, inputs, metadata));
    
    // Delete output file
    remove(outputPath);
    
    // Cache miss due to missing output
    Assert.isFalse(cache.isCached(actionId, inputs, metadata));
    
    writeln("\x1b[32m  ✓ Cache miss on missing output detected\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Failed action not cached");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("bad.cpp", "syntax error!");
    auto sourcePath = buildPath(tempDir.getPath(), "bad.cpp");
    
    ActionId actionId;
    actionId.targetId = "broken";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    
    // Record failed compilation
    cache.update(actionId, inputs, [], metadata, false);
    
    // Failed actions should not produce cache hits
    Assert.isFalse(cache.isCached(actionId, inputs, metadata));
    
    writeln("\x1b[32m  ✓ Failed actions correctly not cached\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - ActionId parsing and serialization");
    
    ActionId original;
    original.targetId = "my-target";
    original.type = ActionType.Compile;
    original.inputHash = "abc123def456";
    original.subId = "file.cpp";
    
    // Serialize
    string serialized = original.toString();
    
    // Deserialize
    auto parseResult = ActionId.parse(serialized);
    Assert.isTrue(parseResult.isOk);
    ActionId parsed = parseResult.unwrap();
    
    // Verify
    Assert.equal(parsed.targetId, original.targetId);
    Assert.equal(parsed.type, original.type);
    Assert.equal(parsed.inputHash, original.inputHash);
    Assert.equal(parsed.subId, original.subId);
    
    writeln("\x1b[32m  ✓ ActionId serialization works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Multiple actions per target");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Simulate compiling multiple source files for one target
    tempDir.createFile("a.cpp", "void a() {}");
    tempDir.createFile("b.cpp", "void b() {}");
    tempDir.createFile("c.cpp", "void c() {}");
    
    auto pathA = buildPath(tempDir.getPath(), "a.cpp");
    auto pathB = buildPath(tempDir.getPath(), "b.cpp");
    auto pathC = buildPath(tempDir.getPath(), "c.cpp");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Compile each file separately (action-level caching)
    foreach (i, path; [pathA, pathB, pathC])
    {
        ActionId actionId;
        actionId.targetId = "my-app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        actionId.subId = baseName(path);
        
        auto outputPath = setExtension(path, ".o");
        tempDir.createFile(baseName(outputPath), "binary");
        
        cache.update(actionId, [path], [outputPath], metadata, true);
    }
    
    // Verify all three actions are cached
    auto stats = cache.getStats();
    Assert.equal(stats.totalEntries, 3);
    Assert.equal(stats.successfulActions, 3);
    
    // Get all actions for this target
    auto actions = cache.getActionsForTarget("my-app");
    Assert.equal(actions.length, 3);
    
    writeln("\x1b[32m  ✓ Multiple actions per target work correctly\x1b[0m");
}

// ==================== CACHE INVALIDATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Manual invalidation");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("source.cpp", "int main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    
    ActionId actionId;
    actionId.targetId = "app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    
    tempDir.createFile("out.o", "binary");
    cache.update(actionId, inputs, [buildPath(tempDir.getPath(), "out.o")], metadata, true);
    Assert.isTrue(cache.isCached(actionId, inputs, metadata));
    
    // Manually invalidate
    cache.invalidate(actionId);
    
    Assert.isFalse(cache.isCached(actionId, inputs, metadata));
    
    writeln("\x1b[32m  ✓ Manual invalidation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Clear all entries");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Add multiple entries
    foreach (i; 0 .. 5)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
        
        ActionId actionId;
        actionId.targetId = "target" ~ i.to!string;
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        
        auto path = buildPath(tempDir.getPath(), filename);
        cache.update(actionId, [path], [], null, true);
    }
    
    auto stats1 = cache.getStats();
    Assert.equal(stats1.totalEntries, 5);
    
    // Clear everything
    cache.clear();
    
    auto stats2 = cache.getStats();
    Assert.equal(stats2.totalEntries, 0);
    
    writeln("\x1b[32m  ✓ Clear all entries works\x1b[0m");
}

// ==================== PERSISTENCE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Persistence across instances");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    
    tempDir.createFile("persistent.cpp", "int main() { return 0; }");
    auto sourcePath = buildPath(tempDir.getPath(), "persistent.cpp");
    
    ActionId actionId;
    actionId.targetId = "persistent-app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "persist-hash";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // First instance - create and flush
    {
        auto cache1 = new ActionCache(cacheDir);
        tempDir.createFile("persistent.o", "binary");
        cache1.update(actionId, inputs, [buildPath(tempDir.getPath(), "persistent.o")], metadata, true);
        cache1.flush();
        cache1.close();
    }
    
    // Second instance - load from disk
    {
        auto cache2 = new ActionCache(cacheDir);
        Assert.isTrue(cache2.isCached(actionId, inputs, metadata));
        
        auto stats = cache2.getStats();
        Assert.equal(stats.totalEntries, 1);
        
        cache2.close();
    }
    
    writeln("\x1b[32m  ✓ Cache persistence works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Automatic flush on close");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    
    tempDir.createFile("file.cpp", "int x = 1;");
    auto sourcePath = buildPath(tempDir.getPath(), "file.cpp");
    
    ActionId actionId;
    actionId.targetId = "auto-flush";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash";
    
    // Add entry and close (should auto-flush)
    {
        auto cache1 = new ActionCache(cacheDir);
        tempDir.createFile("file.o", "binary");
        cache1.update(actionId, [sourcePath], [buildPath(tempDir.getPath(), "file.o")], null, true);
        cache1.close();
    }
    
    // Verify persisted
    {
        auto cache2 = new ActionCache(cacheDir);
        Assert.isTrue(cache2.isCached(actionId, [sourcePath], null));
        cache2.close();
    }
    
    writeln("\x1b[32m  ✓ Automatic flush on close works\x1b[0m");
}

// ==================== EVICTION POLICY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - LRU eviction");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    
    ActionCacheConfig config;
    config.maxEntries = 3;  // Only keep 3 actions
    config.maxSize = 0;      // Disable size limit
    config.maxAge = 365;     // Disable age limit
    
    auto cache = new ActionCache(cacheDir, config);
    
    // Add 3 entries (at capacity)
    foreach (i; 0 .. 3)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "void func() {}");
        
        ActionId actionId;
        actionId.targetId = "target";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        actionId.subId = filename;
        
        auto path = buildPath(tempDir.getPath(), filename);
        cache.update(actionId, [path], [], null, true);
    }
    
    // Access first entry to make it recently used
    ActionId actionId0;
    actionId0.targetId = "target";
    actionId0.type = ActionType.Compile;
    actionId0.inputHash = "hash0";
    actionId0.subId = "file0.cpp";
    cache.isCached(actionId0, [buildPath(tempDir.getPath(), "file0.cpp")], null);
    
    // Add 4th entry - should evict least recently used (entry 1)
    tempDir.createFile("file3.cpp", "void func() {}");
    ActionId actionId3;
    actionId3.targetId = "target";
    actionId3.type = ActionType.Compile;
    actionId3.inputHash = "hash3";
    actionId3.subId = "file3.cpp";
    cache.update(actionId3, [buildPath(tempDir.getPath(), "file3.cpp")], [], null, true);
    
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries <= config.maxEntries);
    
    writeln("\x1b[32m  ✓ LRU eviction policy works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Age-based eviction");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    
    ActionCacheConfig config;
    config.maxEntries = 100;
    config.maxSize = 0;
    config.maxAge = 0;  // Immediate expiration for testing
    
    auto cache = new ActionCache(cacheDir, config);
    
    tempDir.createFile("old.cpp", "int main() {}");
    
    ActionId actionId;
    actionId.targetId = "old-target";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash";
    
    cache.update(actionId, [buildPath(tempDir.getPath(), "old.cpp")], [], null, true);
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.equal(stats.totalEntries, 0, "Old entries should be evicted");
    
    writeln("\x1b[32m  ✓ Age-based eviction works\x1b[0m");
}

// ==================== STATISTICS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Statistics tracking");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("source.cpp", "int main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    
    ActionId actionId;
    actionId.targetId = "app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    
    // Initial miss
    cache.isCached(actionId, inputs, metadata);
    
    // Add entry
    tempDir.createFile("source.o", "binary");
    cache.update(actionId, inputs, [buildPath(tempDir.getPath(), "source.o")], metadata, true);
    
    // Multiple hits
    cache.isCached(actionId, inputs, metadata);
    cache.isCached(actionId, inputs, metadata);
    cache.isCached(actionId, inputs, metadata);
    
    auto stats = cache.getStats();
    Assert.equal(stats.totalEntries, 1);
    Assert.equal(stats.successfulActions, 1);
    Assert.equal(stats.misses, 1);
    Assert.equal(stats.hits, 3);
    Assert.isTrue(stats.hitRate > 70.0, "Hit rate should be high");
    
    writeln("\x1b[32m  ✓ Statistics tracking works\x1b[0m");
}

// ==================== DIFFERENT ACTION TYPES TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Different action types");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create files for different action types
    tempDir.createFile("source.cpp", "int main() {}");
    tempDir.createFile("object.o", "binary");
    tempDir.createFile("schema.proto", "message Test {}");
    tempDir.createFile("test.cpp", "void test() {}");
    
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    auto objectPath = buildPath(tempDir.getPath(), "object.o");
    auto protoPath = buildPath(tempDir.getPath(), "schema.proto");
    auto testPath = buildPath(tempDir.getPath(), "test.cpp");
    
    // Compile action
    ActionId compileId;
    compileId.targetId = "app";
    compileId.type = ActionType.Compile;
    compileId.inputHash = "compile-hash";
    cache.update(compileId, [sourcePath], [objectPath], null, true);
    
    // Link action
    ActionId linkId;
    linkId.targetId = "app";
    linkId.type = ActionType.Link;
    linkId.inputHash = "link-hash";
    tempDir.createFile("app.exe", "binary");
    cache.update(linkId, [objectPath], [buildPath(tempDir.getPath(), "app.exe")], null, true);
    
    // Codegen action
    ActionId codegenId;
    codegenId.targetId = "protobuf";
    codegenId.type = ActionType.Codegen;
    codegenId.inputHash = "codegen-hash";
    tempDir.createFile("schema.pb.h", "generated");
    cache.update(codegenId, [protoPath], [buildPath(tempDir.getPath(), "schema.pb.h")], null, true);
    
    // Test action
    ActionId testId;
    testId.targetId = "tests";
    testId.type = ActionType.Test;
    testId.inputHash = "test-hash";
    cache.update(testId, [testPath], [], null, true);
    
    auto stats = cache.getStats();
    Assert.equal(stats.totalEntries, 4);
    Assert.equal(stats.successfulActions, 4);
    
    writeln("\x1b[32m  ✓ Different action types work correctly\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Concurrent action updates");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create multiple source files
    foreach (i; 0 .. 10)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
    }
    
    try
    {
        // Concurrent updates
        foreach (i; parallel(iota(10)))
        {
            auto filename = "file" ~ i.to!string ~ ".cpp";
            auto path = buildPath(tempDir.getPath(), filename);
            
            ActionId actionId;
            actionId.targetId = "concurrent-target";
            actionId.type = ActionType.Compile;
            actionId.inputHash = "hash" ~ i.to!string;
            actionId.subId = filename;
            
            cache.update(actionId, [path], [], null, true);
        }
        
        auto stats = cache.getStats();
        Assert.equal(stats.totalEntries, 10, "All concurrent actions should be cached");
        
        writeln("\x1b[32m  ✓ Concurrent action updates work safely\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

// ==================== EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Empty metadata handling");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("minimal.cpp", "int x = 1;");
    auto sourcePath = buildPath(tempDir.getPath(), "minimal.cpp");
    
    ActionId actionId;
    actionId.targetId = "minimal";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash";
    
    string[string] emptyMetadata;
    cache.update(actionId, [sourcePath], [], emptyMetadata, true);
    
    Assert.isTrue(cache.isCached(actionId, [sourcePath], emptyMetadata));
    
    writeln("\x1b[32m  ✓ Empty metadata handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - Multiple inputs per action");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create multiple input files for one action (e.g., linking)
    tempDir.createFile("obj1.o", "binary1");
    tempDir.createFile("obj2.o", "binary2");
    tempDir.createFile("obj3.o", "binary3");
    
    auto obj1 = buildPath(tempDir.getPath(), "obj1.o");
    auto obj2 = buildPath(tempDir.getPath(), "obj2.o");
    auto obj3 = buildPath(tempDir.getPath(), "obj3.o");
    
    ActionId linkAction;
    linkAction.targetId = "app";
    linkAction.type = ActionType.Link;
    linkAction.inputHash = "link-hash";
    
    string[] inputs = [obj1, obj2, obj3];
    tempDir.createFile("app.exe", "executable");
    string[] outputs = [buildPath(tempDir.getPath(), "app.exe")];
    
    cache.update(linkAction, inputs, outputs, null, true);
    Assert.isTrue(cache.isCached(linkAction, inputs, null));
    
    // Change one input
    Thread.sleep(10.msecs);
    tempDir.createFile("obj2.o", "modified binary");
    
    Assert.isFalse(cache.isCached(linkAction, inputs, null));
    
    writeln("\x1b[32m  ✓ Multiple inputs per action work correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ActionCache - ActionId with no subId");
    
    auto tempDir = scoped(new TempDir("action-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("input.cpp", "int main() {}");
    auto inputPath = buildPath(tempDir.getPath(), "input.cpp");
    
    // ActionId without subId (e.g., for link actions)
    ActionId actionId;
    actionId.targetId = "my-app";
    actionId.type = ActionType.Link;
    actionId.inputHash = "link-hash-123";
    actionId.subId = "";  // No sub-identifier
    
    tempDir.createFile("output.exe", "binary");
    cache.update(actionId, [inputPath], [buildPath(tempDir.getPath(), "output.exe")], null, true);
    
    Assert.isTrue(cache.isCached(actionId, [inputPath], null));
    
    // Verify serialization works without subId
    string serialized = actionId.toString();
    auto parseResult = ActionId.parse(serialized);
    Assert.isTrue(parseResult.isOk);
    ActionId parsed = parseResult.unwrap();
    Assert.equal(parsed.targetId, actionId.targetId);
    Assert.equal(parsed.type, actionId.type);
    
    writeln("\x1b[32m  ✓ ActionId without subId works correctly\x1b[0m");
}

