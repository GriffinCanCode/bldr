module tests.unit.compilation.test_incremental_engine;

import std.file;
import std.path;
import std.algorithm;
import std.conv;
import std.stdio;
import std.uuid;
import engine.compilation.incremental.engine;
import engine.caching.incremental.dependency;
import engine.caching.actions.action;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

// Helper to generate random UUID
private string randomUUID()
{
    import std.random;
    import std.format;
    
    return format("%08x-%04x-%04x-%04x-%012x",
                 uniform!uint(),
                 uniform!ushort(),
                 uniform!ushort(),
                 uniform!ushort(),
                 uniform!ulong() & 0xFFFF_FFFF_FFFF);
}

/// Test incremental engine rebuild determination
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m IncrementalEngine - Rebuild Set Determination");
    
    auto cacheTempDir = scoped(new TempDir("test-inc-engine"));
    auto sourceTempDir = scoped(new TempDir("test-sources"));
    
    auto testCacheDir = cacheTempDir.getPath();
    auto testDir = sourceTempDir.getPath();
    
    auto depCache = new DependencyCache(buildPath(testCacheDir, "deps"));
    auto actionCache = new ActionCache(buildPath(testCacheDir, "actions"));
    auto engine = new IncrementalEngine(depCache, actionCache);
    
    // Create test files
    sourceTempDir.createFile("main.cpp", "// main");
    sourceTempDir.createFile("utils.cpp", "// utils");
    sourceTempDir.createFile("header.h", "// header");
    
    auto mainPath = buildPath(testDir, "main.cpp");
    auto utilsPath = buildPath(testDir, "utils.cpp");
    auto headerPath = buildPath(testDir, "header.h");
    
    // Record that main.cpp depends on header.h
    depCache.recordDependencies(mainPath, [headerPath]);
    
    auto sources = [mainPath, utilsPath];
    auto changedFiles = [headerPath];
    
    // Determine rebuild set
    auto result = engine.determineRebuildSet(
        sources,
        changedFiles,
        (file) {
            ActionId id;
            id.targetId = "test";
            id.type = ActionType.Compile;
            id.subId = baseName(file);
            id.inputHash = "test-hash";
            return id;
        },
        (file) {
            string[string] meta;
            meta["test"] = "true";
            return meta;
        }
    );
    
    // main.cpp should need recompilation (depends on header.h)
    Assert.isTrue(result.filesToCompile.canFind(mainPath),
              "main.cpp should need recompilation");
    
    // utils.cpp should not (no dependency on header.h)
    // Though it might still compile due to action cache miss
    Assert.equal(result.totalFiles, 2, "Should track 2 total files");
    
    writeln("\x1b[32m  ✓ Rebuild set determination passed\x1b[0m");
}

/// Test incremental compilation recording
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m IncrementalEngine - Compilation Recording");
    
    auto cacheTempDir = scoped(new TempDir("test-inc-record"));
    auto sourceTempDir = scoped(new TempDir("test-sources"));
    
    auto testCacheDir = cacheTempDir.getPath();
    auto testDir = sourceTempDir.getPath();
    
    auto depCache = new DependencyCache(buildPath(testCacheDir, "deps"));
    auto actionCache = new ActionCache(buildPath(testCacheDir, "actions"));
    auto engine = new IncrementalEngine(depCache, actionCache);
    
    // Create test files
    sourceTempDir.createFile("main.cpp", "// main");
    sourceTempDir.createFile("header.h", "// header");
    sourceTempDir.createFile("main.o", "fake object");
    
    auto mainPath = buildPath(testDir, "main.cpp");
    auto headerPath = buildPath(testDir, "header.h");
    auto objPath = buildPath(testDir, "main.o");
    
    ActionId actionId;
    actionId.targetId = "test";
    actionId.type = ActionType.Compile;
    actionId.subId = "main.cpp";
    actionId.inputHash = "test-hash";
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Record compilation
    engine.recordCompilation(
        mainPath,
        [headerPath],
        actionId,
        [objPath],
        metadata
    );
    
    // Verify dependency cache updated
    auto depResult = depCache.getDependencies(mainPath);
    Assert.isTrue(depResult.isOk, "Dependencies should be recorded");
    
    auto deps = depResult.unwrap();
    Assert.isTrue(deps.dependencies.canFind(headerPath),
              "Should record header dependency");
    
    // Verify action cache updated
    Assert.isTrue(actionCache.isCached(actionId, [mainPath], metadata),
              "Action should be cached");
              
    writeln("\x1b[32m  ✓ Recording passed\x1b[0m");
}

/// Test incremental compilation strategies
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m IncrementalEngine - Strategies");
    
    auto cacheTempDir = scoped(new TempDir("test-inc-strat"));
    auto sourceTempDir = scoped(new TempDir("test-sources"));
    
    auto testCacheDir = cacheTempDir.getPath();
    auto testDir = sourceTempDir.getPath();
    
    sourceTempDir.createFile("file1.cpp", "// file1");
    sourceTempDir.createFile("file2.cpp", "// file2");
    
    auto depCache = new DependencyCache(buildPath(testCacheDir, "deps"));
    auto actionCache = new ActionCache(buildPath(testCacheDir, "actions"));
    
    auto file1 = buildPath(testDir, "file1.cpp");
    auto file2 = buildPath(testDir, "file2.cpp");
    auto sources = [file1, file2];
    
    // Test Full strategy
    {
        auto engine = new IncrementalEngine(
            depCache, actionCache, CompilationStrategy.Full
        );
        
        auto result = engine.determineRebuildSet(
            sources, [],
            (file) { ActionId id; return id; },
            (file) { string[string] m; return m; }
        );
        
        Assert.equal(result.strategy, CompilationStrategy.Full, 
                   "Should use Full strategy");
        Assert.equal(result.filesToCompile.length, 2, 
                   "Should compile all files with Full strategy");
    }
    
    // Test Incremental strategy
    {
        auto engine = new IncrementalEngine(
            depCache, actionCache, CompilationStrategy.Incremental
        );
        
        auto result = engine.determineRebuildSet(
            sources, [],
            (file) { ActionId id; return id; },
            (file) { string[string] m; return m; }
        );
        
        Assert.equal(result.strategy, CompilationStrategy.Incremental,
                   "Should use Incremental strategy");
    }
    
    writeln("\x1b[32m  ✓ Strategies passed\x1b[0m");
}
