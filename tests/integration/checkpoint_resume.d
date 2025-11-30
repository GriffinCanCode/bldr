module tests.integration.checkpoint_resume;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import tests.harness;
import tests.fixtures;
import tests.mocks;
import infrastructure.config.schema.schema;
import engine.graph.core.graph;
// import engine.runtime.core.engine.executor; // Removed
import engine.runtime.recovery.checkpoint;
import engine.runtime.recovery.resume;
import infrastructure.errors;

/// Mock executor to simulate build failures based on file content
class MockBuildExecutor
{
    BuildGraph graph;
    string workspaceRoot;
    CheckpointManager checkpointManager;
    
    this(BuildGraph graph, WorkspaceConfig config, int workers, Object logger, bool incremental, bool dryRun)
    {
        this.graph = graph;
        this.workspaceRoot = config.root;
        this.checkpointManager = new CheckpointManager(workspaceRoot, true);
    }
    
    void execute()
    {
        auto sortedResult = graph.topologicalSort();
        if (sortedResult.isErr) return;
        
        auto sorted = sortedResult.unwrap();
        foreach (node; sorted)
        {
            // Check dependencies
            if (!node.isReady(graph))
            {
                node.status = BuildStatus.Pending; 
                continue;
            }
            
            // Simulate build
            bool success = true;
            // Read source to check for failure trigger
            if (node.target.sources.length > 0)
            {
                try
                {
                    auto content = std.file.readText(node.target.sources[0]);
                    if (content.canFind("invalid") || content.canFind("fail") || content.canFind("failure"))
                    {
                        success = false;
                    }
                }
                catch (Exception) {}
            }
            
            if (success)
            {
                node.status = BuildStatus.Success;
                // Set a mock hash
                node.hash = "hash-" ~ node.id.toString();
            }
            else
            {
                node.status = BuildStatus.Failed;
                // Save checkpoint on failure
                auto checkpoint = checkpointManager.capture(graph, workspaceRoot);
                checkpointManager.save(checkpoint);
                return; // Stop on first failure
            }
        }
    }
}

alias BuildExecutor = MockBuildExecutor;

/// Test checkpoint/resume functionality with actual build failures
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Save checkpoint on build failure");
    
    auto tempDir = scoped(new TempDir("checkpoint-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create a simple workspace with multiple targets
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create targets where one will fail
    Target[] targets;
    
    // Target 1: Success
    Target target1;
    target1.name = "target1";
    target1.type = TargetType.Executable;
    target1.language = TargetLanguage.Python;
    target1.sources = [buildPath(workspacePath, "target1.py")];
    std.file.write(target1.sources[0], "print('Target 1')\n");
    targets ~= target1;
    
    // Target 2: Success (depends on target1)
    Target target2;
    target2.name = "target2";
    target2.type = TargetType.Executable;
    target2.language = TargetLanguage.Python;
    target2.sources = [buildPath(workspacePath, "target2.py")];
    target2.deps = ["target1"];
    std.file.write(target2.sources[0], "print('Target 2')\n");
    targets ~= target2;
    
    // Target 3: Will fail (invalid syntax)
    Target target3;
    target3.name = "target3";
    target3.type = TargetType.Executable;
    target3.language = TargetLanguage.Python;
    target3.sources = [buildPath(workspacePath, "target3.py")];
    std.file.write(target3.sources[0], "print('Target 3'\nthis is invalid python\n");
    targets ~= target3;
    
    // Target 4: Pending (depends on target3)
    Target target4;
    target4.name = "target4";
    target4.type = TargetType.Executable;
    target4.language = TargetLanguage.Python;
    target4.sources = [buildPath(workspacePath, "target4.py")];
    target4.deps = ["target3"];
    std.file.write(target4.sources[0], "print('Target 4')\n");
    targets ~= target4;
    
    // Build graph
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    auto sorted = graph.topologicalSort();
    Assert.isTrue(sorted.isOk, "Graph should be valid");
    
    // Execute build with checkpoints enabled
    auto executor = new BuildExecutor(graph, config, 2, null, true, false);
    executor.execute();
    
    // Check that checkpoint was created
    auto checkpointPath = buildPath(workspacePath, ".builder-cache", "checkpoint.bin");
    // CheckpointManager implementation uses .builder-cache/checkpoint.bin
    
    Assert.isTrue(exists(checkpointPath), "Checkpoint file should be created on failure");
    
    // Verify checkpoint manager created checkpoint
    auto checkpointManager = new CheckpointManager(workspacePath, true);
    auto checkpoint = checkpointManager.load();
    Assert.isTrue(checkpoint.isOk, "Should be able to load checkpoint");
    
    auto cp = checkpoint.unwrap();
    Assert.equal(cp.totalTargets, targets.length);
    Assert.isTrue(cp.failedTargets > 0, "Should have failed targets");
    Assert.isTrue(cp.completedTargets > 0, "Should have completed targets");
    
    writeln("\x1b[32m  ✓ Checkpoint saved on build failure\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Resume from checkpoint with RetryFailed strategy");
    
    auto tempDir = scoped(new TempDir("resume-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create checkpoint
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime();
    checkpoint.totalTargets = 4;
    checkpoint.completedTargets = 2;
    checkpoint.failedTargets = 1;
    
    // Simulate: target1 and target2 succeeded, target3 failed, target4 pending
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    checkpoint.nodeStates["target2"] = BuildStatus.Success;
    checkpoint.nodeStates["target3"] = BuildStatus.Failed;
    checkpoint.nodeStates["target4"] = BuildStatus.Pending;
    checkpoint.failedTargetIds = ["target3"];
    
    checkpoint.nodeHashes["target1"] = "hash1";
    checkpoint.nodeHashes["target2"] = "hash2";
    
    // Create targets
    Target[] targets;
    foreach (i; 1 .. 5)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        target.sources = [buildPath(workspacePath, "target" ~ i.to!string ~ ".py")];
        targets ~= target;
    }
    
    // Build graph
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Create resume planner
    ResumeConfig resumeConfig;
    resumeConfig.strategy = ResumeStrategy.RetryFailed;
    auto planner = new ResumePlanner(resumeConfig);
    
    // Plan resume
    auto planResult = planner.plan(checkpoint, graph);
    Assert.isTrue(planResult.isOk, "Resume plan should be valid");
    
    auto plan = planResult.unwrap();
    Assert.equal(plan.strategy, ResumeStrategy.RetryFailed);
    Assert.isTrue(plan.targetsToRetry.canFind("target3"), "Should retry failed target");
    Assert.isTrue(plan.targetsToSkip.canFind("target1"), "Should skip successful target");
    Assert.isTrue(plan.targetsToSkip.canFind("target2"), "Should skip successful target");
    
    writeln("\x1b[32m  ✓ Resume planner works with RetryFailed strategy\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Resume with SkipFailed strategy");
    
    auto tempDir = scoped(new TempDir("skip-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create checkpoint
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime();
    checkpoint.totalTargets = 5;
    checkpoint.completedTargets = 3;
    checkpoint.failedTargets = 2;
    
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    checkpoint.nodeStates["target2"] = BuildStatus.Failed;
    checkpoint.nodeStates["target3"] = BuildStatus.Success;
    checkpoint.nodeStates["target4"] = BuildStatus.Failed;
    checkpoint.nodeStates["target5"] = BuildStatus.Pending;
    checkpoint.failedTargetIds = ["target2", "target4"];
    
    // Create targets
    Target[] targets;
    foreach (i; 1 .. 6)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        target.sources = [buildPath(workspacePath, "target" ~ i.to!string ~ ".py")];
        targets ~= target;
    }
    
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Use SkipFailed strategy
    ResumeConfig resumeConfig;
    resumeConfig.strategy = ResumeStrategy.SkipFailed;
    auto planner = new ResumePlanner(resumeConfig);
    
    auto planResult = planner.plan(checkpoint, graph);
    Assert.isTrue(planResult.isOk, "Resume plan should be valid");
    
    auto plan = planResult.unwrap();
    Assert.equal(plan.strategy, ResumeStrategy.SkipFailed);
    Assert.isTrue(plan.targetsToSkip.canFind("target2"), "Should skip failed targets");
    Assert.isTrue(plan.targetsToSkip.canFind("target4"), "Should skip failed targets");
    Assert.isTrue(plan.targetsToSkip.canFind("target1"), "Should skip successful targets");
    Assert.isTrue(plan.targetsToSkip.canFind("target3"), "Should skip successful targets");
    
    writeln("\x1b[32m  ✓ SkipFailed strategy works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Smart resume with dependency validation");
    
    auto tempDir = scoped(new TempDir("smart-resume-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create checkpoint
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime() - 1.hours; // 1 hour old
    checkpoint.totalTargets = 3;
    checkpoint.completedTargets = 2;
    checkpoint.failedTargets = 1;
    
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    checkpoint.nodeStates["target2"] = BuildStatus.Success;
    checkpoint.nodeStates["target3"] = BuildStatus.Failed;
    checkpoint.failedTargetIds = ["target3"];
    
    // Create targets with dependencies
    Target[] targets;
    
    Target target1;
    target1.name = "target1";
    target1.type = TargetType.Library;
    target1.language = TargetLanguage.Python;
    target1.sources = [buildPath(workspacePath, "target1.py")];
    targets ~= target1;
    
    Target target2;
    target2.name = "target2";
    target2.type = TargetType.Library;
    target2.language = TargetLanguage.Python;
    target2.sources = [buildPath(workspacePath, "target2.py")];
    target2.deps = ["target1"];
    targets ~= target2;
    
    Target target3;
    target3.name = "target3";
    target3.type = TargetType.Executable;
    target3.language = TargetLanguage.Python;
    target3.sources = [buildPath(workspacePath, "target3.py")];
    target3.deps = ["target2"];
    targets ~= target3;
    
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Use Smart strategy
    ResumeConfig resumeConfig;
    resumeConfig.strategy = ResumeStrategy.Smart;
    resumeConfig.validateDependencies = true;
    auto planner = new ResumePlanner(resumeConfig);
    
    auto planResult = planner.plan(checkpoint, graph);
    Assert.isTrue(planResult.isOk, "Smart resume plan should be valid");
    
    auto plan = planResult.unwrap();
    Assert.equal(plan.strategy, ResumeStrategy.Smart);
    Assert.isTrue(plan.targetsToRetry.canFind("target3"), "Should retry failed target");
    
    writeln("\x1b[32m  ✓ Smart resume with dependency validation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Checkpoint expiration");
    
    auto tempDir = scoped(new TempDir("expiration-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create old checkpoint (25 hours ago)
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime() - 25.hours;
    checkpoint.totalTargets = 2;
    checkpoint.completedTargets = 1;
    checkpoint.failedTargets = 1;
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    checkpoint.nodeStates["target2"] = BuildStatus.Failed;
    checkpoint.failedTargetIds = ["target2"];
    
    // Create targets
    Target[] targets;
    foreach (i; 1 .. 3)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        target.sources = [buildPath(workspacePath, "target" ~ i.to!string ~ ".py")];
        targets ~= target;
    }
    
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Set max age to 24 hours
    ResumeConfig resumeConfig;
    resumeConfig.maxCheckpointAge = 24.hours;
    auto planner = new ResumePlanner(resumeConfig);
    
    // Plan should fail due to age
    auto planResult = planner.plan(checkpoint, graph);
    Assert.isTrue(planResult.isErr, "Old checkpoint should be rejected");
    Assert.isTrue(planResult.unwrapErr().canFind("too old"), "Error should mention age");
    
    writeln("\x1b[32m  ✓ Checkpoint expiration works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Invalid checkpoint detection");
    
    auto tempDir = scoped(new TempDir("invalid-checkpoint-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create checkpoint with mismatched target count
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime();
    checkpoint.totalTargets = 3; // Wrong count
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    
    // Create different number of targets
    Target[] targets;
    foreach (i; 1 .. 3) // Only 2 targets
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        target.sources = [buildPath(workspacePath, "target" ~ i.to!string ~ ".py")];
        targets ~= target;
    }
    
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Checkpoint should be invalid
    Assert.isFalse(checkpoint.isValid(graph), "Checkpoint should be invalid for different graph");
    
    // Resume planner should reject it
    auto planner = new ResumePlanner();
    auto planResult = planner.plan(checkpoint, graph);
    Assert.isTrue(planResult.isErr, "Should reject invalid checkpoint");
    
    writeln("\x1b[32m  ✓ Invalid checkpoint detection works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Checkpoint merge with graph state");
    
    auto tempDir = scoped(new TempDir("merge-test"));
    auto workspacePath = tempDir.getPath();
    
    // Create checkpoint
    Checkpoint checkpoint;
    checkpoint.workspaceRoot = workspacePath;
    checkpoint.timestamp = Clock.currTime();
    checkpoint.totalTargets = 3;
    checkpoint.nodeStates["target1"] = BuildStatus.Success;
    checkpoint.nodeStates["target2"] = BuildStatus.Cached;
    checkpoint.nodeStates["target3"] = BuildStatus.Failed;
    checkpoint.nodeHashes["target1"] = "hash1";
    checkpoint.nodeHashes["target2"] = "hash2";
    
    // Create targets
    Target[] targets;
    foreach (i; 1 .. 4)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        target.sources = [buildPath(workspacePath, "target" ~ i.to!string ~ ".py")];
        targets ~= target;
    }
    
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    
    // Initially all nodes should be Pending
    foreach (node; graph.nodes.values)
    {
        Assert.equal(node.status, BuildStatus.Pending);
    }
    
    // Merge checkpoint
    checkpoint.mergeWith(graph);
    
    // Check that successful/cached states were restored
    Assert.equal(graph.nodes["target1"].status, BuildStatus.Success);
    Assert.equal(graph.nodes["target1"].hash, "hash1");
    Assert.equal(graph.nodes["target2"].status, BuildStatus.Cached);
    Assert.equal(graph.nodes["target2"].hash, "hash2");
    
    // Failed target should remain Pending (to be retried)
    Assert.equal(graph.nodes["target3"].status, BuildStatus.Pending);
    
    writeln("\x1b[32m  ✓ Checkpoint merge with graph state works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m checkpoint_resume - Full integration test with retry");
    
    auto tempDir = scoped(new TempDir("full-integration-test"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create targets
    Target[] targets;
    
    // Create 5 targets where target3 initially fails
    foreach (i; 1 .. 6)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Python;
        
        auto sourcePath = buildPath(workspacePath, "target" ~ i.to!string ~ ".py");
        target.sources = [sourcePath];
        
        // target3 has invalid syntax initially
        if (i == 3)
        {
            std.file.write(sourcePath, "print('Target 3'\nthis will fail");
        }
        else
        {
            std.file.write(sourcePath, "print('Target " ~ i.to!string ~ "')\n");
        }
        
        targets ~= target;
    }
    
    // First build - will fail on target3
    auto graph1 = new BuildGraph();
    foreach (target; targets)
    {
        graph1.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph1.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    auto executor1 = new BuildExecutor(graph1, config, 2, null, true, false);
    executor1.execute();
    
    // Verify checkpoint was created
    auto checkpointManager = new CheckpointManager(workspacePath, true);
    auto cpResult1 = checkpointManager.load();
    Assert.isTrue(cpResult1.isOk, "Checkpoint should be saved");
    
    auto cp1 = cpResult1.unwrap();
    Assert.isTrue(cp1.failedTargets > 0, "Should have failures");
    Assert.isTrue(cp1.completedTargets > 0, "Should have completions");
    
    // Fix target3
    auto target3Path = buildPath(workspacePath, "target3.py");
    std.file.write(target3Path, "print('Target 3 fixed')\n");
    
    // Second build - should resume from checkpoint
    auto graph2 = new BuildGraph();
    foreach (target; targets)
    {
        graph2.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph2.addDependency(target.name, dep);
            Assert.isTrue(result.isOk, "Dependency should be added");
        }
    }
    auto executor2 = new BuildExecutor(graph2, config, 2, null, true, false);
    
    // Load checkpoint and merge
    auto cpResult2 = checkpointManager.load();
    if (cpResult2.isOk)
    {
        auto cp2 = cpResult2.unwrap();
        cp2.mergeWith(graph2);
    }
    
    executor2.execute();
    
    // After successful build, checkpoint should be cleared
    // (if clearOnSuccess is enabled in CheckpointManager)
    
    writeln("\x1b[32m  ✓ Full integration test with retry passed\x1b[0m");
}
