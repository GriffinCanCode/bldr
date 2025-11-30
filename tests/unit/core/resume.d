module tests.unit.core.resume;

import std.stdio;
import std.algorithm;
import std.array;
import std.datetime;
import engine.graph.core.graph;
import engine.runtime.recovery.checkpoint;
import engine.runtime.recovery.resume;
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
    
    auto target4 = Target();
    target4.name = "target4";
    target4.type = TargetType.Executable;
    target4.language = TargetLanguage.D;
    target4.sources = ["test4.d"];
    
    graph.addTarget(target1);
    graph.addTarget(target2);
    graph.addTarget(target3);
    graph.addTarget(target4);
    graph.addDependency("target1", "target2");
    graph.addDependency("target3", "target2");
    graph.addDependency("target4", "target3");
    
    return graph;
}

/// Test resume strategy configuration
unittest
{
    writeln("Testing resume configuration...");
    
    auto config = ResumeConfig.init;
    assert(config.strategy == ResumeStrategy.Smart);
    assert(config.clearOnSuccess);
    assert(config.validateDependencies);
    assert(config.maxCheckpointAge == 24.hours);
    
    writeln("✓ Resume configuration tests passed");
}

/// Test retry failed strategy
unittest
{
    writeln("Testing retry failed strategy...");
    
    auto graph = createTestGraph();
    
    // Setup checkpoint state: target2 succeeded, target3 failed
    graph.nodes["target1"].status = BuildStatus.Pending;
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target2"].hash = "hash2";
    graph.nodes["target3"].status = BuildStatus.Failed;
    graph.nodes["target4"].status = BuildStatus.Pending;
    
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    // Reset graph
    foreach (node; graph.nodes.values)
        node.status = BuildStatus.Pending;
    
    // Plan with RetryFailed strategy
    auto config = ResumeConfig.init;
    config.strategy = ResumeStrategy.RetryFailed;
    auto planner = new ResumePlanner(config);
    
    auto result = planner.plan(checkpoint, graph);
    assert(result.isOk);
    
    auto plan = result.unwrap();
    assert(plan.strategy == ResumeStrategy.RetryFailed);
    
    // Should retry failed target
    assert(plan.targetsToRetry.canFind("target3"));
    
    // Should retry dependents of failed target
    assert(plan.targetsToRetry.canFind("target4"));
    
    // Should skip successful target
    assert(plan.targetsToSkip.canFind("target2"));
    
    writeln("✓ Retry failed strategy tests passed");
}

/// Test skip failed strategy
unittest
{
    writeln("Testing skip failed strategy...");
    
    auto graph = createTestGraph();
    
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target3"].status = BuildStatus.Failed;
    
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    foreach (node; graph.nodes.values)
        node.status = BuildStatus.Pending;
    
    auto config = ResumeConfig.init;
    config.strategy = ResumeStrategy.SkipFailed;
    auto planner = new ResumePlanner(config);
    
    auto result = planner.plan(checkpoint, graph);
    assert(result.isOk);
    
    auto plan = result.unwrap();
    
    // Should skip both failed and successful targets
    assert(plan.targetsToSkip.canFind("target2"));
    assert(plan.targetsToSkip.canFind("target3"));
    
    writeln("✓ Skip failed strategy tests passed");
}

/// Test rebuild all strategy
unittest
{
    writeln("Testing rebuild all strategy...");
    
    auto graph = createTestGraph();
    
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target3"].status = BuildStatus.Failed;
    
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    auto config = ResumeConfig.init;
    config.strategy = ResumeStrategy.RebuildAll;
    auto planner = new ResumePlanner(config);
    
    auto result = planner.plan(checkpoint, graph);
    assert(result.isOk);
    
    auto plan = result.unwrap();
    
    // All nodes should be Pending after rebuild all
    foreach (node; graph.nodes.values)
        assert(node.status == BuildStatus.Pending);
    
    writeln("✓ Rebuild all strategy tests passed");
}

/// Test smart strategy
unittest
{
    writeln("Testing smart resume strategy...");
    
    auto graph = createTestGraph();
    
    graph.nodes["target1"].status = BuildStatus.Pending;
    graph.nodes["target2"].status = BuildStatus.Success;
    graph.nodes["target2"].hash = "hash2";
    graph.nodes["target3"].status = BuildStatus.Failed;
    graph.nodes["target4"].status = BuildStatus.Pending;
    
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    foreach (node; graph.nodes.values)
        node.status = BuildStatus.Pending;
    
    auto config = ResumeConfig.init;
    config.strategy = ResumeStrategy.Smart;
    config.validateDependencies = false; // Disable for simpler test
    auto planner = new ResumePlanner(config);
    
    auto result = planner.plan(checkpoint, graph);
    assert(result.isOk);
    
    auto plan = result.unwrap();
    assert(plan.strategy == ResumeStrategy.Smart);
    
    // Should retry failed targets and their dependents
    assert(plan.targetsToRetry.canFind("target3"));
    assert(plan.targetsToRetry.canFind("target4"));
    
    // Should skip successful targets
    assert(plan.targetsToSkip.canFind("target2"));
    
    writeln("✓ Smart resume strategy tests passed");
}

/// Test estimated savings calculation
unittest
{
    writeln("Testing estimated savings...");
    
    ResumePlan plan;
    plan.targetsToRetry = ["target1", "target2"];
    plan.targetsToSkip = ["target3", "target4", "target5", "target6", "target7", "target8"];
    
    auto savings = plan.estimatedSavings();
    assert(savings > 74.0 && savings < 76.0); // 6/8 = 75%
    
    writeln("✓ Estimated savings tests passed");
}

/// Test invalid checkpoint handling
unittest
{
    writeln("Testing invalid checkpoint handling...");
    
    auto graph1 = createTestGraph();
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph1);
    
    // Create different graph
    auto graph2 = new BuildGraph();
    auto target = Target();
    target.name = "different";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.D;
    target.sources = ["test.d"];
    graph2.addTarget(target);
    
    auto planner = new ResumePlanner(ResumeConfig.init);
    auto result = planner.plan(checkpoint, graph2);
    
    assert(result.isErr);
    assert(result.unwrapErr() == "Checkpoint invalid for current graph");
    
    writeln("✓ Invalid checkpoint handling tests passed");
}

/// Test stale checkpoint detection
unittest
{
    writeln("Testing stale checkpoint detection...");
    
    auto graph = createTestGraph();
    auto manager = new CheckpointManager(".", false);
    auto checkpoint = manager.capture(graph);
    
    // Artificially age the checkpoint
    checkpoint.timestamp = Clock.currTime() - 25.hours;
    
    auto config = ResumeConfig.init;
    config.maxCheckpointAge = 24.hours;
    auto planner = new ResumePlanner(config);
    
    auto result = planner.plan(checkpoint, graph);
    assert(result.isErr);
    assert(result.unwrapErr() == "Checkpoint too old");
    
    writeln("✓ Stale checkpoint detection tests passed");
}

void runResumeTests()
{
    writeln("\n=== Running Resume Tests ===\n");
    
    // Tests run automatically via unittest blocks
    
    writeln("\n=== All Resume Tests Passed ===\n");
}

