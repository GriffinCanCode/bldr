module tests.integration.stress_parallel;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.parallelism;
import tests.harness;
import tests.fixtures;
import tests.mocks;
import infrastructure.config.schema.schema;
import engine.graph.core.graph;
import engine.runtime.core.engine.executor;
import infrastructure.utils.logging.logger;

/// Stress test: Build graph with 10,000+ targets
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Build graph with 10,000 targets");
    
    auto tempDir = scoped(new TempDir("stress-10k"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create 10,000 targets
    immutable size_t targetCount = 10_000;
    Target[] targets;
    targets.reserve(targetCount);
    
    writeln("  Creating ", targetCount, " targets...");
    auto createTimer = StopWatch(AutoStart.yes);
    
    foreach (i; 0 .. targetCount)
    {
        Target target;
        target.name = "target" ~ i.to!string;
        target.type = TargetType.Library;
        target.language = TargetLanguage.Python;
        
        // Create minimal source file
        auto sourcePath = buildPath(workspacePath, "target" ~ i.to!string ~ ".py");
        target.sources = [sourcePath];
        
        // Simple Python source
        std.file.write(sourcePath, "# Target " ~ i.to!string ~ "\nvalue = " ~ i.to!string ~ "\n");
        
        // Add dependency to previous target (creates linear chain)
        if (i > 0 && i % 10 == 0)
        {
            target.deps = ["target" ~ (i - 1).to!string];
        }
        
        targets ~= target;
        
        // Progress indicator
        if ((i + 1) % 1000 == 0)
        {
            writeln("    Created ", i + 1, " targets...");
        }
    }
    
    createTimer.stop();
    writeln("  ✓ Created ", targetCount, " targets in ", createTimer.peek().total!"msecs", "ms");
    
    // Build dependency graph
    writeln("  Building dependency graph...");
    auto graphTimer = StopWatch(AutoStart.yes);
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
    graphTimer.stop();
    writeln("  ✓ Built graph in ", graphTimer.peek().total!"msecs", "ms");
    
    // Verify graph structure
    Assert.equal(graph.nodes.length, targetCount);
    auto stats = graph.getStats();
    writeln("  Graph stats:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Depth: ", stats.maxDepth);
    
    // Topological sort
    writeln("  Performing topological sort...");
    auto sortTimer = StopWatch(AutoStart.yes);
    auto sortResult = graph.topologicalSort();
    sortTimer.stop();
    Assert.isTrue(sortResult.isOk, "Graph should be sortable");
    writeln("  ✓ Sorted in ", sortTimer.peek().total!"msecs", "ms");
    
    // Execute build with maximum parallelism
    writeln("  Executing parallel build with ", totalCPUs, " workers...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built ", targetCount, " targets in ", buildTimer.peek().total!"seconds", "s");
    writeln("  Throughput: ", (targetCount * 1000) / buildTimer.peek().total!"msecs", " targets/sec");
    
    // Verify all targets were built
    size_t successCount = 0;
    foreach (node; graph.nodes.values)
    {
        if (node.status == BuildStatus.Success || node.status == BuildStatus.Cached)
            successCount++;
    }
    
    writeln("  Success rate: ", successCount, "/", targetCount, " (", 
            (successCount * 100.0 / targetCount), "%)");
    
    Assert.isTrue(successCount > targetCount * 0.95, "At least 95% should succeed");
    
    writeln("\x1b[32m  ✓ Stress test with 10,000 targets passed\x1b[0m");
}

/// Stress test: Wide dependency tree (fan-out pattern)
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Wide dependency tree (1,000 targets, fan-out)");
    
    auto tempDir = scoped(new TempDir("stress-wide"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create 1 root target and 999 leaf targets that depend on it
    immutable size_t leafCount = 999;
    Target[] targets;
    
    writeln("  Creating wide dependency tree...");
    
    // Root target
    Target root;
    root.name = "root";
    root.type = TargetType.Library;
    root.language = TargetLanguage.Python;
    auto rootPath = buildPath(workspacePath, "root.py");
    root.sources = [rootPath];
    std.file.write(rootPath, "# Root library\ndef common():\n    return 'common'\n");
    targets ~= root;
    
    // Leaf targets (all depend on root)
    foreach (i; 0 .. leafCount)
    {
        Target leaf;
        leaf.name = "leaf" ~ i.to!string;
        leaf.type = TargetType.Executable;
        leaf.language = TargetLanguage.Python;
        
        auto leafPath = buildPath(workspacePath, "leaf" ~ i.to!string ~ ".py");
        leaf.sources = [leafPath];
        std.file.write(leafPath, "# Leaf " ~ i.to!string ~ "\nimport root\n");
        
        leaf.deps = ["root"];
        targets ~= leaf;
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Created ", i + 1, " leaf targets...");
        }
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
    auto stats = graph.getStats();
    
    writeln("  Graph stats:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Max depth: ", stats.maxDepth);
    
    Assert.equal(stats.maxDepth, 2, "Should have depth 2 (root + leaves)");
    
    // Execute with high parallelism
    writeln("  Executing parallel build...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built in ", buildTimer.peek().total!"msecs", "ms");
    writeln("  Parallelism efficiency: ", 
            (leafCount * 1000.0) / (buildTimer.peek().total!"msecs" * totalCPUs), " x");
    
    writeln("\x1b[32m  ✓ Wide dependency tree stress test passed\x1b[0m");
}

/// Stress test: Deep dependency chain
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Deep dependency chain (1,000 levels)");
    
    auto tempDir = scoped(new TempDir("stress-deep"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create chain of 1,000 targets where each depends on previous
    immutable size_t chainLength = 1_000;
    Target[] targets;
    
    writeln("  Creating deep dependency chain...");
    
    foreach (i; 0 .. chainLength)
    {
        Target target;
        target.name = "chain" ~ i.to!string;
        target.type = TargetType.Library;
        target.language = TargetLanguage.Python;
        
        auto sourcePath = buildPath(workspacePath, "chain" ~ i.to!string ~ ".py");
        target.sources = [sourcePath];
        std.file.write(sourcePath, "# Chain link " ~ i.to!string ~ "\nvalue = " ~ i.to!string ~ "\n");
        
        // Depend on previous link
        if (i > 0)
        {
            target.deps = ["chain" ~ (i - 1).to!string];
        }
        
        targets ~= target;
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Created ", i + 1, " chain links...");
        }
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
    auto stats = graph.getStats();
    
    writeln("  Graph stats:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Max depth: ", stats.maxDepth);
    
    Assert.equal(stats.maxDepth, chainLength, "Should have depth equal to chain length");
    
    // Execute build (will be sequential due to dependencies)
    writeln("  Executing build (sequential due to dependencies)...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built ", chainLength, " links in ", buildTimer.peek().total!"msecs", "ms");
    
    writeln("\x1b[32m  ✓ Deep dependency chain stress test passed\x1b[0m");
}

/// Stress test: Diamond dependency pattern (many diamonds)
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Diamond dependency pattern (100 diamonds)");
    
    auto tempDir = scoped(new TempDir("stress-diamond"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create 100 diamond patterns
    // Each diamond: root -> left, right -> merge
    immutable size_t diamondCount = 100;
    Target[] targets;
    
    writeln("  Creating ", diamondCount, " diamond patterns...");
    
    foreach (i; 0 .. diamondCount)
    {
        string prefix = "d" ~ i.to!string ~ "_";
        
        // Root of diamond
        Target root;
        root.name = prefix ~ "root";
        root.type = TargetType.Library;
        root.language = TargetLanguage.Python;
        auto rootPath = buildPath(workspacePath, root.name ~ ".py");
        root.sources = [rootPath];
        std.file.write(rootPath, "# Diamond " ~ i.to!string ~ " root\n");
        targets ~= root;
        
        // Left path
        Target left;
        left.name = prefix ~ "left";
        left.type = TargetType.Library;
        left.language = TargetLanguage.Python;
        auto leftPath = buildPath(workspacePath, left.name ~ ".py");
        left.sources = [leftPath];
        left.deps = [root.name];
        std.file.write(leftPath, "# Diamond " ~ i.to!string ~ " left\n");
        targets ~= left;
        
        // Right path
        Target right;
        right.name = prefix ~ "right";
        right.type = TargetType.Library;
        right.language = TargetLanguage.Python;
        auto rightPath = buildPath(workspacePath, right.name ~ ".py");
        right.sources = [rightPath];
        right.deps = [root.name];
        std.file.write(rightPath, "# Diamond " ~ i.to!string ~ " right\n");
        targets ~= right;
        
        // Merge point
        Target merge;
        merge.name = prefix ~ "merge";
        merge.type = TargetType.Executable;
        merge.language = TargetLanguage.Python;
        auto mergePath = buildPath(workspacePath, merge.name ~ ".py");
        merge.sources = [mergePath];
        merge.deps = [left.name, right.name];
        std.file.write(mergePath, "# Diamond " ~ i.to!string ~ " merge\n");
        targets ~= merge;
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
    auto stats = graph.getStats();
    
    writeln("  Graph stats:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Max depth: ", stats.maxDepth);
    
    Assert.equal(stats.totalNodes, diamondCount * 4);
    
    // Execute build
    writeln("  Executing parallel build...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built ", stats.totalNodes, " targets in ", buildTimer.peek().total!"msecs", "ms");
    
    writeln("\x1b[32m  ✓ Diamond dependency pattern stress test passed\x1b[0m");
}

/// Stress test: Random dependency graph
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Random dependency graph (5,000 targets)");
    
    auto tempDir = scoped(new TempDir("stress-random"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    import std.random;
    
    // Create 5,000 targets with random dependencies
    immutable size_t targetCount = 5_000;
    Target[] targets;
    
    writeln("  Creating ", targetCount, " targets with random dependencies...");
    
    foreach (i; 0 .. targetCount)
    {
        Target target;
        target.name = "rand" ~ i.to!string;
        target.type = TargetType.Library;
        target.language = TargetLanguage.Python;
        
        auto sourcePath = buildPath(workspacePath, target.name ~ ".py");
        target.sources = [sourcePath];
        std.file.write(sourcePath, "# Random target " ~ i.to!string ~ "\n");
        
        // Add 0-3 random dependencies to earlier targets
        if (i > 0)
        {
            auto depCount = uniform(0, min(4, i));
            foreach (j; 0 .. depCount)
            {
                auto depIdx = uniform(0, i);
                auto depName = "rand" ~ depIdx.to!string;
                if (!target.deps.canFind(depName))
                {
                    target.deps ~= depName;
                }
            }
        }
        
        targets ~= target;
        
        if ((i + 1) % 500 == 0)
        {
            writeln("    Created ", i + 1, " targets...");
        }
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
    
    // Check for cycles
    auto sortResult = graph.topologicalSort();
    Assert.isTrue(sortResult.isOk, "Random graph should be acyclic");
    
    auto stats = graph.getStats();
    writeln("  Graph stats:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Max depth: ", stats.maxDepth);
    writeln("    Avg dependencies per target: ", stats.totalEdges * 1.0 / stats.totalNodes);
    
    // Execute build
    writeln("  Executing parallel build...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built ", targetCount, " targets in ", buildTimer.peek().total!"seconds", "s");
    writeln("  Throughput: ", (targetCount * 1000) / buildTimer.peek().total!"msecs", " targets/sec");
    
    writeln("\x1b[32m  ✓ Random dependency graph stress test passed\x1b[0m");
}

/// Performance benchmark: Compare serial vs parallel execution
version(none) unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m stress_parallel - Serial vs Parallel performance comparison");
    
    auto tempDir = scoped(new TempDir("perf-comparison"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create 100 independent targets
    immutable size_t targetCount = 100;
    Target[] targets;
    
    foreach (i; 0 .. targetCount)
    {
        Target target;
        target.name = "perf" ~ i.to!string;
        target.type = TargetType.Library;
        target.language = TargetLanguage.Python;
        
        auto sourcePath = buildPath(workspacePath, target.name ~ ".py");
        target.sources = [sourcePath];
        std.file.write(sourcePath, "# Performance test " ~ i.to!string ~ "\nimport time\n");
        
        targets ~= target;
    }
    
    // Serial execution (1 worker)
    writeln("  Testing serial execution (1 worker)...");
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
    auto serialTimer = StopWatch(AutoStart.yes);
    auto executor1 = new BuildExecutor(graph1, config, 1, null, false, false);
    executor1.execute();
    serialTimer.stop();
    auto serialTime = serialTimer.peek().total!"msecs";
    writeln("  Serial time: ", serialTime, "ms");
    
    // Parallel execution (all CPUs)
    writeln("  Testing parallel execution (", totalCPUs, " workers)...");
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
    auto parallelTimer = StopWatch(AutoStart.yes);
    auto executor2 = new BuildExecutor(graph2, config, totalCPUs, null, false, false);
    executor2.execute();
    parallelTimer.stop();
    auto parallelTime = parallelTimer.peek().total!"msecs";
    writeln("  Parallel time: ", parallelTime, "ms");
    
    // Calculate speedup
    auto speedup = cast(double)serialTime / cast(double)parallelTime;
    writeln("  Speedup: ", speedup, "x");
    writeln("  Efficiency: ", (speedup / totalCPUs * 100.0), "%");
    
    Assert.isTrue(parallelTime < serialTime, "Parallel should be faster than serial");
    Assert.isTrue(speedup >= 1.5, "Should see at least 1.5x speedup");
    
    writeln("\x1b[32m  ✓ Performance comparison passed\x1b[0m");
}

