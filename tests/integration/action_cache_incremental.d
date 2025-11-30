module tests.integration.action_cache_incremental;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.algorithm;
import std.array;
import std.range;
import core.thread;
import core.time;
import engine.caching.actions.action;
import tests.harness;
import tests.fixtures;

/// Integration test demonstrating incremental builds with action cache
/// 
/// Scenario:
/// 1. Build a C++ project with multiple source files
/// 2. Modify one source file
/// 3. Rebuild - only modified file should recompile
/// 4. Verify cache hits for unchanged files

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Incremental C++ build");
    
    auto tempDir = scoped(new TempDir("action-cache-integration"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create a multi-file C++ project
    tempDir.createFile("main.cpp", `
#include "utils.h"
#include "math.h"
int main() {
    print_hello();
    int result = add(2, 3);
    return 0;
}
`);
    
    tempDir.createFile("utils.cpp", `
#include "utils.h"
#include <iostream>
void print_hello() {
    std::cout << "Hello, World!" << std::endl;
}
`);
    
    tempDir.createFile("math.cpp", `
#include "math.h"
int add(int a, int b) {
    return a + b;
}
`);
    
    tempDir.createFile("utils.h", `
#ifndef UTILS_H
#define UTILS_H
void print_hello();
#endif
`);
    
    tempDir.createFile("math.h", `
#ifndef MATH_H
#define MATH_H
int add(int a, int b);
#endif
`);
    
    auto mainCpp = buildPath(tempDir.getPath(), "main.cpp");
    auto utilsCpp = buildPath(tempDir.getPath(), "utils.cpp");
    auto mathCpp = buildPath(tempDir.getPath(), "math.cpp");
    
    string[string] compileMetadata;
    compileMetadata["compiler"] = "g++";
    compileMetadata["flags"] = "-std=c++17 -O2";
    
    writeln("  Phase 1: Initial build (all files compile)");
    
    // Simulate compiling each source file
    ActionId[] compileActions;
    string[] objectFiles;
    
    foreach (sourceFile; [mainCpp, utilsCpp, mathCpp])
    {
        ActionId actionId;
        actionId.targetId = "my-app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash-v1";
        actionId.subId = baseName(sourceFile);
        
        // Check cache (should miss on first build)
        Assert.isFalse(cache.isCached(actionId, [sourceFile], compileMetadata),
                      "First build should be cache miss for " ~ baseName(sourceFile));
        
        // Simulate compilation output
        auto objectFile = setExtension(sourceFile, ".o");
        tempDir.createFile(baseName(objectFile), "binary-object-v1");
        objectFiles ~= objectFile;
        
        // Update cache with successful compilation
        cache.update(actionId, [sourceFile], [objectFile], compileMetadata, true);
        compileActions ~= actionId;
        
        writeln("    Compiled: ", baseName(sourceFile), " (cache miss)");
    }
    
    // Simulate linking
    ActionId linkAction;
    linkAction.targetId = "my-app";
    linkAction.type = ActionType.Link;
    linkAction.inputHash = "link-hash-v1";
    
    string[string] linkMetadata;
    linkMetadata["linker"] = "g++";
    linkMetadata["flags"] = "-o my-app";
    
    tempDir.createFile("my-app", "executable-v1");
    auto appPath = buildPath(tempDir.getPath(), "my-app");
    
    cache.update(linkAction, objectFiles, [appPath], linkMetadata, true);
    writeln("    Linked: my-app (cache miss)");
    
    auto stats1 = cache.getStats();
    Assert.equal(stats1.totalEntries, 4, "Should have 3 compile + 1 link actions");
    Assert.equal(stats1.successfulActions, 4);
    
    writeln("  Phase 2: Rebuild without changes (all cached)");
    
    // Simulate second build - everything should be cached
    size_t cacheHits = 0;
    foreach (i, sourceFile; [mainCpp, utilsCpp, mathCpp])
    {
        if (cache.isCached(compileActions[i], [sourceFile], compileMetadata))
        {
            cacheHits++;
            writeln("    Skipped: ", baseName(sourceFile), " (cache hit)");
        }
    }
    
    Assert.equal(cacheHits, 3, "All source files should be cached");
    
    // Link should also be cached
    Assert.isTrue(cache.isCached(linkAction, objectFiles, linkMetadata),
                 "Link action should be cached");
    writeln("    Skipped: linking (cache hit)");
    
    writeln("  Phase 3: Modify one file and rebuild (incremental)");
    
    // Modify utils.cpp
    Thread.sleep(10.msecs);
    tempDir.createFile("utils.cpp", `
#include "utils.h"
#include <iostream>
void print_hello() {
    std::cout << "Hello, Modified World!" << std::endl;
}
`);
    
    // Check cache status after modification
    cacheHits = 0;
    size_t cacheMisses = 0;
    
    foreach (i, sourceFile; [mainCpp, utilsCpp, mathCpp])
    {
        if (cache.isCached(compileActions[i], [sourceFile], compileMetadata))
        {
            cacheHits++;
            writeln("    Skipped: ", baseName(sourceFile), " (cache hit)");
        }
        else
        {
            cacheMisses++;
            writeln("    Recompiling: ", baseName(sourceFile), " (cache miss)");
            
            // Simulate recompilation
            auto objectFile = setExtension(sourceFile, ".o");
            Thread.sleep(5.msecs);
            tempDir.createFile(baseName(objectFile), "binary-object-v2");
            
            // Update cache with new compilation
            ActionId newActionId;
            newActionId.targetId = "my-app";
            newActionId.type = ActionType.Compile;
            newActionId.inputHash = "hash-v2";
            newActionId.subId = baseName(sourceFile);
            
            cache.update(newActionId, [sourceFile], [objectFile], compileMetadata, true);
        }
    }
    
    Assert.equal(cacheHits, 2, "main.cpp and math.cpp should be cached");
    Assert.equal(cacheMisses, 1, "utils.cpp should be recompiled");
    
    // Link is invalidated because object files changed
    Assert.isFalse(cache.isCached(linkAction, objectFiles, linkMetadata),
                  "Link should be invalidated after object file change");
    
    // Relink
    Thread.sleep(5.msecs);
    tempDir.createFile("my-app", "executable-v2");
    
    ActionId newLinkAction;
    newLinkAction.targetId = "my-app";
    newLinkAction.type = ActionType.Link;
    newLinkAction.inputHash = "link-hash-v2";
    
    cache.update(newLinkAction, objectFiles, [appPath], linkMetadata, true);
    writeln("    Relinked: my-app");
    
    auto stats2 = cache.getStats();
    writeln("\n  Statistics:");
    writeln("    Total actions cached: ", stats2.totalEntries);
    writeln("    Cache hits: ", stats2.hits);
    writeln("    Cache misses: ", stats2.misses);
    writeln("    Hit rate: ", stats2.hitRate, "%");
    
    Assert.isTrue(stats2.hitRate > 50.0, "Hit rate should be above 50% in incremental build");
    
    writeln("\x1b[32m  ✓ Incremental C++ build with action cache works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Multi-target incremental build");
    
    auto tempDir = scoped(new TempDir("action-cache-multi-target"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    // Create a project with library and application
    writeln("  Building library and application...");
    
    // Library sources
    tempDir.createFile("lib/vector.cpp", "class Vector { /* impl */ };");
    tempDir.createFile("lib/matrix.cpp", "class Matrix { /* impl */ };");
    
    // Application sources
    tempDir.createFile("app/main.cpp", "#include <vector>\nint main() {}");
    tempDir.createFile("app/ui.cpp", "void render() { /* ui code */ }");
    
    auto libVector = buildPath(tempDir.getPath(), "lib/vector.cpp");
    auto libMatrix = buildPath(tempDir.getPath(), "lib/matrix.cpp");
    auto appMain = buildPath(tempDir.getPath(), "app/main.cpp");
    auto appUi = buildPath(tempDir.getPath(), "app/ui.cpp");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Build library
    writeln("    Compiling library...");
    foreach (sourceFile; [libVector, libMatrix])
    {
        ActionId actionId;
        actionId.targetId = "math-lib";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "lib-hash-v1";
        actionId.subId = baseName(sourceFile);
        
        auto objectFile = setExtension(sourceFile, ".o");
        tempDir.createFile(baseName(dirName(objectFile)) ~ "/" ~ baseName(objectFile), "lib-object");
        
        cache.update(actionId, [sourceFile], [objectFile], metadata, true);
    }
    
    // Link library
    ActionId libLinkAction;
    libLinkAction.targetId = "math-lib";
    libLinkAction.type = ActionType.Link;
    libLinkAction.inputHash = "lib-link-v1";
    
    tempDir.createFile("lib/libmath.a", "static-lib");
    auto libPath = buildPath(tempDir.getPath(), "lib/libmath.a");
    cache.update(libLinkAction, [setExtension(libVector, ".o"), setExtension(libMatrix, ".o")], 
                [libPath], metadata, true);
    
    // Build application
    writeln("    Compiling application...");
    foreach (sourceFile; [appMain, appUi])
    {
        ActionId actionId;
        actionId.targetId = "my-app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "app-hash-v1";
        actionId.subId = baseName(sourceFile);
        
        auto objectFile = setExtension(sourceFile, ".o");
        tempDir.createFile(baseName(dirName(objectFile)) ~ "/" ~ baseName(objectFile), "app-object");
        
        cache.update(actionId, [sourceFile], [objectFile], metadata, true);
    }
    
    // Link application
    ActionId appLinkAction;
    appLinkAction.targetId = "my-app";
    appLinkAction.type = ActionType.Link;
    appLinkAction.inputHash = "app-link-v1";
    
    tempDir.createFile("app/my-app", "executable");
    auto appPath = buildPath(tempDir.getPath(), "app/my-app");
    auto appObjs = [setExtension(appMain, ".o"), setExtension(appUi, ".o")];
    cache.update(appLinkAction, appObjs ~ libPath, [appPath], metadata, true);
    
    auto stats1 = cache.getStats();
    writeln("    Initial build complete: ", stats1.totalEntries, " actions cached");
    
    // Modify only library source
    writeln("\n  Modifying library source...");
    Thread.sleep(10.msecs);
    tempDir.createFile("lib/vector.cpp", "class Vector { /* modified */ };");
    
    // Check what needs rebuilding
    size_t libRebuilds = 0;
    size_t appRebuilds = 0;
    
    foreach (sourceFile; [libVector, libMatrix])
    {
        ActionId actionId;
        actionId.targetId = "math-lib";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "lib-hash-v1";
        actionId.subId = baseName(sourceFile);
        
        if (!cache.isCached(actionId, [sourceFile], metadata))
        {
            libRebuilds++;
            writeln("    Library needs recompile: ", baseName(sourceFile));
        }
    }
    
    foreach (sourceFile; [appMain, appUi])
    {
        ActionId actionId;
        actionId.targetId = "my-app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "app-hash-v1";
        actionId.subId = baseName(sourceFile);
        
        if (!cache.isCached(actionId, [sourceFile], metadata))
        {
            appRebuilds++;
            writeln("    Application needs recompile: ", baseName(sourceFile));
        }
    }
    
    Assert.equal(libRebuilds, 1, "Only vector.cpp should need recompilation");
    Assert.equal(appRebuilds, 0, "Application sources unchanged");
    
    writeln("\x1b[32m  ✓ Multi-target incremental build works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Header file dependency invalidation");
    
    auto tempDir = scoped(new TempDir("action-cache-headers"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Setting up project with header dependencies...");
    
    // Create header and multiple sources that include it
    tempDir.createFile("common.h", `
#ifndef COMMON_H
#define COMMON_H
#define VERSION 1
#endif
`);
    
    tempDir.createFile("module1.cpp", `
#include "common.h"
void func1() { int v = VERSION; }
`);
    
    tempDir.createFile("module2.cpp", `
#include "common.h"
void func2() { int v = VERSION; }
`);
    
    auto headerPath = buildPath(tempDir.getPath(), "common.h");
    auto module1Path = buildPath(tempDir.getPath(), "module1.cpp");
    auto module2Path = buildPath(tempDir.getPath(), "module2.cpp");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    writeln("    Initial compilation...");
    
    // Compile both modules (both depend on header)
    ActionId[] compileActions;
    foreach (sourceFile; [module1Path, module2Path])
    {
        ActionId actionId;
        actionId.targetId = "app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash-v1";
        actionId.subId = baseName(sourceFile);
        
        // Include header as input
        string[] inputs = [sourceFile, headerPath];
        
        auto objectFile = setExtension(sourceFile, ".o");
        tempDir.createFile(baseName(objectFile), "object-v1");
        
        cache.update(actionId, inputs, [objectFile], metadata, true);
        compileActions ~= actionId;
    }
    
    writeln("    Both modules compiled");
    
    // Verify both are cached
    foreach (i, sourceFile; [module1Path, module2Path])
    {
        string[] inputs = [sourceFile, headerPath];
        Assert.isTrue(cache.isCached(compileActions[i], inputs, metadata));
    }
    
    writeln("\n  Modifying header file...");
    Thread.sleep(10.msecs);
    tempDir.createFile("common.h", `
#ifndef COMMON_H
#define COMMON_H
#define VERSION 2
#endif
`);
    
    // Both modules should be invalidated
    size_t invalidated = 0;
    foreach (i, sourceFile; [module1Path, module2Path])
    {
        string[] inputs = [sourceFile, headerPath];
        if (!cache.isCached(compileActions[i], inputs, metadata))
        {
            invalidated++;
            writeln("    Invalidated: ", baseName(sourceFile));
        }
    }
    
    Assert.equal(invalidated, 2, "Both modules should be invalidated when header changes");
    
    writeln("\x1b[32m  ✓ Header dependency invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Compilation flag change invalidation");
    
    auto tempDir = scoped(new TempDir("action-cache-flags"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("code.cpp", "int factorial(int n) { return n <= 1 ? 1 : n * factorial(n-1); }");
    auto sourcePath = buildPath(tempDir.getPath(), "code.cpp");
    
    ActionId actionId;
    actionId.targetId = "optimized-lib";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    writeln("  Compiling with -O0 (no optimization)...");
    string[string] metadataO0;
    metadataO0["compiler"] = "g++";
    metadataO0["flags"] = "-O0";
    
    tempDir.createFile("code.o", "object-O0");
    auto objectPath = buildPath(tempDir.getPath(), "code.o");
    
    cache.update(actionId, [sourcePath], [objectPath], metadataO0, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], metadataO0));
    
    writeln("  Changing to -O3 (full optimization)...");
    string[string] metadataO3;
    metadataO3["compiler"] = "g++";
    metadataO3["flags"] = "-O3";
    
    // Should be cache miss with different flags
    Assert.isFalse(cache.isCached(actionId, [sourcePath], metadataO3),
                  "Different optimization flags should invalidate cache");
    
    // Recompile with new flags
    Thread.sleep(5.msecs);
    tempDir.createFile("code.o", "object-O3");
    cache.update(actionId, [sourcePath], [objectPath], metadataO3, true);
    
    // Now cached with new flags
    Assert.isTrue(cache.isCached(actionId, [sourcePath], metadataO3));
    
    // Old flags still not cached
    Assert.isFalse(cache.isCached(actionId, [sourcePath], metadataO0),
                  "Should not match old flags");
    
    writeln("\x1b[32m  ✓ Compilation flag change invalidation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Partial build failure recovery");
    
    auto tempDir = scoped(new TempDir("action-cache-failure"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Building project with intentional failure...");
    
    // Create multiple source files
    tempDir.createFile("good1.cpp", "void func1() {}");
    tempDir.createFile("bad.cpp", "syntax error here!");
    tempDir.createFile("good2.cpp", "void func2() {}");
    
    auto good1Path = buildPath(tempDir.getPath(), "good1.cpp");
    auto badPath = buildPath(tempDir.getPath(), "bad.cpp");
    auto good2Path = buildPath(tempDir.getPath(), "good2.cpp");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Compile good1 - success
    ActionId action1;
    action1.targetId = "app";
    action1.type = ActionType.Compile;
    action1.inputHash = "hash1";
    action1.subId = "good1.cpp";
    
    tempDir.createFile("good1.o", "object1");
    cache.update(action1, [good1Path], [buildPath(tempDir.getPath(), "good1.o")], metadata, true);
    writeln("    good1.cpp: SUCCESS");
    
    // Compile bad - failure
    ActionId action2;
    action2.targetId = "app";
    action2.type = ActionType.Compile;
    action2.inputHash = "hash2";
    action2.subId = "bad.cpp";
    
    cache.update(action2, [badPath], [], metadata, false);
    writeln("    bad.cpp: FAILED");
    
    // Compile good2 - success
    ActionId action3;
    action3.targetId = "app";
    action3.type = ActionType.Compile;
    action3.inputHash = "hash3";
    action3.subId = "good2.cpp";
    
    tempDir.createFile("good2.o", "object2");
    cache.update(action3, [good2Path], [buildPath(tempDir.getPath(), "good2.o")], metadata, true);
    writeln("    good2.cpp: SUCCESS");
    
    auto stats1 = cache.getStats();
    Assert.equal(stats1.successfulActions, 2);
    Assert.equal(stats1.failedActions, 1);
    
    writeln("\n  Fixing bad file and rebuilding...");
    Thread.sleep(10.msecs);
    tempDir.createFile("bad.cpp", "void func_fixed() {}");
    
    // good1 and good2 should be cached
    Assert.isTrue(cache.isCached(action1, [good1Path], metadata), "good1 should be cached");
    Assert.isTrue(cache.isCached(action3, [good2Path], metadata), "good2 should be cached");
    
    // bad should not be cached (failed previously)
    Assert.isFalse(cache.isCached(action2, [badPath], metadata), "bad should not be cached after failure");
    
    // Recompile only bad.cpp
    tempDir.createFile("bad.o", "object-fixed");
    cache.update(action2, [badPath], [buildPath(tempDir.getPath(), "bad.o")], metadata, true);
    writeln("    bad.cpp: SUCCESS (recompiled)");
    writeln("    good1.cpp: CACHED");
    writeln("    good2.cpp: CACHED");
    
    auto stats2 = cache.getStats();
    Assert.equal(stats2.successfulActions, 3, "All actions should now be successful");
    
    writeln("\x1b[32m  ✓ Partial build failure recovery works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache - Large-scale incremental build");
    
    auto tempDir = scoped(new TempDir("action-cache-largescale"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    enum numFiles = 50;
    
    writeln("  Creating ", numFiles, " source files...");
    
    // Create many source files
    foreach (i; 0 .. numFiles)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        auto content = "void func" ~ i.to!string ~ "() { /* implementation */ }";
        tempDir.createFile(filename, content);
    }
    
    writeln("  Initial build of all files...");
    auto startTime = Clock.currTime();
    
    ActionId[] allActions;
    foreach (i; 0 .. numFiles)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        auto sourcePath = buildPath(tempDir.getPath(), filename);
        
        ActionId actionId;
        actionId.targetId = "large-app";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash-v1";
        actionId.subId = filename;
        
        auto objectFile = setExtension(sourcePath, ".o");
        tempDir.createFile(baseName(objectFile), "object-" ~ i.to!string);
        
        cache.update(actionId, [sourcePath], [objectFile], null, true);
        allActions ~= actionId;
    }
    
    auto initialBuildTime = Clock.currTime() - startTime;
    writeln("    Initial build: ", initialBuildTime.total!"msecs", "ms");
    
    auto stats1 = cache.getStats();
    Assert.equal(stats1.totalEntries, numFiles);
    
    writeln("\n  Modifying 5 random files...");
    auto modifiedIndices = [5, 15, 25, 35, 45];
    
    foreach (idx; modifiedIndices)
    {
        Thread.sleep(2.msecs);
        auto filename = "file" ~ idx.to!string ~ ".cpp";
        auto content = "void func" ~ idx.to!string ~ "() { /* MODIFIED */ }";
        tempDir.createFile(filename, content);
    }
    
    writeln("  Incremental rebuild...");
    startTime = Clock.currTime();
    
    size_t cacheHits = 0;
    size_t cacheMisses = 0;
    
    foreach (i; 0 .. numFiles)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        auto sourcePath = buildPath(tempDir.getPath(), filename);
        
        if (cache.isCached(allActions[i], [sourcePath], null))
        {
            cacheHits++;
        }
        else
        {
            cacheMisses++;
            
            // Simulate recompilation
            auto objectFile = setExtension(sourcePath, ".o");
            tempDir.createFile(baseName(objectFile), "object-v2-" ~ i.to!string);
            
            ActionId newActionId;
            newActionId.targetId = "large-app";
            newActionId.type = ActionType.Compile;
            newActionId.inputHash = "hash-v2";
            newActionId.subId = filename;
            
            cache.update(newActionId, [sourcePath], [objectFile], null, true);
        }
    }
    
    auto incrementalBuildTime = Clock.currTime() - startTime;
    writeln("    Incremental build: ", incrementalBuildTime.total!"msecs", "ms");
    
    Assert.equal(cacheHits, numFiles - modifiedIndices.length);
    Assert.equal(cacheMisses, modifiedIndices.length);
    
    auto stats2 = cache.getStats();
    writeln("\n  Final statistics:");
    writeln("    Cache hits: ", cacheHits);
    writeln("    Cache misses: ", cacheMisses);
    writeln("    Hit rate: ", stats2.hitRate, "%");
    
    Assert.isTrue(stats2.hitRate > 85.0, "Hit rate should be very high in large incremental build");
    
    writeln("\x1b[32m  ✓ Large-scale incremental build works efficiently\x1b[0m");
}

