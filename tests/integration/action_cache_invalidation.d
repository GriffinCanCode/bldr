module tests.integration.action_cache_invalidation;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.algorithm;
import std.array;
import core.thread;
import core.time;
import engine.caching.actions.action;
import tests.harness;
import tests.fixtures;

/// Integration tests focused on cache invalidation correctness
/// 
/// These tests verify that the action cache correctly invalidates
/// entries when inputs, outputs, or metadata change in various scenarios.

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Input file modification");
    
    auto tempDir = scoped(new TempDir("invalidation-input"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Initial compilation...");
    tempDir.createFile("source.cpp", "int add(int a, int b) { return a + b; }");
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    
    ActionId actionId;
    actionId.targetId = "math-lib";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "v1";
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    metadata["flags"] = "-O2";
    
    tempDir.createFile("source.o", "binary-v1");
    auto outputPath = buildPath(tempDir.getPath(), "source.o");
    
    cache.update(actionId, [sourcePath], [outputPath], metadata, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], metadata));
    writeln("    Cached successfully");
    
    // Test 1: Modify content
    writeln("\n  Test 1: Content modification");
    Thread.sleep(10.msecs);
    tempDir.createFile("source.cpp", "int add(int a, int b) { return a + b + 0; }");
    Assert.isFalse(cache.isCached(actionId, [sourcePath], metadata));
    writeln("    ✓ Content change detected");
    
    // Update cache with new content
    tempDir.createFile("source.o", "binary-v2");
    cache.update(actionId, [sourcePath], [outputPath], metadata, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], metadata));
    
    // Test 2: Touch file (modify timestamp but not content)
    writeln("\n  Test 2: Timestamp-only modification");
    Thread.sleep(10.msecs);
    auto content = readText(sourcePath);
    std.file.write(sourcePath, content); // Rewrite same content (updates timestamp)
    
    // Should still be cached (content hash unchanged)
    Assert.isTrue(cache.isCached(actionId, [sourcePath], metadata));
    writeln("    ✓ Timestamp-only change ignored (content hash same)");
    
    writeln("\x1b[32m  ✓ Input file modification invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Output file deletion");
    
    auto tempDir = scoped(new TempDir("invalidation-output"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("input.cpp", "void func() {}");
    auto inputPath = buildPath(tempDir.getPath(), "input.cpp");
    
    tempDir.createFile("output.o", "binary");
    auto outputPath = buildPath(tempDir.getPath(), "output.o");
    
    ActionId actionId;
    actionId.targetId = "lib";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    cache.update(actionId, [inputPath], [outputPath], null, true);
    Assert.isTrue(cache.isCached(actionId, [inputPath], null));
    writeln("    Initial cache: valid");
    
    // Delete output file
    writeln("\n  Deleting output file...");
    remove(outputPath);
    
    // Cache should be invalidated
    Assert.isFalse(cache.isCached(actionId, [inputPath], null));
    writeln("    ✓ Cache invalidated when output missing");
    
    // Recreate output
    tempDir.createFile("output.o", "binary-recreated");
    cache.update(actionId, [inputPath], [outputPath], null, true);
    Assert.isTrue(cache.isCached(actionId, [inputPath], null));
    writeln("    Cache restored after output recreation");
    
    writeln("\x1b[32m  ✓ Output file deletion invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Metadata changes");
    
    auto tempDir = scoped(new TempDir("invalidation-metadata"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    tempDir.createFile("code.cpp", "int factorial(int n) { return n <= 1 ? 1 : n * factorial(n-1); }");
    auto sourcePath = buildPath(tempDir.getPath(), "code.cpp");
    auto outputPath = buildPath(tempDir.getPath(), "code.o");
    
    ActionId actionId;
    actionId.targetId = "optimized";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    writeln("  Test different metadata changes...");
    
    // Test 1: Compiler flags change
    writeln("\n  Test 1: Compiler flags");
    string[string] meta1;
    meta1["compiler"] = "g++";
    meta1["flags"] = "-O0";
    
    tempDir.createFile("code.o", "object-O0");
    cache.update(actionId, [sourcePath], [outputPath], meta1, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], meta1));
    
    string[string] meta2;
    meta2["compiler"] = "g++";
    meta2["flags"] = "-O3";
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta2));
    writeln("    ✓ Flag change detected (-O0 vs -O3)");
    
    // Test 2: Additional metadata key
    writeln("\n  Test 2: Additional metadata key");
    string[string] meta3;
    meta3["compiler"] = "g++";
    meta3["flags"] = "-O0";
    meta3["debug"] = "true";
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta3));
    writeln("    ✓ Additional key detected");
    
    // Test 3: Missing metadata key
    writeln("\n  Test 3: Missing metadata key");
    string[string] meta4;
    meta4["compiler"] = "g++";
    // "flags" key missing
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta4));
    writeln("    ✓ Missing key detected");
    
    // Test 4: Compiler change
    writeln("\n  Test 4: Compiler change");
    string[string] meta5;
    meta5["compiler"] = "clang++";
    meta5["flags"] = "-O0";
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta5));
    writeln("    ✓ Compiler change detected (g++ vs clang++)");
    
    // Test 5: Empty metadata
    writeln("\n  Test 5: Empty metadata");
    string[string] emptyMeta;
    
    tempDir.createFile("code.o", "object-no-meta");
    cache.update(actionId, [sourcePath], [outputPath], emptyMeta, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], emptyMeta));
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta1));
    writeln("    ✓ Empty vs non-empty metadata detected");
    
    writeln("\x1b[32m  ✓ Metadata change invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Multiple input files");
    
    auto tempDir = scoped(new TempDir("invalidation-multi-input"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Creating link action with multiple inputs...");
    
    tempDir.createFile("obj1.o", "binary1");
    tempDir.createFile("obj2.o", "binary2");
    tempDir.createFile("obj3.o", "binary3");
    
    auto obj1 = buildPath(tempDir.getPath(), "obj1.o");
    auto obj2 = buildPath(tempDir.getPath(), "obj2.o");
    auto obj3 = buildPath(tempDir.getPath(), "obj3.o");
    
    ActionId linkAction;
    linkAction.targetId = "app";
    linkAction.type = ActionType.Link;
    linkAction.inputHash = "link-v1";
    
    string[] inputs = [obj1, obj2, obj3];
    tempDir.createFile("app", "executable");
    auto appPath = buildPath(tempDir.getPath(), "app");
    
    cache.update(linkAction, inputs, [appPath], null, true);
    Assert.isTrue(cache.isCached(linkAction, inputs, null));
    writeln("    Initial link cached");
    
    // Test 1: Modify one input
    writeln("\n  Test 1: Modify obj2.o");
    Thread.sleep(10.msecs);
    tempDir.createFile("obj2.o", "binary2-modified");
    Assert.isFalse(cache.isCached(linkAction, inputs, null));
    writeln("    ✓ Single input modification detected");
    
    // Update cache
    tempDir.createFile("app", "executable-v2");
    cache.update(linkAction, inputs, [appPath], null, true);
    Assert.isTrue(cache.isCached(linkAction, inputs, null));
    
    // Test 2: Modify multiple inputs
    writeln("\n  Test 2: Modify obj1.o and obj3.o");
    Thread.sleep(10.msecs);
    tempDir.createFile("obj1.o", "binary1-modified");
    tempDir.createFile("obj3.o", "binary3-modified");
    Assert.isFalse(cache.isCached(linkAction, inputs, null));
    writeln("    ✓ Multiple input modifications detected");
    
    // Update cache
    tempDir.createFile("app", "executable-v3");
    cache.update(linkAction, inputs, [appPath], null, true);
    Assert.isTrue(cache.isCached(linkAction, inputs, null));
    
    // Test 3: Reorder inputs (should still be valid)
    writeln("\n  Test 3: Reorder inputs");
    string[] reorderedInputs = [obj3, obj1, obj2];
    // Note: Input order matters for cache key, so this is a cache miss
    Assert.isFalse(cache.isCached(linkAction, reorderedInputs, null));
    writeln("    ✓ Input order matters for cache key");
    
    // Test 4: Add an input
    writeln("\n  Test 4: Add new input file");
    tempDir.createFile("obj4.o", "binary4");
    auto obj4 = buildPath(tempDir.getPath(), "obj4.o");
    string[] extendedInputs = [obj1, obj2, obj3, obj4];
    Assert.isFalse(cache.isCached(linkAction, extendedInputs, null));
    writeln("    ✓ Additional input detected");
    
    // Test 5: Remove an input
    writeln("\n  Test 5: Remove input file");
    string[] reducedInputs = [obj1, obj2];
    Assert.isFalse(cache.isCached(linkAction, reducedInputs, null));
    writeln("    ✓ Removed input detected");
    
    writeln("\x1b[32m  ✓ Multiple input file invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Cascading dependency invalidation");
    
    auto tempDir = scoped(new TempDir("invalidation-cascade"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Building dependency chain: base -> middle -> top");
    
    // Create dependency chain
    tempDir.createFile("base.cpp", "int base_value = 1;");
    tempDir.createFile("middle.cpp", "int middle_value = 2;");
    tempDir.createFile("top.cpp", "int top_value = 3;");
    
    auto baseCpp = buildPath(tempDir.getPath(), "base.cpp");
    auto middleCpp = buildPath(tempDir.getPath(), "middle.cpp");
    auto topCpp = buildPath(tempDir.getPath(), "top.cpp");
    
    auto baseO = buildPath(tempDir.getPath(), "base.o");
    auto middleO = buildPath(tempDir.getPath(), "middle.o");
    auto topO = buildPath(tempDir.getPath(), "top.o");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Build base
    ActionId baseCompile;
    baseCompile.targetId = "base";
    baseCompile.type = ActionType.Compile;
    baseCompile.inputHash = "base-v1";
    tempDir.createFile("base.o", "base-obj-v1");
    cache.update(baseCompile, [baseCpp], [baseO], metadata, true);
    
    ActionId baseLink;
    baseLink.targetId = "base";
    baseLink.type = ActionType.Link;
    baseLink.inputHash = "base-link-v1";
    tempDir.createFile("libbase.a", "base-lib-v1");
    auto baseLib = buildPath(tempDir.getPath(), "libbase.a");
    cache.update(baseLink, [baseO], [baseLib], metadata, true);
    
    // Build middle (depends on base)
    ActionId middleCompile;
    middleCompile.targetId = "middle";
    middleCompile.type = ActionType.Compile;
    middleCompile.inputHash = "middle-v1";
    tempDir.createFile("middle.o", "middle-obj-v1");
    cache.update(middleCompile, [middleCpp], [middleO], metadata, true);
    
    ActionId middleLink;
    middleLink.targetId = "middle";
    middleLink.type = ActionType.Link;
    middleLink.inputHash = "middle-link-v1";
    tempDir.createFile("libmiddle.a", "middle-lib-v1");
    auto middleLib = buildPath(tempDir.getPath(), "libmiddle.a");
    cache.update(middleLink, [middleO, baseLib], [middleLib], metadata, true);
    
    // Build top (depends on middle)
    ActionId topCompile;
    topCompile.targetId = "top";
    topCompile.type = ActionType.Compile;
    topCompile.inputHash = "top-v1";
    tempDir.createFile("top.o", "top-obj-v1");
    cache.update(topCompile, [topCpp], [topO], metadata, true);
    
    ActionId topLink;
    topLink.targetId = "top";
    topLink.type = ActionType.Link;
    topLink.inputHash = "top-link-v1";
    tempDir.createFile("top", "top-app-v1");
    auto topApp = buildPath(tempDir.getPath(), "top");
    cache.update(topLink, [topO, middleLib], [topApp], metadata, true);
    
    writeln("    All cached initially");
    
    // Verify all cached
    Assert.isTrue(cache.isCached(baseCompile, [baseCpp], metadata));
    Assert.isTrue(cache.isCached(baseLink, [baseO], metadata));
    Assert.isTrue(cache.isCached(middleCompile, [middleCpp], metadata));
    Assert.isTrue(cache.isCached(middleLink, [middleO, baseLib], metadata));
    Assert.isTrue(cache.isCached(topCompile, [topCpp], metadata));
    Assert.isTrue(cache.isCached(topLink, [topO, middleLib], metadata));
    
    writeln("\n  Modifying base library...");
    Thread.sleep(10.msecs);
    tempDir.createFile("base.cpp", "int base_value = 100;");
    
    // Check invalidation cascade
    writeln("    Checking cache status...");
    
    // Base compilation invalidated
    Assert.isFalse(cache.isCached(baseCompile, [baseCpp], metadata));
    writeln("      base compile: INVALIDATED ✓");
    
    // Recompile and relink base
    tempDir.createFile("base.o", "base-obj-v2");
    cache.update(baseCompile, [baseCpp], [baseO], metadata, true);
    
    tempDir.createFile("libbase.a", "base-lib-v2");
    ActionId baseLink2;
    baseLink2.targetId = "base";
    baseLink2.type = ActionType.Link;
    baseLink2.inputHash = "base-link-v2";
    cache.update(baseLink2, [baseO], [baseLib], metadata, true);
    
    // Middle compilation still valid (source unchanged)
    Assert.isTrue(cache.isCached(middleCompile, [middleCpp], metadata));
    writeln("      middle compile: VALID ✓");
    
    // Middle linking invalidated (base lib changed)
    Assert.isFalse(cache.isCached(middleLink, [middleO, baseLib], metadata));
    writeln("      middle link: INVALIDATED ✓");
    
    // Relink middle
    tempDir.createFile("libmiddle.a", "middle-lib-v2");
    ActionId middleLink2;
    middleLink2.targetId = "middle";
    middleLink2.type = ActionType.Link;
    middleLink2.inputHash = "middle-link-v2";
    cache.update(middleLink2, [middleO, baseLib], [middleLib], metadata, true);
    
    // Top compilation still valid
    Assert.isTrue(cache.isCached(topCompile, [topCpp], metadata));
    writeln("      top compile: VALID ✓");
    
    // Top linking invalidated (middle lib changed)
    Assert.isFalse(cache.isCached(topLink, [topO, middleLib], metadata));
    writeln("      top link: INVALIDATED ✓");
    
    writeln("\x1b[32m  ✓ Cascading dependency invalidation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Cross-target isolation");
    
    auto tempDir = scoped(new TempDir("invalidation-isolation"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Creating two independent targets with same source names...");
    
    // Target A
    tempDir.createFile("targetA/main.cpp", "int main_a() { return 1; }");
    auto mainA = buildPath(tempDir.getPath(), "targetA/main.cpp");
    
    ActionId actionA;
    actionA.targetId = "targetA";
    actionA.type = ActionType.Compile;
    actionA.inputHash = "hashA";
    actionA.subId = "main.cpp";
    
    tempDir.createFile("targetA/main.o", "binary-A");
    auto outputA = buildPath(tempDir.getPath(), "targetA/main.o");
    cache.update(actionA, [mainA], [outputA], null, true);
    
    // Target B (different target, same file name)
    tempDir.createFile("targetB/main.cpp", "int main_b() { return 2; }");
    auto mainB = buildPath(tempDir.getPath(), "targetB/main.cpp");
    
    ActionId actionB;
    actionB.targetId = "targetB";
    actionB.type = ActionType.Compile;
    actionB.inputHash = "hashB";
    actionB.subId = "main.cpp";
    
    tempDir.createFile("targetB/main.o", "binary-B");
    auto outputB = buildPath(tempDir.getPath(), "targetB/main.o");
    cache.update(actionB, [mainB], [outputB], null, true);
    
    writeln("    Both targets cached");
    Assert.isTrue(cache.isCached(actionA, [mainA], null));
    Assert.isTrue(cache.isCached(actionB, [mainB], null));
    
    writeln("\n  Modifying targetA source...");
    Thread.sleep(10.msecs);
    tempDir.createFile("targetA/main.cpp", "int main_a() { return 100; }");
    
    // Target A should be invalidated
    Assert.isFalse(cache.isCached(actionA, [mainA], null));
    writeln("    targetA: INVALIDATED ✓");
    
    // Target B should remain valid (different target)
    Assert.isTrue(cache.isCached(actionB, [mainB], null));
    writeln("    targetB: VALID ✓");
    
    writeln("\x1b[32m  ✓ Cross-target isolation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Failed action not cached");
    
    auto tempDir = scoped(new TempDir("invalidation-failure"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Recording successful and failed actions...");
    
    tempDir.createFile("good.cpp", "void good() {}");
    tempDir.createFile("bad.cpp", "syntax error");
    
    auto goodPath = buildPath(tempDir.getPath(), "good.cpp");
    auto badPath = buildPath(tempDir.getPath(), "bad.cpp");
    
    // Successful action
    ActionId goodAction;
    goodAction.targetId = "app";
    goodAction.type = ActionType.Compile;
    goodAction.inputHash = "good-hash";
    
    tempDir.createFile("good.o", "object");
    cache.update(goodAction, [goodPath], [buildPath(tempDir.getPath(), "good.o")], null, true);
    
    // Failed action
    ActionId badAction;
    badAction.targetId = "app";
    badAction.type = ActionType.Compile;
    badAction.inputHash = "bad-hash";
    
    cache.update(badAction, [badPath], [], null, false);
    
    writeln("    Good action: success=true");
    writeln("    Bad action: success=false");
    
    // Good action is cached
    Assert.isTrue(cache.isCached(goodAction, [goodPath], null));
    writeln("\n  Good action: CACHED ✓");
    
    // Failed action is not cached
    Assert.isFalse(cache.isCached(badAction, [badPath], null));
    writeln("  Bad action: NOT CACHED ✓");
    
    // Fix bad file
    writeln("\n  Fixing bad.cpp...");
    Thread.sleep(10.msecs);
    tempDir.createFile("bad.cpp", "void fixed() {}");
    
    // Still not cached (needs rebuild)
    Assert.isFalse(cache.isCached(badAction, [badPath], null));
    writeln("    Still not cached (requires rebuild)");
    
    // Rebuild successfully
    tempDir.createFile("bad.o", "object-fixed");
    cache.update(badAction, [badPath], [buildPath(tempDir.getPath(), "bad.o")], null, true);
    
    // Now cached
    Assert.isTrue(cache.isCached(badAction, [badPath], null));
    writeln("    Now cached after successful build ✓");
    
    writeln("\x1b[32m  ✓ Failed action handling works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[INTEGRATION TEST]\x1b[0m ActionCache Invalidation - Environment variable changes");
    
    auto tempDir = scoped(new TempDir("invalidation-env"));
    auto cacheDir = buildPath(tempDir.getPath(), ".action-cache");
    auto cache = new ActionCache(cacheDir);
    
    writeln("  Testing environment-sensitive compilation...");
    
    tempDir.createFile("env_sensitive.cpp", "#ifdef DEBUG\nint debug_mode = 1;\n#endif");
    auto sourcePath = buildPath(tempDir.getPath(), "env_sensitive.cpp");
    
    ActionId actionId;
    actionId.targetId = "env-app";
    actionId.type = ActionType.Compile;
    actionId.inputHash = "hash1";
    
    // Compile without DEBUG
    string[string] meta1;
    meta1["compiler"] = "g++";
    meta1["defines"] = "";
    
    tempDir.createFile("env_sensitive.o", "obj-no-debug");
    auto outputPath = buildPath(tempDir.getPath(), "env_sensitive.o");
    cache.update(actionId, [sourcePath], [outputPath], meta1, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], meta1));
    writeln("    Compiled without DEBUG define");
    
    // Compile with DEBUG
    string[string] meta2;
    meta2["compiler"] = "g++";
    meta2["defines"] = "-DDEBUG";
    
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta2));
    writeln("    Cache miss with DEBUG define ✓");
    
    tempDir.createFile("env_sensitive.o", "obj-with-debug");
    cache.update(actionId, [sourcePath], [outputPath], meta2, true);
    Assert.isTrue(cache.isCached(actionId, [sourcePath], meta2));
    writeln("    Compiled with DEBUG define");
    
    // Original (no DEBUG) should still be separate
    Assert.isFalse(cache.isCached(actionId, [sourcePath], meta1));
    writeln("    Original metadata still produces cache miss ✓");
    
    writeln("\x1b[32m  ✓ Environment variable change detection works\x1b[0m");
}

