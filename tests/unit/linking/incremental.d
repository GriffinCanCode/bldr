module tests.unit.linking.incremental;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import engine.linking.incremental;
import engine.linking.integration;
import engine.caching.actions.action;

/// Unit tests for incremental linking engine
unittest
{
    writeln("=== Incremental Linking Unit Tests ===");
    
    // Test 1: Linker type detection
    testLinkerTypeDetection();
    
    // Test 2: Link state tracking
    testLinkStateTracking();
    
    // Test 3: Link analysis
    testLinkAnalysis();
    
    // Test 4: Platform-specific flag generation
    testLinkerFlags();
    
    // Test 5: LinkerArgs builder
    testLinkerArgsBuilder();
    
    // Test 6: Integration helper
    testIntegrationHelper();
    
    writeln("=== All Incremental Linking Tests Passed ===");
}

/// Test linker type detection from path
void testLinkerTypeDetection()
{
    writeln("  Test: Linker type detection");
    
    // Test LLD detection
    assert(IncrementalLinker.detectLinkerType("/usr/bin/ld.lld") == LinkerType.LLD);
    assert(IncrementalLinker.detectLinkerType("/usr/lib/llvm-17/bin/lld") == LinkerType.LLD);
    
    // Test MSVC detection
    assert(IncrementalLinker.detectLinkerType("link.exe") == LinkerType.MSVC);
    assert(IncrementalLinker.detectLinkerType("C:\\Program Files\\MSVC\\link.exe") == LinkerType.MSVC);
    
    // Test Mold detection
    assert(IncrementalLinker.detectLinkerType("/usr/bin/mold") == LinkerType.Mold);
    
    // Test Gold detection
    assert(IncrementalLinker.detectLinkerType("/usr/bin/ld.gold") == LinkerType.Gold);
    
    // Test ld64 detection
    assert(IncrementalLinker.detectLinkerType("/usr/bin/ld64") == LinkerType.LD64);
    
    writeln("    ✓ Linker type detection works correctly");
}

/// Test link state change tracking
void testLinkStateTracking()
{
    writeln("  Test: Link state tracking");
    
    // Create test link state
    LinkState state;
    state.outputPath = "/tmp/test_output";
    state.outputHash = "abc123";
    state.linkerFlags = "-O2";
    
    // Add some object states
    ObjectState obj1;
    obj1.path = "/tmp/obj1.o";
    obj1.hash = "hash1";
    state.objects ~= obj1;
    
    ObjectState obj2;
    obj2.path = "/tmp/obj2.o";
    obj2.hash = "hash2";
    state.objects ~= obj2;
    
    // Test hasChanges with same objects
    string[] currentObjects = ["/tmp/obj1.o", "/tmp/obj2.o"];
    assert(!state.hasChanges(currentObjects), "Should detect no changes");
    
    // Test hasChanges with different objects
    string[] newObjects = ["/tmp/obj1.o", "/tmp/obj3.o"];
    assert(state.hasChanges(newObjects), "Should detect changes");
    
    // Test hasChanges with different count
    string[] fewerObjects = ["/tmp/obj1.o"];
    assert(state.hasChanges(fewerObjects), "Should detect changes when count differs");
    
    writeln("    ✓ Link state tracking works correctly");
}

/// Test link analysis for incremental decisions
void testLinkAnalysis()
{
    writeln("  Test: Link analysis");
    
    // Test analysis result properties
    LinkAnalysis analysis;
    analysis.strategy = LinkStrategy.Incremental;
    analysis.objectsToLink = ["obj1.o", "obj2.o"];
    analysis.changedObjects = ["obj1.o"];
    analysis.reductionPercent = 50.0;
    
    assert(analysis.canIncrementalLink(), "Should allow incremental link");
    
    // Test full strategy
    LinkAnalysis fullAnalysis;
    fullAnalysis.strategy = LinkStrategy.Full;
    assert(!fullAnalysis.canIncrementalLink(), "Full strategy should not be incremental");
    
    // Test delta strategy
    LinkAnalysis deltaAnalysis;
    deltaAnalysis.strategy = LinkStrategy.Delta;
    assert(deltaAnalysis.canIncrementalLink(), "Delta strategy should be incremental");
    
    writeln("    ✓ Link analysis works correctly");
}

/// Test platform-specific linker flag generation
void testLinkerFlags()
{
    writeln("  Test: Linker flag generation");
    
    // Test LLD flags
    LinkerConfig lldConfig;
    lldConfig.type = LinkerType.LLD;
    lldConfig.supportsIncremental = true;
    
    auto lldFlags = lldConfig.getIncrementalFlags();
    assert(lldFlags.canFind("--incremental"), "LLD should have --incremental flag");
    
    // Test MSVC flags
    LinkerConfig msvcConfig;
    msvcConfig.type = LinkerType.MSVC;
    msvcConfig.supportsIncremental = true;
    
    auto msvcFlags = msvcConfig.getIncrementalFlags();
    assert(msvcFlags.canFind("/INCREMENTAL"), "MSVC should have /INCREMENTAL flag");
    
    // Test Gold flags
    LinkerConfig goldConfig;
    goldConfig.type = LinkerType.Gold;
    goldConfig.supportsIncremental = true;
    
    auto goldFlags = goldConfig.getIncrementalFlags();
    assert(goldFlags.canFind("--incremental"), "Gold should have --incremental flag");
    
    // Test Mold (no incremental - fast enough)
    LinkerConfig moldConfig;
    moldConfig.type = LinkerType.Mold;
    moldConfig.supportsIncremental = false;
    
    auto moldFlags = moldConfig.getIncrementalFlags();
    assert(moldFlags.empty, "Mold should not have incremental flags");
    
    writeln("    ✓ Linker flag generation works correctly");
}

/// Test LinkerArgs builder helper
void testLinkerArgsBuilder()
{
    writeln("  Test: LinkerArgs builder");
    
    // Test LLD args
    auto lldArgs = LinkerArgs.create(LinkerType.LLD);
    lldArgs.output("/tmp/output")
           .libPath("/usr/lib")
           .lib("pthread")
           .incremental()
           .debug_();
    
    assert(lldArgs.args.canFind("-o"), "Should have output flag");
    assert(lldArgs.args.canFind("/tmp/output"), "Should have output path");
    assert(lldArgs.args.canFind("-L"), "Should have lib path flag");
    assert(lldArgs.args.canFind("-lpthread"), "Should have library flag");
    assert(lldArgs.args.canFind("--incremental"), "Should have incremental flag");
    assert(lldArgs.args.canFind("-g"), "Should have debug flag");
    
    // Test MSVC args
    auto msvcArgs = LinkerArgs.create(LinkerType.MSVC);
    msvcArgs.output("C:\\output.exe")
            .libPath("C:\\libs")
            .lib("kernel32")
            .incremental()
            .debug_();
    
    assert(msvcArgs.args.canFind("/OUT:C:\\output.exe"), "Should have MSVC output flag");
    assert(msvcArgs.args.canFind("/LIBPATH:C:\\libs"), "Should have MSVC lib path");
    assert(msvcArgs.args.canFind("kernel32.lib"), "Should have MSVC library");
    assert(msvcArgs.args.canFind("/INCREMENTAL"), "Should have MSVC incremental flag");
    assert(msvcArgs.args.canFind("/DEBUG"), "Should have MSVC debug flag");
    
    writeln("    ✓ LinkerArgs builder works correctly");
}

/// Test integration helper
void testIntegrationHelper()
{
    writeln("  Test: Integration helper");
    
    // Test hasIncrementalSupport
    assert(hasIncrementalSupport("/usr/bin/ld.lld"), "LLD should support incremental");
    assert(hasIncrementalSupport("link.exe"), "MSVC should support incremental");
    assert(hasIncrementalSupport("/usr/bin/ld.gold"), "Gold should support incremental");
    
    // Test addIncrementalFlags
    string[] baseCmd = ["ld", "-o", "output"];
    auto lldCmd = addIncrementalFlags(baseCmd, LinkerType.LLD);
    assert(lldCmd.canFind("--incremental"), "Should add LLD incremental flag");
    
    auto msvcCmd = addIncrementalFlags(baseCmd, LinkerType.MSVC);
    assert(msvcCmd.canFind("/INCREMENTAL"), "Should add MSVC incremental flag");
    
    writeln("    ✓ Integration helper works correctly");
}

/// Test LinkerConfig good incremental support detection
unittest
{
    writeln("  Test: LinkerConfig incremental support");
    
    LinkerConfig lld;
    lld.type = LinkerType.LLD;
    assert(lld.hasGoodIncrementalSupport(), "LLD should have good support");
    
    LinkerConfig msvc;
    msvc.type = LinkerType.MSVC;
    assert(msvc.hasGoodIncrementalSupport(), "MSVC should have good support");
    
    LinkerConfig gold;
    gold.type = LinkerType.Gold;
    assert(gold.hasGoodIncrementalSupport(), "Gold should have good support");
    
    LinkerConfig gnu;
    gnu.type = LinkerType.GNU_LD;
    assert(!gnu.hasGoodIncrementalSupport(), "GNU LD should not have good support");
    
    LinkerConfig mold;
    mold.type = LinkerType.Mold;
    assert(!mold.hasGoodIncrementalSupport(), "Mold doesn't need incremental - it's fast");
    
    writeln("    ✓ LinkerConfig incremental support detection works");
}

/// Test delta link flags
unittest
{
    writeln("  Test: Delta link flags");
    
    LinkerConfig lld;
    lld.type = LinkerType.LLD;
    auto lldDelta = lld.getDeltaLinkFlags();
    assert(lldDelta.canFind("-r"), "LLD delta should have relocatable flag");
    assert(lldDelta.canFind("--incremental"), "LLD delta should have incremental");
    
    LinkerConfig msvc;
    msvc.type = LinkerType.MSVC;
    auto msvcDelta = msvc.getDeltaLinkFlags();
    assert(msvcDelta.canFind("/INCREMENTAL"), "MSVC delta should have incremental");
    assert(msvcDelta.canFind("/LTCG:incremental"), "MSVC delta should have LTCG incremental");
    
    writeln("    ✓ Delta link flags work correctly");
}

/// Test LinkingConfig struct
unittest
{
    writeln("  Test: LinkingConfig struct");
    
    LinkingConfig config;
    config.objectFiles = ["a.o", "b.o"];
    config.outputPath = "/tmp/output";
    config.libraries = ["pthread", "m"];
    config.libraryPaths = ["/usr/lib"];
    config.systemLibs = ["c"];
    config.extraFlags = ["-O2"];
    config.useIncrementalLink = true;
    config.debugInfo = false;
    config.strip = true;
    config.lto = false;
    
    assert(config.objectFiles.length == 2);
    assert(config.libraries.canFind("pthread"));
    assert(config.useIncrementalLink);
    
    writeln("    ✓ LinkingConfig struct works correctly");
}

/// Test LinkResult struct
unittest
{
    writeln("  Test: LinkResult struct");
    
    LinkResult result;
    result.success = true;
    result.wasIncremental = true;
    result.reductionPercent = 75.0;
    result.outputHash = "abc123";
    
    assert(result.success);
    assert(result.wasIncremental);
    assert(result.reductionPercent > 50.0);
    
    writeln("    ✓ LinkResult struct works correctly");
}

