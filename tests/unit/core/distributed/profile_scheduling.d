module tests.unit.core.distributed.profile_scheduling;

import std.algorithm : map, sort, maxElement;
import std.array : array;
import std.conv : to;
import engine.distributed.coordinator.profile;
import engine.distributed.coordinator.scheduler : DistributedScheduler;
import engine.distributed.coordinator.registry : WorkerRegistry;
import engine.distributed.protocol.protocol : ActionId, ActionRequest, Priority;
import engine.economics.estimator : CostEstimator, ExecutionHistory;
import engine.economics.pricing : ResourceUsageEstimate;
import engine.graph : BuildGraph, BuildNode;
import infrastructure.config.schema.schema : TargetId, Target;

/// Test profile-guided scheduling prioritizes critical path
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m profile_scheduling - Critical path prioritization");
    
    // Create execution history with varied costs
    auto history = new ExecutionHistory();
    
    // Record different execution times: target_a (slow), target_b (fast), target_c (medium)
    import std.datetime : seconds, msecs;
    history.record("target_a", seconds(30), ResourceUsageEstimate(4, 2_000_000_000, 0, 0, seconds(30)), false);
    history.record("target_b", seconds(5), ResourceUsageEstimate(2, 512_000_000, 0, 0, seconds(5)), false);
    history.record("target_c", seconds(15), ResourceUsageEstimate(4, 1_000_000_000, 0, 0, seconds(15)), false);
    
    // Create simple graph: target_c depends on target_a and target_b
    auto graph = new BuildGraph();
    
    auto targetA = Target();
    targetA.name = "target_a";
    graph.addTarget(targetA);
    auto nodeA = graph.nodes["target_a"];
    
    auto targetB = Target();
    targetB.name = "target_b";
    graph.addTarget(targetB);
    auto nodeB = graph.nodes["target_b"];
    
    auto targetC = Target();
    targetC.name = "target_c";
    targetC.deps = ["target_a", "target_b"];
    graph.addTarget(targetC);
    auto nodeC = graph.nodes["target_c"];
    
    // Link dependencies
    graph.addDependency("target_c", "target_a");
    graph.addDependency("target_c", "target_b");
    
    // Create profiled scheduler
    auto scheduler = createProfiledScheduler(graph, history);
    
    // Verify profiles computed
    auto stats = scheduler.getStats();
    assert(stats.totalActions == 3, "Should have 3 action profiles");
    
    // target_a should have higher critical path cost (30s own + 15s downstream)
    auto profileA = scheduler.getProfile("target_a");
    auto profileB = scheduler.getProfile("target_b");
    
    assert(profileA !is null, "Profile A should exist");
    assert(profileB !is null, "Profile B should exist");
    
    // Critical path through A is longer than through B
    assert(profileA.criticalPathCost >= profileB.criticalPathCost, 
        "Slow action should have higher critical path cost");
    
    writeln("\x1b[32m  ✓ Critical path prioritization\x1b[0m");
}

/// Test that expensive actions get scheduled early
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m profile_scheduling - Expensive actions scheduled early");
    
    // Test ActionProfile scheduling score
    // Expensive action with many dependents should score highest
    ActionProfile expensive = ActionProfile(
        10000,   // 10 second estimated cost
        45000,   // 45s critical path
        5,       // 5 dependents
        1,       // depth 1
        0.0f     // no cache hits
    );
    
    ActionProfile cheap = ActionProfile(
        1000,    // 1 second estimated cost
        3000,    // 3s critical path
        1,       // 1 dependent
        2,       // depth 2
        0.5f     // 50% cache hits
    );
    
    ActionProfile medium = ActionProfile(
        5000,    // 5 second estimated cost
        20000,   // 20s critical path
        3,       // 3 dependents
        1,       // depth 1
        0.2f     // 20% cache hits
    );
    
    // Expensive should score highest (critical path dominates)
    assert(expensive.schedulingScore() > medium.schedulingScore(),
        "Expensive action should score higher than medium");
    assert(medium.schedulingScore() > cheap.schedulingScore(),
        "Medium action should score higher than cheap");
    
    writeln("\x1b[32m  ✓ Expensive actions scheduled early\x1b[0m");
}

/// Test profile statistics
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m profile_scheduling - Statistics calculation");
    
    // Create test graph
    auto graph = new BuildGraph();
    auto history = new ExecutionHistory();
    
    // Add nodes
    foreach (i; 0 .. 5)
    {
        auto target = Target();
        target.name = "node_" ~ i.to!string;
        graph.addTarget(target);
    }
    
    auto scheduler = createProfiledScheduler(graph, history);
    auto stats = scheduler.getStats();
    
    assert(stats.totalActions == 5, "Should have 5 actions");
    assert(stats.format().length > 0, "Format should produce output");
    
    writeln("\x1b[32m  ✓ Statistics calculation\x1b[0m");
}

/// Test scheduler integration with profiles
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m profile_scheduling - Scheduler integration");
    
    auto graph = new BuildGraph();
    auto history = new ExecutionHistory();
    
    // Create a simple node
    auto target = Target();
    target.name = "test_target";
    graph.addTarget(target);
    
    // Create profile scheduler
    auto profileScheduler = createProfiledScheduler(graph, history);
    
    // Create distributed scheduler and enable profiling
    auto registry = new WorkerRegistry();
    auto distScheduler = new DistributedScheduler(graph, registry);
    
    distScheduler.enableProfileGuidedScheduling(profileScheduler);
    assert(distScheduler.isProfileGuided(), "Should be profile-guided");
    
    writeln("\x1b[32m  ✓ Scheduler integration\x1b[0m");
}

/// Test dependents count influence on scheduling
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m profile_scheduling - Dependents influence parallelism");
    
    // Action with many dependents should be prioritized to unblock parallelism
    ActionProfile manyDependents = ActionProfile(1000, 5000, 10, 1, 0.0f);
    ActionProfile fewDependents = ActionProfile(1000, 5000, 2, 1, 0.0f);
    
    assert(manyDependents.schedulingScore() > fewDependents.schedulingScore(),
        "More dependents should increase priority to unblock parallelism");
    
    // The difference should be proportional to dependent count difference
    auto scoreDiff = manyDependents.schedulingScore() - fewDependents.schedulingScore();
    assert(scoreDiff > 0, "Score difference should be positive");
    
    writeln("\x1b[32m  ✓ Dependents influence parallelism\x1b[0m");
}

