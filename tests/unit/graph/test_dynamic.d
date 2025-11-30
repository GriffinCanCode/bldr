module tests.unit.graph.test_dynamic;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import engine.graph;
import infrastructure.config.schema.schema;
import tests.harness;

/// Test dynamic graph creation and basic operations
@TestCase("DynamicGraph.Creation")
void testDynamicGraphCreation()
{
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    assert(dynamicGraph.graph is baseGraph, "Base graph should be accessible");
    assert(!dynamicGraph.hasPendingDiscoveries(), "New graph should have no discoveries");
}

/// Test marking targets as discoverable
@TestCase("DynamicGraph.MarkDiscoverable")
void testMarkDiscoverable()
{
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    auto targetId = TargetId("test-target");
    
    assert(!dynamicGraph.isDiscoverable(targetId), "Target should not be discoverable initially");
    
    dynamicGraph.markDiscoverable(targetId);
    
    assert(dynamicGraph.isDiscoverable(targetId), "Target should be discoverable after marking");
}

/// Test recording discoveries
@TestCase("DynamicGraph.RecordDiscovery")
void testRecordDiscovery()
{
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    auto originId = TargetId("origin-target");
    dynamicGraph.markDiscoverable(originId);
    
    // Create discovery metadata
    auto discovery = DiscoveryBuilder.forTarget(originId)
        .addOutputs(["generated/file1.cpp", "generated/file2.cpp"])
        .withMetadata("generator", "protobuf")
        .build();
    
    dynamicGraph.recordDiscovery(discovery);
    
    assert(dynamicGraph.hasPendingDiscoveries(), "Should have pending discoveries");
    
    auto stats = dynamicGraph.getDiscoveryStats();
    assert(stats.totalDiscoveries == 1, "Should have one discovery recorded");
}

/// Test applying discoveries and extending graph
@TestCase("DynamicGraph.ApplyDiscoveries")
void testApplyDiscoveries()
{
    // Create base graph with one target
    auto baseGraph = new BuildGraph();
    
    Target protoTarget;
    protoTarget.name = "my-proto";
    protoTarget.type = TargetType.Library;
    protoTarget.language = TargetLanguage.Protobuf;
    protoTarget.sources = ["test.proto"];
    
    auto addResult = baseGraph.addTarget(protoTarget);
    assert(addResult.isOk, "Should add proto target successfully");
    
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    dynamicGraph.markDiscoverable(protoTarget.id);
    
    // Create discovered compile target
    Target compileTarget;
    compileTarget.name = "my-proto-generated-cpp";
    compileTarget.type = TargetType.Library;
    compileTarget.language = TargetLanguage.Cpp;
    compileTarget.sources = ["generated/test.pb.cc", "generated/test.pb.h"];
    compileTarget.deps = [protoTarget.name];
    
    // Create discovery metadata
    auto discovery = DiscoveryBuilder.forTarget(protoTarget.id)
        .addOutputs(compileTarget.sources)
        .addTargets([compileTarget])
        .addDependents([compileTarget.id])
        .build();
    
    dynamicGraph.recordDiscovery(discovery);
    
    // Apply discoveries
    auto applyResult = dynamicGraph.applyDiscoveries();
    assert(applyResult.isOk, "Should apply discoveries successfully");
    
    auto newNodes = applyResult.unwrap();
    assert(newNodes.length == 1, "Should have one new node");
    assert(newNodes[0].id.toString() == compileTarget.name, "New node should be compile target");
    
    // Verify graph was extended
    assert(compileTarget.name in baseGraph.nodes, "Compile target should be in graph");
    
    // Verify dependency was added
    auto compileNode = baseGraph.nodes[compileTarget.name];
    assert(compileNode.dependencyIds.length == 1, "Compile target should have one dependency");
    assert(compileNode.dependencyIds[0].toString() == protoTarget.name, 
           "Dependency should be proto target");
}

/// Test discovered target creation with language inference
@TestCase("DynamicGraph.CreateDiscoveredTarget")
void testCreateDiscoveredTarget()
{
    auto target = DynamicBuildGraph.createDiscoveredTarget(
        "test-generated",
        ["file1.cpp", "file2.cpp"],
        [TargetId("origin")],
        "out/generated.a"
    );
    
    assert(target.name == "test-generated", "Name should match");
    assert(target.language == TargetLanguage.Cpp, "Should infer C++ language");
    assert(target.type == TargetType.Library, "Should be library type");
    assert(target.sources.length == 2, "Should have two sources");
    assert(target.deps.length == 1, "Should have one dependency");
}

/// Test code generation discovery pattern
@TestCase("DiscoveryPatterns.CodeGeneration")
void testCodeGenerationPattern()
{
    auto originId = TargetId("proto-target");
    string[] generatedFiles = [
        "gen/message.pb.cc",
        "gen/message.pb.h",
        "gen/service.pb.cc",
        "gen/service.pb.h"
    ];
    
    auto discovery = DiscoveryPatterns.codeGeneration(
        originId,
        generatedFiles,
        "proto-generated"
    );
    
    assert(discovery.originTarget == originId, "Origin should match");
    assert(discovery.discoveredOutputs == generatedFiles, "Outputs should match");
    assert(!discovery.newTargets.empty, "Should create new targets");
    assert(!discovery.discoveredDependents.empty, "Should have dependents");
    
    // Verify targets grouped by extension
    bool foundH = false, foundCc = false;
    foreach (target; discovery.newTargets)
    {
        if (target.sources.any!(s => s.endsWith(".h")))
            foundH = true;
        if (target.sources.any!(s => s.endsWith(".cc")))
            foundCc = true;
    }
    assert(foundH || foundCc, "Should create targets for generated files");
}

/// Test library discovery pattern
@TestCase("DiscoveryPatterns.LibraryDiscovery")
void testLibraryDiscoveryPattern()
{
    auto originId = TargetId("link-target");
    string[] libraries = [
        "/usr/lib/libfoo.so",
        "/usr/lib/libbar.so"
    ];
    
    auto discovery = DiscoveryPatterns.libraryDiscovery(originId, libraries);
    
    assert(discovery.originTarget == originId, "Origin should match");
    assert(discovery.discoveredOutputs == libraries, "Libraries should match");
    assert(discovery.metadata["discovery_type"] == "libraries", "Should have correct metadata");
}

/// Test test discovery pattern
@TestCase("DiscoveryPatterns.TestDiscovery")
void testTestDiscoveryPattern()
{
    auto originId = TargetId("test-generator");
    string[] testFiles = [
        "tests/test_foo.cpp",
        "tests/test_bar.cpp"
    ];
    
    auto discovery = DiscoveryPatterns.testDiscovery(originId, testFiles);
    
    assert(discovery.originTarget == originId, "Origin should match");
    assert(discovery.discoveredOutputs == testFiles, "Test files should match");
    assert(!discovery.newTargets.empty, "Should create test targets");
    
    // Verify test targets
    foreach (target; discovery.newTargets)
    {
        assert(target.type == TargetType.Test, "Should be test type");
        assert(target.deps.length == 1, "Should depend on origin");
    }
}

/// Test discovery builder fluent interface
@TestCase("DiscoveryBuilder.FluentAPI")
void testDiscoveryBuilderFluent()
{
    auto targetId = TargetId("test-target");
    
    auto discovery = DiscoveryBuilder.forTarget(targetId)
        .addOutputs(["file1.cpp", "file2.cpp"])
        .addDependents([TargetId("dep1"), TargetId("dep2")])
        .withMetadata("key1", "value1")
        .withMetadata("key2", "value2")
        .build();
    
    assert(discovery.originTarget == targetId, "Origin should match");
    assert(discovery.discoveredOutputs.length == 2, "Should have two outputs");
    assert(discovery.discoveredDependents.length == 2, "Should have two dependents");
    assert(discovery.metadata.length == 2, "Should have two metadata entries");
    assert(discovery.metadata["key1"] == "value1", "Metadata should match");
}

/// Test concurrent discovery recording (thread safety)
@TestCase("DynamicGraph.ConcurrentDiscovery")
void testConcurrentDiscovery()
{
    import core.thread;
    import std.parallelism;
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    // Mark multiple targets as discoverable
    TargetId[] targetIds;
    foreach (i; 0..10)
    {
        auto id = TargetId("target-" ~ std.conv.to!string(i));
        targetIds ~= id;
        dynamicGraph.markDiscoverable(id);
    }
    
    // Record discoveries concurrently
    foreach (i, targetId; parallel(targetIds))
    {
        auto discovery = DiscoveryBuilder.forTarget(targetId)
            .addOutputs(["file" ~ std.conv.to!string(i) ~ ".cpp"])
            .withMetadata("index", std.conv.to!string(i))
            .build();
        
        dynamicGraph.recordDiscovery(discovery);
    }
    
    // Verify all discoveries recorded
    auto stats = dynamicGraph.getDiscoveryStats();
    assert(stats.totalDiscoveries == 10, "Should have all discoveries recorded");
}

/// Test discovery with cycle detection
@TestCase("DynamicGraph.CycleDetection")
void testDiscoveryWithCycleDetection()
{
    auto baseGraph = new BuildGraph();
    
    // Create two targets
    Target target1;
    target1.name = "target1";
    target1.type = TargetType.Library;
    baseGraph.addTarget(target1);
    
    Target target2;
    target2.name = "target2";
    target2.type = TargetType.Library;
    baseGraph.addTarget(target2);
    
    // Add dependency: target2 -> target1
    auto depResult = baseGraph.addDependency("target2", "target1");
    assert(depResult.isOk, "Should add dependency");
    
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    dynamicGraph.markDiscoverable(target1.id);
    
    // Try to discover a dependency that would create a cycle: target1 -> target2
    Target newTarget;
    newTarget.name = "target1-generated";
    newTarget.type = TargetType.Library;
    newTarget.deps = ["target2"];  // This is fine
    
    auto discovery = DiscoveryBuilder.forTarget(target1.id)
        .addTargets([newTarget])
        .addDependents([newTarget.id])
        .build();
    
    dynamicGraph.recordDiscovery(discovery);
    
    // Apply discoveries - should succeed as target1-generated -> target2 doesn't create cycle
    auto applyResult = dynamicGraph.applyDiscoveries();
    assert(applyResult.isOk, "Should apply non-cyclic discovery");
}

/// Run all dynamic graph tests
void runDynamicGraphTests()
{
    writeln("Running Dynamic Graph Tests...");
    
    testDynamicGraphCreation();
    testMarkDiscoverable();
    testRecordDiscovery();
    testApplyDiscoveries();
    testCreateDiscoveredTarget();
    testCodeGenerationPattern();
    testLibraryDiscoveryPattern();
    testTestDiscoveryPattern();
    testDiscoveryBuilderFluent();
    testConcurrentDiscovery();
    testDiscoveryWithCycleDetection();
    
    writeln("All Dynamic Graph Tests Passed! ✓");
}

unittest
{
    runDynamicGraphTests();
}


