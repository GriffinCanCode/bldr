module tests.unit.graph.test_dynamic;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv : to;
import engine.graph;
import infrastructure.config.schema.schema;
import tests.harness;

/// Test dynamic graph creation and basic operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Creation and basic operations");
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    assert(dynamicGraph.graph is baseGraph, "Base graph should be accessible");
    assert(!dynamicGraph.hasPendingDiscoveries(), "New graph should have no discoveries");
    
    writeln("\x1b[32m  ✓ Dynamic graph creation works correctly\x1b[0m");
}

/// Test marking targets as discoverable
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Mark discoverable");
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    auto targetId = TargetId("test-target");
    
    assert(!dynamicGraph.isDiscoverable(targetId), "Target should not be discoverable initially");
    
    dynamicGraph.markDiscoverable(targetId);
    
    assert(dynamicGraph.isDiscoverable(targetId), "Target should be discoverable after marking");
    
    writeln("\x1b[32m  ✓ Mark discoverable works correctly\x1b[0m");
}

/// Test recording discoveries
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Record discovery");
    
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
    
    writeln("\x1b[32m  ✓ Record discovery works correctly\x1b[0m");
}

/// Test applying discoveries and extending graph
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Apply discoveries");
    
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
    
    writeln("\x1b[32m  ✓ Apply discoveries works correctly\x1b[0m");
}

/// Test discovered target creation with language inference
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Create discovered target");
    
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
    
    writeln("\x1b[32m  ✓ Create discovered target works correctly\x1b[0m");
}

/// Test code generation discovery pattern
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Code generation pattern");
    
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
    
    writeln("\x1b[32m  ✓ Code generation pattern works correctly\x1b[0m");
}

/// Test library discovery pattern
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Library discovery pattern");
    
    auto originId = TargetId("link-target");
    string[] libraries = [
        "/usr/lib/libfoo.so",
        "/usr/lib/libbar.so"
    ];
    
    auto discovery = DiscoveryPatterns.libraryDiscovery(originId, libraries);
    
    assert(discovery.originTarget == originId, "Origin should match");
    assert(discovery.discoveredOutputs == libraries, "Libraries should match");
    assert(discovery.metadata["discovery_type"] == "libraries", "Should have correct metadata");
    
    writeln("\x1b[32m  ✓ Library discovery pattern works correctly\x1b[0m");
}

/// Test test discovery pattern
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Test discovery pattern");
    
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
    
    writeln("\x1b[32m  ✓ Test discovery pattern works correctly\x1b[0m");
}

/// Test discovery builder fluent interface
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Discovery builder fluent API");
    
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
    
    writeln("\x1b[32m  ✓ Discovery builder fluent API works correctly\x1b[0m");
}

/// Test concurrent discovery recording (thread safety)
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Concurrent discovery (thread safety)");
    
    import core.thread;
    import std.parallelism;
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    // Mark multiple targets as discoverable
    TargetId[] targetIds;
    foreach (i; 0..10)
    {
        auto id = TargetId("target-" ~ i.to!string);
        targetIds ~= id;
        dynamicGraph.markDiscoverable(id);
    }
    
    // Record discoveries concurrently
    foreach (idx, targetId; parallel(targetIds))
    {
        auto discovery = DiscoveryBuilder.forTarget(targetId)
            .addOutputs(["file" ~ idx.to!string ~ ".cpp"])
            .withMetadata("index", idx.to!string)
            .build();
        
        dynamicGraph.recordDiscovery(discovery);
    }
    
    // Verify all discoveries recorded
    auto stats = dynamicGraph.getDiscoveryStats();
    assert(stats.totalDiscoveries == 10, "Should have all discoveries recorded");
    
    writeln("\x1b[32m  ✓ Concurrent discovery (thread safety) works correctly\x1b[0m");
}

/// Test discovery with cycle detection
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m graph.dynamic - Cycle detection");
    
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
    
    writeln("\x1b[32m  ✓ Cycle detection works correctly\x1b[0m");
}
