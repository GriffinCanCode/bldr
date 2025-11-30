module tests.unit.caching.test_incremental;

import std.file;
import std.path;
import std.algorithm;
import std.conv;
import std.stdio;
import std.uuid;
import engine.caching.incremental.dependency;
import engine.caching.incremental.storage;
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

/// Test dependency cache basic operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m DependencyCache - Basic Operations");
    
    auto tempDir = scoped(new TempDir("test-dep-cache"));
    auto cache = new DependencyCache(tempDir.getPath());
    
    // Test recording dependencies
    cache.recordDependencies("main.cpp", ["header.h", "utils.h"]);
    
    auto result = cache.getDependencies("main.cpp");
    Assert.isTrue(result.isOk, "Should retrieve dependencies");
    
    auto deps = result.unwrap();
    Assert.equal(deps.sourceFile, "main.cpp", "Source file should match");
    Assert.equal(deps.dependencies.length, 2, "Should have 2 dependencies");
    Assert.isTrue(deps.dependencies.canFind("header.h"), "Should include header.h");
    Assert.isTrue(deps.dependencies.canFind("utils.h"), "Should include utils.h");
    
    writeln("\x1b[32m  ✓ Basic operations passed\x1b[0m");
}

/// Test dependency change analysis
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m DependencyCache - Change Analysis");
    
    auto cacheTempDir = scoped(new TempDir("test-dep-analysis"));
    auto sourceTempDir = scoped(new TempDir("test-sources"));
    
    auto cache = new DependencyCache(cacheTempDir.getPath());
    auto testDir = sourceTempDir.getPath();
    
    // Create test files
    sourceTempDir.createFile("main.cpp", "// main");
    sourceTempDir.createFile("header.h", "// header");
    sourceTempDir.createFile("utils.h", "// utils");
    
    // Record dependencies
    auto mainPath = buildPath(testDir, "main.cpp");
    auto headerPath = buildPath(testDir, "header.h");
    auto utilsPath = buildPath(testDir, "utils.h");
    
    cache.recordDependencies(mainPath, [headerPath, utilsPath]);
    
    // Analyze changes when header.h changes
    auto changes = cache.analyzeChanges([headerPath]);
    
    Assert.isTrue(changes.filesToRebuild.length > 0, "Should have files to rebuild");
    Assert.isTrue(changes.filesToRebuild.canFind(mainPath), 
              "main.cpp should need rebuild when header.h changes");
    Assert.isTrue(changes.changedDependencies.canFind(headerPath),
              "header.h should be in changed dependencies");
              
    writeln("\x1b[32m  ✓ Change analysis passed\x1b[0m");
}

/// Test dependency cache persistence
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m DependencyCache - Persistence");
    
    auto tempDir = scoped(new TempDir("test-dep-persist"));
    auto cacheDir = tempDir.getPath();
    
    // Create cache and record dependencies
    {
        auto cache = new DependencyCache(cacheDir);
        cache.recordDependencies("file1.cpp", ["dep1.h", "dep2.h"]);
        cache.recordDependencies("file2.cpp", ["dep3.h"]);
        cache.flush();
    }
    
    // Load cache in new instance
    {
        auto cache = new DependencyCache(cacheDir);
        
        auto result1 = cache.getDependencies("file1.cpp");
        Assert.isTrue(result1.isOk, "Should load file1.cpp dependencies");
        Assert.equal(result1.unwrap().dependencies.length, 2, "Should have 2 deps");
        
        auto result2 = cache.getDependencies("file2.cpp");
        Assert.isTrue(result2.isOk, "Should load file2.cpp dependencies");
        Assert.equal(result2.unwrap().dependencies.length, 1, "Should have 1 dep");
    }
    
    writeln("\x1b[32m  ✓ Persistence passed\x1b[0m");
}

/// Test dependency invalidation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m DependencyCache - Invalidation");
    
    auto tempDir = scoped(new TempDir("test-dep-invalid"));
    auto cache = new DependencyCache(tempDir.getPath());
    
    // Record dependencies
    cache.recordDependencies("main.cpp", ["header.h"]);
    
    auto before = cache.getDependencies("main.cpp");
    Assert.isTrue(before.isOk, "Should have dependencies before invalidation");
    
    // Invalidate
    cache.invalidate(["main.cpp"]);
    
    auto after = cache.getDependencies("main.cpp");
    Assert.isTrue(after.isErr, "Should not have dependencies after invalidation");
    
    writeln("\x1b[32m  ✓ Invalidation passed\x1b[0m");
}
