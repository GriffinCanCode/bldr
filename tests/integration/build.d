module tests.integration.build;

import std.stdio;
import std.path;
import std.file;
import std.algorithm;
import engine.graph.core.graph;
import engine.runtime.core.engine.executor;
import infrastructure.config.schema.schema;
import infrastructure.config.parsing.parser;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m integration.build - Simple Python build");
    
    auto workspace = scoped(new MockWorkspace());
    
    // Create simple Python application
    workspace.createTarget("simple-app", TargetType.Executable, 
                          ["main.py"], []);
    
    // Parse workspace and build graph
    auto configResult = ConfigParser.parseWorkspace(workspace.getPath());
    Assert.isTrue(configResult.isOk);
    auto config = configResult.unwrap();
    Assert.notEmpty(config.targets);
    
    auto graph = new BuildGraph();
    foreach (ref target; config.targets)
    {
        graph.addTarget(target);
    }
    
    // Verify graph structure
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, 1);
    Assert.equal(stats.maxDepth, 0);
    
    writeln("\x1b[32m  ✓ Simple build integration test verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m integration.build - Multi-target build");
    
    auto workspace = scoped(new MockWorkspace());
    
    // Create library and application with dependency
    workspace.createTarget("lib", TargetType.Library, ["lib.py"], []);
    workspace.createTarget("app", TargetType.Executable, ["main.py"], ["//lib"]);
    
    // Parse workspace
    auto configResult = ConfigParser.parseWorkspace(workspace.getPath());
    Assert.isTrue(configResult.isOk);
    auto config = configResult.unwrap();
    Assert.equal(config.targets.length, 2);
    
    // Build dependency graph
    auto graph = new BuildGraph();
    foreach (ref target; config.targets)
    {
        graph.addTarget(target);
    }
    
    // Add dependencies between targets
    foreach (ref target; config.targets)
    {
        foreach (dep; target.deps)
        {
            // Find matching target
            // Handle both "//lib1" matching "//lib1:lib1" and "//lib1:lib1" matching "//lib1:lib1"
            foreach (ref depTarget; config.targets)
            {
                if (depTarget.name == dep ||
                    (depTarget.name.startsWith(dep) && depTarget.name.length > dep.length && depTarget.name[dep.length] == ':'))
                {
                    graph.addDependency(target.name, depTarget.name);
                    break;
                }
            }
        }
    }
    
    // Verify topological order
    auto sortedResult = graph.topologicalSort();
    Assert.isTrue(sortedResult.isOk);
    auto sorted = sortedResult.unwrap();
    Assert.equal(sorted.length, 2);
    
    // lib should come before app
    auto libIdx = sorted.countUntil!(n => n.id.toString().canFind("lib"));
    auto appIdx = sorted.countUntil!(n => n.id.toString().canFind("app"));
    Assert.isTrue(libIdx < appIdx);
    
    writeln("\x1b[32m  ✓ Multi-target build integration test verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m integration.build - Incremental rebuild");
    
    auto workspace = scoped(new MockWorkspace());
    
    workspace.createTarget("app", TargetType.Executable, ["main.py"], []);
    
    auto configResult = ConfigParser.parseWorkspace(workspace.getPath());
    Assert.isTrue(configResult.isOk);
    auto config = configResult.unwrap();
    auto graph = new BuildGraph();
    
    foreach (ref target; config.targets)
    {
        graph.addTarget(target);
    }
    
    // Initial build
    auto initialNodes = graph.getReadyNodes();
    Assert.notEmpty(initialNodes);
    
    // Mark as built
    foreach (node; initialNodes)
    {
        node.status = BuildStatus.Success;
    }
    
    // Verify no more ready nodes (all built)
    auto afterBuild = graph.getReadyNodes();
    Assert.isEmpty(afterBuild);
    
    // Reset for "rebuild" test
    foreach (node; initialNodes)
    {
        node.status = BuildStatus.Pending;
    }
    
    // Should have ready nodes again
    auto rebuilt = graph.getReadyNodes();
    Assert.notEmpty(rebuilt);
    
    writeln("\x1b[32m  ✓ Incremental rebuild integration test verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m integration.build - Complex dependency graph");
    
    auto workspace = scoped(new MockWorkspace());
    
    // Create complex dependency structure:
    // app -> middleware -> [lib1, lib2]
    // lib2 -> util
    workspace.createTarget("util", TargetType.Library, ["util.py"], []);
    workspace.createTarget("lib1", TargetType.Library, ["lib1.py"], []);
    workspace.createTarget("lib2", TargetType.Library, ["lib2.py"], ["//util"]);
    workspace.createTarget("middleware", TargetType.Library, 
                          ["middleware.py"], ["//lib1", "//lib2"]);
    workspace.createTarget("app", TargetType.Executable, 
                          ["app.py"], ["//middleware"]);
    
    auto configResult = ConfigParser.parseWorkspace(workspace.getPath());
    Assert.isTrue(configResult.isOk);
    auto config = configResult.unwrap();
    auto graph = new BuildGraph();
    
    // Build graph
    foreach (ref target; config.targets)
    {
        graph.addTarget(target);
    }
    
    // Add all dependencies
    foreach (ref target; config.targets)
    {
        foreach (dep; target.deps)
        {
            // The dep might be "//lib1" and the target name might be "//lib1:lib1"
            // Or dep might be a full path like "//lib1:lib1"
            // Match if the target name starts with the dep path
            foreach (ref depTarget; config.targets)
            {
                // Check if target name matches the dependency
                // Handle both "//lib1" matching "//lib1:lib1" and "//lib1:lib1" matching "//lib1:lib1"
                if (depTarget.name == dep ||  // Exact match
                    (depTarget.name.startsWith(dep) && depTarget.name.length > dep.length && depTarget.name[dep.length] == ':'))
                {
                    graph.addDependency(target.name, depTarget.name);
                    break;
                }
            }
        }
    }
    
    // Verify graph structure
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, 5);
    Assert.isTrue(stats.maxDepth >= 3);
    
    // Verify topological order respects dependencies
    auto sortedResult = graph.topologicalSort();
    Assert.isTrue(sortedResult.isOk);
    auto sorted = sortedResult.unwrap();
    Assert.equal(sorted.length, 5);
    
    // util should come before lib2
    auto utilIdx = sorted.countUntil!(n => n.id.toString().canFind("util"));
    auto lib2Idx = sorted.countUntil!(n => n.id.toString().canFind("lib2"));
    Assert.isTrue(utilIdx < lib2Idx);
    
    // middleware should come after lib1 and lib2
    auto midIdx = sorted.countUntil!(n => n.id.toString().canFind("middleware"));
    auto lib1Idx = sorted.countUntil!(n => n.id.toString().canFind("lib1"));
    Assert.isTrue(lib1Idx < midIdx);
    Assert.isTrue(lib2Idx < midIdx);
    
    // app should be last
    auto appIdx = sorted.countUntil!(n => n.id.toString().canFind("app"));
    Assert.isTrue(midIdx < appIdx);
    
    writeln("\x1b[32m  ✓ Complex dependency graph integration test verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m integration.build - Parallel build opportunities");
    
    auto workspace = scoped(new MockWorkspace());
    
    // Create structure with parallelism:
    // app -> [lib1, lib2, lib3] (all parallel)
    workspace.createTarget("lib1", TargetType.Library, ["lib1.py"], []);
    workspace.createTarget("lib2", TargetType.Library, ["lib2.py"], []);
    workspace.createTarget("lib3", TargetType.Library, ["lib3.py"], []);
    workspace.createTarget("app", TargetType.Executable, 
                          ["app.py"], ["//lib1", "//lib2", "//lib3"]);
    
    auto configResult = ConfigParser.parseWorkspace(workspace.getPath());
    Assert.isTrue(configResult.isOk);
    auto config = configResult.unwrap();
    auto graph = new BuildGraph();
    
    foreach (ref target; config.targets)
    {
        graph.addTarget(target);
    }
    
    foreach (ref target; config.targets)
    {
        foreach (dep; target.deps)
        {
            foreach (ref depTarget; config.targets)
            {
                if (depTarget.name == dep ||
                    (depTarget.name.startsWith(dep) && depTarget.name.length > dep.length && depTarget.name[dep.length] == ':'))
                {
                    graph.addDependency(target.name, depTarget.name);
                    break;
                }
            }
        }
    }
    
    // Verify parallelism
    auto stats = graph.getStats();
    Assert.equal(stats.parallelism, 3); // lib1, lib2, lib3 can build in parallel
    
    // Initially all 3 libs should be ready
    auto ready = graph.getReadyNodes();
    Assert.equal(ready.length, 3);
    
    writeln("\x1b[32m  ✓ Parallel build opportunities verified\x1b[0m");
}

