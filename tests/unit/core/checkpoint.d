module tests.unit.core.checkpoint;

import std.stdio;
import std.file;
import std.path;
import std.datetime;
import std.algorithm;
import engine.graph.core.graph;
import engine.runtime.recovery.checkpoint;
import infrastructure.config.schema.schema;

/// Helper to create test graph
BuildGraph createTestGraph()
{
    auto graph = new BuildGraph();
    
    auto target1 = Target();
    target1.name = "target1";
    target1.type = TargetType.Executable;
    target1.language = TargetLanguage.D;
    target1.sources = ["test1.d"];
    
    auto target2 = Target();
    target2.name = "target2";
    target2.type = TargetType.Library;
    target2.language = TargetLanguage.D;
    target2.sources = ["test2.d"];
    
    auto target3 = Target();
    target3.name = "target3";
    target3.type = TargetType.Executable;
    target3.language = TargetLanguage.D;
    target3.sources = ["test3.d"];
    
    graph.addTarget(target1);
    graph.addTarget(target2);
    graph.addTarget(target3);
    graph.addDependency("target1", "target2");
    graph.addDependency("target3", "target2");
    
    return graph;
}

/// Test checkpoint capture
unittest
{
    writeln("Testing checkpoint capture...");
    
    auto graph = createTestGraph();
    
    // Set some statuses
    graph.nodes["target1"].status = BuildStatus.Success;
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target3"].status = BuildStatus.Failed;
    
    // Set hashes
    graph.nodes["target1"].hash = "hash1";
    graph.nodes["target2"].hash = "hash2";
    
    auto manager = new CheckpointManager(".", false); // Don't auto-save
    auto checkpoint = manager.capture(graph);
    
    assert(checkpoint.totalTargets == 3);
    assert(checkpoint.completedTargets == 2);
    assert(checkpoint.failedTargets == 1);
    assert(checkpoint.failedTargetIds == ["target3"]);
    
    assert(checkpoint.nodeStates["target1"] == BuildStatus.Success);
    assert(checkpoint.nodeStates["target2"] == BuildStatus.Success);
    assert(checkpoint.nodeStates["target3"] == BuildStatus.Failed);
    
    assert(checkpoint.nodeHashes["target1"] == "hash1");
    assert(checkpoint.nodeHashes["target2"] == "hash2");
    
    assert(checkpoint.completion() > 66.0 && checkpoint.completion() < 67.0);
    
    writeln("✓ Checkpoint capture tests passed");
}

/// Test checkpoint validation
unittest
{
    writeln("Testing checkpoint validation...");
    
    auto graph = createTestGraph();
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    // Valid for same graph
    assert(checkpoint.isValid(graph));
    
    // Invalid if target count changes
    auto graph2 = new BuildGraph();
    auto target1 = Target();
    target1.name = "target1";
    target1.type = TargetType.Executable;
    target1.language = TargetLanguage.D;
    target1.sources = ["test1.d"];
    graph2.addTarget(target1);
    
    assert(!checkpoint.isValid(graph2));
    
    // Invalid if target missing
    auto graph3 = createTestGraph();
    graph3.nodes.remove("target1");
    
    assert(!checkpoint.isValid(graph3));
    
    writeln("✓ Checkpoint validation tests passed");
}

/// Test checkpoint merge
unittest
{
    writeln("Testing checkpoint merge...");
    
    auto graph = createTestGraph();
    
    // Original state
    graph.nodes["target1"].status = BuildStatus.Success;
    graph.nodes["target1"].hash = "hash1";
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target2"].hash = "hash2";
    graph.nodes["target3"].status = BuildStatus.Failed;
    
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    // Reset graph (simulate new build)
    foreach (node; graph.nodes.values)
        node.status = BuildStatus.Pending;
    
    // Merge checkpoint
    checkpoint.mergeWith(graph);
    
    // Success/Cached states should be restored
    assert(graph.nodes["target1"].status == BuildStatus.Success);
    assert(graph.nodes["target1"].hash == "hash1");
    assert(graph.nodes["target2"].status == BuildStatus.Success);
    assert(graph.nodes["target2"].hash == "hash2");
    
    // Failed nodes should remain Pending (not restored)
    assert(graph.nodes["target3"].status == BuildStatus.Pending);
    
    writeln("✓ Checkpoint merge tests passed");
}

/// Test checkpoint serialization
unittest
{
    writeln("Testing checkpoint serialization...");
    
    auto graph = createTestGraph();
    graph.nodes["target1"].status = BuildStatus.Success;
    graph.nodes["target1"].hash = "hash1";
    graph.nodes["target2"].status = BuildStatus.Cached;
    graph.nodes["target2"].hash = "hash2";
    graph.nodes["target3"].status = BuildStatus.Failed;
    
    // Create temporary directory for test
    import std.conv : to;
    string testDir = ".test-checkpoint-" ~ Clock.currTime().toUnixTime().to!string;
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    if (!exists(testDir))
        mkdirRecurse(testDir);
    
    auto manager = new CheckpointManager(testDir, true);
    auto checkpoint1 = manager.capture(graph, testDir);
    
    // Save
    manager.save(checkpoint1);
    assert(manager.exists());
    
    // Load
    auto result = manager.load();
    assert(result.isOk);
    
    auto checkpoint2 = result.unwrap();
    
    // Verify data integrity
    assert(checkpoint2.totalTargets == checkpoint1.totalTargets);
    assert(checkpoint2.completedTargets == checkpoint1.completedTargets);
    assert(checkpoint2.failedTargets == checkpoint1.failedTargets);
    assert(checkpoint2.failedTargetIds == checkpoint1.failedTargetIds);
    
    assert(checkpoint2.nodeStates == checkpoint1.nodeStates);
    assert(checkpoint2.nodeHashes == checkpoint1.nodeHashes);
    
    writeln("✓ Checkpoint serialization tests passed");
}

/// Test checkpoint age tracking
unittest
{
    writeln("Testing checkpoint age tracking...");
    
    import std.conv : to;
    string testDir = ".test-checkpoint-age-" ~ Clock.currTime().toUnixTime().to!string;
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    if (!exists(testDir))
        mkdirRecurse(testDir);
    
    auto manager = new CheckpointManager(testDir, true);
    auto graph = createTestGraph();
    auto checkpoint = manager.capture(graph, testDir);
    
    manager.save(checkpoint);
    
    // Fresh checkpoint should not be stale
    assert(!manager.isStale());
    
    // Age should be very small
    auto age = manager.age();
    assert(age < 1.seconds);
    
    writeln("✓ Checkpoint age tracking tests passed");
}

/// Test checkpoint clear
unittest
{
    writeln("Testing checkpoint clear...");
    
    import std.conv : to;
    string testDir = ".test-checkpoint-clear-" ~ Clock.currTime().toUnixTime().to!string;
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    if (!exists(testDir))
        mkdirRecurse(testDir);
    
    auto manager = new CheckpointManager(testDir, true);
    auto graph = createTestGraph();
    auto checkpoint = manager.capture(graph, testDir);
    
    manager.save(checkpoint);
    assert(manager.exists());
    
    manager.clear();
    assert(!manager.exists());
    
    writeln("✓ Checkpoint clear tests passed");
}

void runCheckpointTests()
{
    writeln("\n=== Running Checkpoint Tests ===\n");
    
    // Tests run automatically via unittest blocks
    
    writeln("\n=== All Checkpoint Tests Passed ===\n");
}

