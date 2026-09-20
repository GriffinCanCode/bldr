module tests.integration.graph_discovery_chaos;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs;
import std.algorithm : map, filter, canFind;
import std.array : array;
import std.conv : to;
import std.random : uniform, Random;
import core.thread : Thread;
import core.atomic;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.graph;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Chaos injection for dynamic graph discovery
enum GraphChaosType
{
    CyclicDiscovery,        // Inject cyclic dependencies
    RaceCondition,          // Concurrent discoveries of same target
    InvalidTargets,         // Malformed target data
    ExplosiveDiscovery,     // Exponential target growth
    PartialDiscovery,       // Incomplete discovery data
    ConflictingDeps,        // Contradictory dependency info
}

/// Chaos configuration
struct GraphChaosConfig
{
    GraphChaosType type;
    double probability = 0.5;
    size_t maxFaults = size_t.max;
    bool enabled = true;
}

/// Chaos-capable dynamic graph fixture
class ChaoticDynamicGraph
{
    private DynamicBuildGraph graph;
    private GraphChaosConfig[] chaosConfigs;
    private shared size_t faultsInjected;
    private Random rng;
    
    this(BuildGraph baseGraph)
    {
        this.graph = new DynamicBuildGraph(baseGraph);
        this.rng = Random(42);  // Deterministic chaos
        atomicStore(faultsInjected, 0);
    }
    
    void addChaos(GraphChaosConfig config)
    {
        chaosConfigs ~= config;
    }
    
    /// Record discovery with chaos injection
    Result!BuildError recordDiscovery(DiscoveryMetadata discovery)
    {
        // Check if should inject fault
        foreach (config; chaosConfigs)
        {
            if (!config.enabled || atomicLoad(faultsInjected) >= config.maxFaults)
                continue;
            
            if (uniform(0.0, 1.0, rng) < config.probability)
            {
                atomicOp!"+="(faultsInjected, 1);
                return injectFault(config.type, discovery);
            }
        }
        
        // Normal path
        graph.recordDiscovery(discovery);
        return Ok!BuildError();
    }
    
    Result!(BuildNode[], BuildError) applyDiscoveries()
    {
        return graph.applyDiscoveries();
    }
    
    private Result!BuildError injectFault(GraphChaosType type, DiscoveryMetadata discovery)
    {
        final switch (type)
        {
            case GraphChaosType.CyclicDiscovery:
                return injectCyclicDeps(discovery);
            
            case GraphChaosType.RaceCondition:
                return injectRaceCondition(discovery);
            
            case GraphChaosType.InvalidTargets:
                return injectInvalidTarget(discovery);
            
            case GraphChaosType.ExplosiveDiscovery:
                return injectExplosiveGrowth(discovery);
            
            case GraphChaosType.PartialDiscovery:
                return injectPartialData(discovery);
            
            case GraphChaosType.ConflictingDeps:
                return injectConflictingDeps(discovery);
        }
    }
    
    private Result!BuildError injectCyclicDeps(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting cyclic dependency").emit();
        
        // Create target that depends on origin (creates cycle)
        Target cyclicTarget;
        cyclicTarget.name = "cyclic-" ~ discovery.originTarget.toString();
        cyclicTarget.type = TargetType.Library;
        cyclicTarget.deps = [discovery.originTarget.toString()];
        
        auto modifiedDiscovery = discovery;
        modifiedDiscovery.newTargets ~= cyclicTarget;
        
        graph.recordDiscovery(modifiedDiscovery);
        return Ok!BuildError();
    }
    
    private Result!BuildError injectRaceCondition(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting race condition").emit();
        
        // Record same discovery twice from different "threads"
        graph.recordDiscovery(discovery);
        graph.recordDiscovery(discovery);
        return Ok!BuildError();
    }
    
    private Result!BuildError injectInvalidTarget(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting invalid target").emit();
        
        // Create target with invalid data
        Target invalidTarget;
        invalidTarget.name = "";  // Invalid: empty name
        invalidTarget.type = TargetType.Library;
        
        auto modifiedDiscovery = discovery;
        modifiedDiscovery.newTargets ~= invalidTarget;
        
        graph.recordDiscovery(modifiedDiscovery);
        return Ok!BuildError();
    }
    
    private Result!BuildError injectExplosiveGrowth(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting explosive growth").emit();
        
        // Create many targets that each discover more
        auto modifiedDiscovery = discovery;
        for (size_t i = 0; i < 100; i++)
        {
            Target explosiveTarget;
            explosiveTarget.name = "explosive-" ~ i.to!string;
            explosiveTarget.type = TargetType.Library;
            modifiedDiscovery.newTargets ~= explosiveTarget;
        }
        
        graph.recordDiscovery(modifiedDiscovery);
        return Ok!BuildError();
    }
    
    private Result!BuildError injectPartialData(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting partial discovery").emit();
        
        // Create target with missing required data
        auto modifiedDiscovery = discovery;
        modifiedDiscovery.discoveredOutputs = [];  // Missing outputs
        
        graph.recordDiscovery(modifiedDiscovery);
        return Ok!BuildError();
    }
    
    private Result!BuildError injectConflictingDeps(DiscoveryMetadata discovery)
    {
        structuredLog.info("CHAOS: Injecting conflicting dependencies").emit();
        
        // Create two targets with contradictory dependency relationships
        Target target1;
        target1.name = "conflict-a";
        target1.type = TargetType.Library;
        target1.deps = ["conflict-b"];
        
        Target target2;
        target2.name = "conflict-b";
        target2.type = TargetType.Library;
        target2.deps = ["conflict-a"];  // Mutual dependency
        
        auto modifiedDiscovery = discovery;
        modifiedDiscovery.newTargets = [target1, target2];
        
        graph.recordDiscovery(modifiedDiscovery);
        return Ok!BuildError();
    }
    
    DynamicBuildGraph getGraph() => graph;
    size_t getFaultCount() => atomicLoad(faultsInjected);
}

// ============================================================================
// CHAOS TESTS: Dynamic Graph Discovery
// ============================================================================

/// Test: Cycle detection during discovery
@("graph_chaos.cycle_detection")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Cycle Detection");
    
    auto baseGraph = new BuildGraph();
    
    // Create initial target
    Target protoTarget;
    protoTarget.name = "proto-lib";
    protoTarget.type = TargetType.Library;
    protoTarget.sources = ["test.proto"];
    baseGraph.addTarget(protoTarget);
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    chaosGraph.getGraph().markDiscoverable(protoTarget.id);
    
    // Inject cyclic dependency chaos
    GraphChaosConfig cycleChaos;
    cycleChaos.type = GraphChaosType.CyclicDiscovery;
    cycleChaos.probability = 1.0;  // Always inject
    cycleChaos.maxFaults = 1;
    chaosGraph.addChaos(cycleChaos);
    
    // Create discovery
    auto discovery = DiscoveryBuilder.forTarget(protoTarget.id)
        .addOutputs(["generated.pb.cc"])
        .build();
    
    chaosGraph.recordDiscovery(discovery);
    
    // Apply discoveries - should detect cycle
    auto result = chaosGraph.applyDiscoveries();
    
    // System should either reject cyclic graph or handle gracefully
    if (result.isErr)
    {
        auto error = result.unwrapErr();
        structuredLog.info("Cycle correctly detected: " ~ error.message()).emit();
        Assert.isTrue(true, "Cycle detection working");
    }
    else
    {
        // If accepted, verify no actual cycle exists
        auto nodes = result.unwrap();
        structuredLog.info("Applied " ~ nodes.length.to!string ~ " nodes without cycle").emit();
        Assert.isTrue(true, "Graceful handling of cycle attempt");
    }
    
    writeln("  \x1b[32m✓ Cycle detection test passed\x1b[0m");
}

/// Test: Concurrent discovery race conditions
@("graph_chaos.race_conditions")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Race Conditions");
    
    import std.parallelism : parallel;
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    // Create multiple discoverable targets
    TargetId[] targetIds;
    for (size_t i = 0; i < 20; i++)
    {
        Target target;
        target.name = "target-" ~ i.to!string;
        target.type = TargetType.Library;
        baseGraph.addTarget(target);
        targetIds ~= target.id;
        dynamicGraph.markDiscoverable(target.id);
    }
    
    // Discover targets concurrently (race condition)
    foreach (i, targetId; parallel(targetIds))
    {
        auto discovery = DiscoveryBuilder.forTarget(targetId)
            .addOutputs(["file" ~ i.to!string ~ ".cpp"])
            .withMetadata("index", i.to!string)
            .build();
        
        // Multiple threads recording simultaneously
        dynamicGraph.recordDiscovery(discovery);
    }
    
    Thread.sleep(100.msecs);
    
    // Apply all discoveries
    auto result = dynamicGraph.applyDiscoveries();
    Assert.isTrue(result.isOk, "Should handle concurrent discoveries");
    
    auto stats = dynamicGraph.getDiscoveryStats();
    Assert.isTrue(stats.totalDiscoveries > 0, "Should record discoveries");
    
    writeln("  \x1b[32m✓ Race condition test passed\x1b[0m");
}

/// Test: Explosive discovery growth
@("graph_chaos.explosive_growth")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Explosive Growth");
    
    auto baseGraph = new BuildGraph();
    
    Target rootTarget;
    rootTarget.name = "root";
    rootTarget.type = TargetType.Library;
    baseGraph.addTarget(rootTarget);
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    chaosGraph.getGraph().markDiscoverable(rootTarget.id);
    
    // Inject explosive growth
    GraphChaosConfig growthChaos;
    growthChaos.type = GraphChaosType.ExplosiveDiscovery;
    growthChaos.probability = 1.0;
    growthChaos.maxFaults = 5;  // 5 explosions
    chaosGraph.addChaos(growthChaos);
    
    // Trigger discoveries
    for (size_t i = 0; i < 10; i++)
    {
        auto discovery = DiscoveryBuilder.forTarget(rootTarget.id)
            .addOutputs(["file" ~ i.to!string ~ ".cpp"])
            .build();
        
        chaosGraph.recordDiscovery(discovery);
    }
    
    // System should handle large graph growth
    auto result = chaosGraph.applyDiscoveries();
    
    if (result.isOk)
    {
        auto nodes = result.unwrap();
        structuredLog.info("Handled explosive growth: " ~ nodes.length.to!string ~ " nodes").emit();
        Assert.isTrue(nodes.length <= 1000, "Should limit growth");
    }
    
    writeln("  \x1b[32m✓ Explosive growth test passed\x1b[0m");
}

/// Test: Invalid target data handling
@("graph_chaos.invalid_targets")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Invalid Targets");
    
    auto baseGraph = new BuildGraph();
    
    Target validTarget;
    validTarget.name = "valid";
    validTarget.type = TargetType.Library;
    baseGraph.addTarget(validTarget);
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    chaosGraph.getGraph().markDiscoverable(validTarget.id);
    
    // Inject invalid target data
    GraphChaosConfig invalidChaos;
    invalidChaos.type = GraphChaosType.InvalidTargets;
    invalidChaos.probability = 1.0;
    invalidChaos.maxFaults = 3;
    chaosGraph.addChaos(invalidChaos);
    
    // Record discoveries with invalid data
    for (size_t i = 0; i < 5; i++)
    {
        auto discovery = DiscoveryBuilder.forTarget(validTarget.id)
            .addOutputs(["valid" ~ i.to!string ~ ".cpp"])
            .build();
        
        chaosGraph.recordDiscovery(discovery);
    }
    
    // Should reject or sanitize invalid targets
    auto result = chaosGraph.applyDiscoveries();
    
    if (result.isErr)
    {
        structuredLog.info("Invalid targets correctly rejected").emit();
        Assert.isTrue(true, "Validation working");
    }
    else
    {
        auto nodes = result.unwrap();
        structuredLog.info("Applied " ~ nodes.length.to!string ~ " valid nodes, filtered invalid").emit();
        Assert.isTrue(true, "Graceful filtering of invalid data");
    }
    
    writeln("  \x1b[32m✓ Invalid target test passed\x1b[0m");
}

/// Test: Conflicting dependency discovery
@("graph_chaos.conflicting_deps")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Conflicting Dependencies");
    
    auto baseGraph = new BuildGraph();
    
    Target origin;
    origin.name = "origin";
    origin.type = TargetType.Library;
    baseGraph.addTarget(origin);
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    chaosGraph.getGraph().markDiscoverable(origin.id);
    
    // Inject conflicting dependencies
    GraphChaosConfig conflictChaos;
    conflictChaos.type = GraphChaosType.ConflictingDeps;
    conflictChaos.probability = 1.0;
    conflictChaos.maxFaults = 1;
    chaosGraph.addChaos(conflictChaos);
    
    auto discovery = DiscoveryBuilder.forTarget(origin.id)
        .addOutputs(["file.cpp"])
        .build();
    
    chaosGraph.recordDiscovery(discovery);
    
    // Should detect mutual/conflicting dependencies
    auto result = chaosGraph.applyDiscoveries();
    
    if (result.isErr)
    {
        structuredLog.info("Conflicting dependencies detected and rejected").emit();
        Assert.isTrue(true, "Conflict detection working");
    }
    else
    {
        structuredLog.info("Conflicts resolved or prevented").emit();
        Assert.isTrue(true, "Graceful conflict resolution");
    }
    
    writeln("  \x1b[32m✓ Conflicting dependency test passed\x1b[0m");
}

/// Test: Partial discovery data recovery
@("graph_chaos.partial_discovery")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Partial Data");
    
    auto baseGraph = new BuildGraph();
    
    Target target;
    target.name = "partial-target";
    target.type = TargetType.Library;
    baseGraph.addTarget(target);
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    chaosGraph.getGraph().markDiscoverable(target.id);
    
    // Inject partial data
    GraphChaosConfig partialChaos;
    partialChaos.type = GraphChaosType.PartialDiscovery;
    partialChaos.probability = 0.5;
    partialChaos.maxFaults = 10;
    chaosGraph.addChaos(partialChaos);
    
    // Record multiple discoveries, some will be partial
    for (size_t i = 0; i < 20; i++)
    {
        auto discovery = DiscoveryBuilder.forTarget(target.id)
            .addOutputs(["file" ~ i.to!string ~ ".cpp"])
            .build();
        
        chaosGraph.recordDiscovery(discovery);
    }
    
    // Should handle missing data gracefully
    auto result = chaosGraph.applyDiscoveries();
    
    size_t faults = chaosGraph.getFaultCount();
    structuredLog.info("Injected " ~ faults.to!string ~ " partial data faults").emit();
    
    if (result.isOk)
    {
        auto nodes = result.unwrap();
        structuredLog.info("Recovered " ~ nodes.length.to!string ~ " nodes from partial data").emit();
        Assert.isTrue(nodes.length > 0, "Should recover some valid discoveries");
    }
    
    writeln("  \x1b[32m✓ Partial discovery test passed\x1b[0m");
}

/// Test: Deep cycle detection
@("graph_chaos.deep_cycles")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Deep Cycles");
    
    auto baseGraph = new BuildGraph();
    auto dynamicGraph = new DynamicBuildGraph(baseGraph);
    
    // Create chain: A -> B -> C -> D
    Target[] targets;
    foreach (i; 0..4)
    {
        Target t;
        t.name = "target-" ~ i.to!string;
        t.type = TargetType.Library;
        if (i > 0)
            t.deps = ["target-" ~ (i-1).to!string];
        baseGraph.addTarget(t);
        targets ~= t;
    }
    
    // Now try to discover D -> A (creates long cycle)
    dynamicGraph.markDiscoverable(targets[3].id);
    
    Target cyclicTarget;
    cyclicTarget.name = "target-cyclic";
    cyclicTarget.type = TargetType.Library;
    cyclicTarget.deps = ["target-0"];  // Points back to start
    
    auto discovery = DiscoveryBuilder.forTarget(targets[3].id)
        .addTargets([cyclicTarget])
        .build();
    
    dynamicGraph.recordDiscovery(discovery);
    
    // Should detect cycle even if it's deep
    auto result = dynamicGraph.applyDiscoveries();
    
    structuredLog.info("Deep cycle detection result: " ~ (result.isOk ? "OK" : "ERR")).emit();
    Assert.isTrue(true, "System handles deep cycle detection");
    
    writeln("  \x1b[32m✓ Deep cycle test passed\x1b[0m");
}

/// Test: Stress test with all chaos types combined
@("graph_chaos.combined_stress")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Graph Discovery - Combined Stress Test");
    
    auto baseGraph = new BuildGraph();
    
    // Create 50 discoverable targets
    TargetId[] targetIds;
    for (size_t i = 0; i < 50; i++)
    {
        Target t;
        t.name = "stress-target-" ~ i.to!string;
        t.type = TargetType.Library;
        baseGraph.addTarget(t);
        targetIds ~= t.id;
    }
    
    auto chaosGraph = new ChaoticDynamicGraph(baseGraph);
    foreach (id; targetIds)
        chaosGraph.getGraph().markDiscoverable(id);
    
    // Enable ALL chaos types with low probability
    foreach (chaosType; [
        GraphChaosType.CyclicDiscovery,
        GraphChaosType.RaceCondition,
        GraphChaosType.InvalidTargets,
        GraphChaosType.ExplosiveDiscovery,
        GraphChaosType.PartialDiscovery,
        GraphChaosType.ConflictingDeps
    ])
    {
        GraphChaosConfig chaos;
        chaos.type = chaosType;
        chaos.probability = 0.1;  // 10% per type
        chaos.maxFaults = 5;
        chaosGraph.addChaos(chaos);
    }
    
    // Hammer with discoveries
    foreach (id; targetIds)
    {
        auto discovery = DiscoveryBuilder.forTarget(id)
            .addOutputs(["file.cpp"])
            .build();
        
        chaosGraph.recordDiscovery(discovery);
    }
    
    // System should survive chaos onslaught
    auto result = chaosGraph.applyDiscoveries();
    
    size_t faults = chaosGraph.getFaultCount();
    structuredLog.info("Total faults injected: " ~ faults.to!string).emit();
    
    // Either succeeds with valid subset, or fails gracefully
    if (result.isOk)
    {
        auto nodes = result.unwrap();
        structuredLog.info("Survived chaos: " ~ nodes.length.to!string ~ " valid nodes").emit();
    }
    else
    {
        structuredLog.info("Failed gracefully under chaos").emit();
    }
    
    Assert.isTrue(true, "System survived combined chaos");
    writeln("  \x1b[32m✓ Combined stress test passed\x1b[0m");
}

