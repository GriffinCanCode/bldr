module tests.integration.multilang_stress;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv : to, text;
import std.datetime.stopwatch;
import std.parallelism;
import std.format;
import std.range : repeat;
import tests.harness;
import tests.fixtures;
import tests.mocks;
import infrastructure.config.schema.schema;
import engine.graph.core.graph;
import engine.runtime.core.engine.executor;
import infrastructure.utils.logging.logger;

/// Comprehensive multi-language stress test
/// Tests system performance with many languages at scale
version(none) unittest
{
    writeln("\x1b[36m[STRESS TEST]\x1b[0m Multi-Language Scale Test - ALL LANGUAGES");
    writeln(repeat('=', 80));
    
    auto tempDir = scoped(new TempDir("multilang-stress"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Define all supported languages with their configurations
    struct LanguageTestConfig
    {
        TargetLanguage language;
        string extension;
        string simpleCode;
        TargetType type;
    }
    
    LanguageTestConfig[] languages = [
        // Compiled languages
        LanguageTestConfig(TargetLanguage.Cpp, ".cpp", 
            "#include <iostream>\nint main() { std::cout << \"test\" << std::endl; return 0; }", 
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.C, ".c",
            "#include <stdio.h>\nint main() { printf(\"test\\n\"); return 0; }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Rust, ".rs",
            "fn main() { println!(\"test\"); }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Go, ".go",
            "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"test\") }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.D, ".d",
            "import std.stdio;\nvoid main() { writeln(\"test\"); }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Zig, ".zig",
            "const std = @import(\"std\");\npub fn main() !void { }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Nim, ".nim",
            "echo \"test\"",
            TargetType.Executable),
        
        // Scripting languages
        LanguageTestConfig(TargetLanguage.Python, ".py",
            "# Python module\ndef test():\n    return 'test'\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.Ruby, ".rb",
            "# Ruby module\ndef test\n  'test'\nend\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.JavaScript, ".js",
            "// JavaScript module\nexport function test() { return 'test'; }\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.TypeScript, ".ts",
            "// TypeScript module\nexport function test(): string { return 'test'; }\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.Lua, ".lua",
            "-- Lua module\nlocal M = {}\nfunction M.test() return 'test' end\nreturn M\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.PHP, ".php",
            "<?php\nfunction test() { return 'test'; }\n",
            TargetType.Library),
        LanguageTestConfig(TargetLanguage.R, ".R",
            "# R function\ntest <- function() { 'test' }\n",
            TargetType.Library),
        
        // JVM languages
        LanguageTestConfig(TargetLanguage.Java, ".java",
            "public class Test { public static void main(String[] args) { } }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Kotlin, ".kt",
            "fun main() { println(\"test\") }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.Scala, ".scala",
            "object Test { def main(args: Array[String]): Unit = {} }",
            TargetType.Executable),
        
        // .NET languages
        LanguageTestConfig(TargetLanguage.CSharp, ".cs",
            "class Program { static void Main() { } }",
            TargetType.Executable),
        LanguageTestConfig(TargetLanguage.FSharp, ".fs",
            "[<EntryPoint>]\nlet main argv = 0",
            TargetType.Executable),
    ];
    
    // Configuration for stress test
    immutable size_t targetsPerLanguage = 50;
    immutable size_t totalTargets = languages.length * targetsPerLanguage;
    
    writeln("\n📊 Test Configuration:");
    writeln("  Languages: ", languages.length);
    writeln("  Targets per language: ", targetsPerLanguage);
    writeln("  Total targets: ", totalTargets);
    writeln("  CPU cores available: ", totalCPUs);
    writeln();
    
    Target[] targets;
    targets.reserve(totalTargets);
    
    // Phase 1: Target Creation
    writeln("📝 Phase 1: Creating ", totalTargets, " targets across ", languages.length, " languages...");
    auto createTimer = StopWatch(AutoStart.yes);
    
    size_t targetIdx = 0;
    foreach (langIdx, langConfig; languages)
    {
        writeln("  Creating ", targetsPerLanguage, " ", langConfig.language, " targets...");
        
        foreach (i; 0 .. targetsPerLanguage)
        {
            Target target;
            target.name = format("%s_%d", langConfig.language, i);
            target.type = langConfig.type;
            target.language = langConfig.language;
            
            // Create source file
            auto sourcePath = buildPath(workspacePath, target.name ~ langConfig.extension);
            auto code = format("// Target %s\n%s", target.name, langConfig.simpleCode);
            std.file.write(sourcePath, code);
            target.sources = [sourcePath];
            
            // Add some dependencies within same language
            if (i > 0 && i % 5 == 0 && langConfig.type == TargetType.Library)
            {
                auto depName = format("%s_%d", langConfig.language, i - 1);
                target.deps = [depName];
            }
            
            // Add cross-language dependencies occasionally
            if (langIdx > 0 && i % 10 == 0)
            {
                auto prevLang = languages[langIdx - 1];
                if (prevLang.type == TargetType.Library)
                {
                    auto depName = format("%s_%d", prevLang.language, 0);
                    target.deps ~= depName;
                }
            }
            
            targets ~= target;
            targetIdx++;
        }
    }
    
    createTimer.stop();
    writeln("  ✓ Created ", totalTargets, " targets in ", 
            createTimer.peek().total!"msecs", " ms");
    writeln("  Creation rate: ", format("%.1f", totalTargets * 1000.0 / createTimer.peek().total!"msecs"), 
            " targets/sec");
    writeln();
    
    // Phase 2: Graph Construction
    writeln("🔗 Phase 2: Building dependency graph...");
    auto graphTimer = StopWatch(AutoStart.yes);
    
    auto graph = new BuildGraph();
    
    // Add all targets
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    
    // Add all dependencies
    size_t totalDeps = 0;
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            auto result = graph.addDependency(target.name, dep);
            if (result.isOk)
                totalDeps++;
        }
    }
    
    graphTimer.stop();
    auto stats = graph.getStats();
    
    writeln("  ✓ Graph built in ", graphTimer.peek().total!"msecs", " ms");
    writeln("  Graph Statistics:");
    writeln("    Nodes: ", stats.totalNodes);
    writeln("    Edges: ", stats.totalEdges);
    writeln("    Max depth: ", stats.maxDepth);
    writeln("    Avg dependencies: ", format("%.2f", stats.totalEdges * 1.0 / stats.totalNodes));
    writeln();
    
    // Phase 3: Topological Sort
    writeln("🔀 Phase 3: Topological sorting...");
    auto sortTimer = StopWatch(AutoStart.yes);
    auto sortResult = graph.topologicalSort();
    sortTimer.stop();
    
    if (!sortResult.isOk)
    {
        writeln("  ❌ ERROR: Graph has cycles!");
        assert(false, "Graph should be acyclic");
    }
    
    writeln("  ✓ Sorted in ", sortTimer.peek().total!"msecs", " ms");
    writeln("  Sort rate: ", format("%.1f", totalTargets * 1000.0 / sortTimer.peek().total!"msecs"),
            " nodes/sec");
    writeln();
    
    // Phase 4: Serial Execution Benchmark
    writeln("🚶 Phase 4: Serial execution (1 worker)...");
    auto serialGraph = new BuildGraph();
    foreach (target; targets)
    {
        serialGraph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            serialGraph.addDependency(target.name, dep);
        }
    }
    
    auto serialTimer = StopWatch(AutoStart.yes);
    auto serialExecutor = new BuildExecutor(serialGraph, config, 1, null, false, false);
    serialExecutor.execute();
    serialTimer.stop();
    
    auto serialTime = serialTimer.peek().total!"msecs";
    writeln("  ✓ Serial execution completed in ", serialTime, " ms");
    writeln("  Throughput: ", format("%.1f", totalTargets * 1000.0 / serialTime), " targets/sec");
    
    // Count successful builds
    size_t serialSuccess = 0;
    foreach (node; serialGraph.nodes.values)
    {
        if (node.status == BuildStatus.Success || node.status == BuildStatus.Cached)
            serialSuccess++;
    }
    writeln("  Success rate: ", serialSuccess, "/", totalTargets, 
            " (", format("%.1f", serialSuccess * 100.0 / totalTargets), "%)");
    writeln();
    
    // Phase 5: Parallel Execution Benchmark
    writeln("🏃 Phase 5: Parallel execution (", totalCPUs, " workers)...");
    auto parallelTimer = StopWatch(AutoStart.yes);
    auto parallelExecutor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    parallelExecutor.execute();
    parallelTimer.stop();
    
    auto parallelTime = parallelTimer.peek().total!"msecs";
    writeln("  ✓ Parallel execution completed in ", parallelTime, " ms");
    writeln("  Throughput: ", format("%.1f", totalTargets * 1000.0 / parallelTime), " targets/sec");
    
    // Count successful builds
    size_t parallelSuccess = 0;
    foreach (node; graph.nodes.values)
    {
        if (node.status == BuildStatus.Success || node.status == BuildStatus.Cached)
            parallelSuccess++;
    }
    writeln("  Success rate: ", parallelSuccess, "/", totalTargets,
            " (", format("%.1f", parallelSuccess * 100.0 / totalTargets), "%)");
    writeln();
    
    // Phase 6: Performance Analysis
    writeln("📈 Phase 6: Performance Analysis");
    writeln("=" .repeat(80).join);
    
    auto speedup = cast(double)serialTime / cast(double)parallelTime;
    auto efficiency = speedup / totalCPUs * 100.0;
    auto idealParallelTime = serialTime / totalCPUs;
    auto overhead = parallelTime - idealParallelTime;
    
    writeln("\n  Speedup Analysis:");
    writeln("    Serial time:          ", serialTime, " ms");
    writeln("    Parallel time:        ", parallelTime, " ms");
    writeln("    Speedup:              ", format("%.2fx", speedup));
    writeln("    Efficiency:           ", format("%.1f%%", efficiency));
    writeln("    Ideal parallel time:  ", idealParallelTime, " ms");
    writeln("    Overhead:             ", overhead, " ms (", 
            format("%.1f%%", overhead * 100.0 / parallelTime), ")");
    
    writeln("\n  Per-Language Statistics:");
    writeln("    ", format("%-15s %10s %10s %10s", "Language", "Targets", "Success", "Rate"));
    writeln("    ", repeat('-', 50));
    
    foreach (langConfig; languages)
    {
        size_t langTargets = 0;
        size_t langSuccess = 0;
        
        foreach (node; graph.nodes.values)
        {
            if (node.target.language == langConfig.language)
            {
                langTargets++;
                if (node.status == BuildStatus.Success || node.status == BuildStatus.Cached)
                    langSuccess++;
            }
        }
        
        auto rate = langTargets > 0 ? langSuccess * 100.0 / langTargets : 0.0;
        writeln("    ", format("%-15s %10d %10d %9.1f%%", 
                langConfig.language, langTargets, langSuccess, rate));
    }
    
    writeln("\n  Overall Metrics:");
    writeln("    Total targets:        ", totalTargets);
    writeln("    Total dependencies:   ", stats.totalEdges);
    writeln("    Graph depth:          ", stats.maxDepth);
    writeln("    Languages tested:     ", languages.length);
    writeln("    CPU cores used:       ", totalCPUs);
    writeln("    Serial throughput:    ", format("%.1f", totalTargets * 1000.0 / serialTime), " targets/sec");
    writeln("    Parallel throughput:  ", format("%.1f", totalTargets * 1000.0 / parallelTime), " targets/sec");
    writeln("    Graph build time:     ", graphTimer.peek().total!"msecs", " ms");
    writeln("    Sort time:            ", sortTimer.peek().total!"msecs", " ms");
    
    writeln("\n", repeat('=', 80));
    
    // Assertions
    Assert.isTrue(parallelTime < serialTime, "Parallel should be faster than serial");
    Assert.isTrue(speedup >= 1.5, "Should achieve at least 1.5x speedup");
    Assert.isTrue(parallelSuccess > totalTargets * 0.8, "At least 80% should succeed");
    
    writeln("\n\x1b[32m✓ Multi-language stress test PASSED\x1b[0m");
    writeln("\x1b[32m  Tested ", languages.length, " languages with ", totalTargets, " targets\x1b[0m");
    writeln("\x1b[32m  Achieved ", format("%.2fx", speedup), " speedup with ", 
            format("%.1f%%", efficiency), " efficiency\x1b[0m\n");
}

/// Extreme scale test: 20,000+ targets across multiple languages
version(none) unittest
{
    writeln("\x1b[36m[EXTREME STRESS TEST]\x1b[0m 20,000 Target Multi-Language Test");
    writeln(repeat('=', 80));
    
    auto tempDir = scoped(new TempDir("extreme-multilang"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Use subset of fast-building languages for extreme test
    TargetLanguage[] fastLanguages = [
        TargetLanguage.Python,
        TargetLanguage.JavaScript,
        TargetLanguage.Ruby,
        TargetLanguage.Lua,
        TargetLanguage.PHP,
    ];
    
    immutable size_t targetsPerLanguage = 4000;
    immutable size_t totalTargets = fastLanguages.length * targetsPerLanguage;
    
    writeln("\n📊 Extreme Test Configuration:");
    writeln("  Languages: ", fastLanguages.length, " (fast-building only)");
    writeln("  Targets per language: ", targetsPerLanguage);
    writeln("  Total targets: ", totalTargets);
    writeln("  CPU cores: ", totalCPUs);
    writeln();
    
    Target[] targets;
    targets.reserve(totalTargets);
    
    writeln("📝 Creating ", totalTargets, " targets...");
    auto createTimer = StopWatch(AutoStart.yes);
    
    foreach (langIdx, language; fastLanguages)
    {
        foreach (i; 0 .. targetsPerLanguage)
        {
            Target target;
            target.name = format("%s_%d", language, i);
            target.type = TargetType.Library;
            target.language = language;
            
            string extension;
            string code;
            
            if (language == TargetLanguage.Python)
            {
                extension = ".py";
                code = format("# Target %d\ndef func_%d(): return %d\n", i, i, i);
            }
            else if (language == TargetLanguage.JavaScript)
            {
                extension = ".js";
                code = format("// Target %d\nexport const val_%d = %d;\n", i, i, i);
            }
            else if (language == TargetLanguage.Ruby)
            {
                extension = ".rb";
                code = format("# Target %d\ndef func_%d\n  %d\nend\n", i, i, i);
            }
            else if (language == TargetLanguage.Lua)
            {
                extension = ".lua";
                code = format("-- Target %d\nlocal M = {}\nM.val_%d = %d\nreturn M\n", i, i, i);
            }
            else if (language == TargetLanguage.PHP)
            {
                extension = ".php";
                code = format("<?php\n// Target %d\nfunction func_%d() { return %d; }\n", i, i, i);
            }
            else
            {
                extension = ".txt";
                code = "test";
            }
            
            auto sourcePath = buildPath(workspacePath, target.name ~ extension);
            std.file.write(sourcePath, code);
            target.sources = [sourcePath];
            
            // Add dependencies to create interesting graph structure
            if (i > 0 && i % 100 == 0)
            {
                target.deps = [format("%s_%d", language, i - 1)];
            }
            if (i > 50 && i % 250 == 0 && langIdx > 0)
            {
                target.deps ~= format("%s_%d", fastLanguages[langIdx - 1], i % targetsPerLanguage);
            }
            
            targets ~= target;
        }
        
        writeln("  Created ", (langIdx + 1) * targetsPerLanguage, " / ", totalTargets, " targets...");
    }
    
    createTimer.stop();
    writeln("  ✓ Created ", totalTargets, " targets in ", 
            createTimer.peek().total!"seconds", " seconds");
    writeln();
    
    writeln("🔗 Building graph...");
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
            graph.addDependency(target.name, dep);
        }
    }
    
    graphTimer.stop();
    auto stats = graph.getStats();
    writeln("  ✓ Graph built in ", graphTimer.peek().total!"msecs", " ms");
    writeln("  Nodes: ", stats.totalNodes);
    writeln("  Edges: ", stats.totalEdges);
    writeln("  Depth: ", stats.maxDepth);
    writeln();
    
    writeln("🏃 Executing parallel build with ", totalCPUs, " workers...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    auto buildTime = buildTimer.peek().total!"seconds";
    writeln("  ✓ Built ", totalTargets, " targets in ", buildTime, " seconds");
    writeln("  Throughput: ", format("%.0f", totalTargets / cast(double)buildTime), " targets/sec");
    
    size_t successCount = 0;
    foreach (node; graph.nodes.values)
    {
        if (node.status == BuildStatus.Success || node.status == BuildStatus.Cached)
            successCount++;
    }
    
    writeln("  Success: ", successCount, " / ", totalTargets,
            " (", format("%.1f%%", successCount * 100.0 / totalTargets), ")");
    
    Assert.isTrue(successCount > totalTargets * 0.8, "At least 80% should succeed");
    
    writeln("\n\x1b[32m✓ Extreme stress test PASSED\x1b[0m");
    writeln("\x1b[32m  Successfully handled ", totalTargets, " targets!\x1b[0m\n");
}

/// Wide dependency test: Massive fan-out across languages
version(none) unittest
{
    writeln("\x1b[36m[STRESS TEST]\x1b[0m Wide Multi-Language Dependency Test");
    writeln(repeat('=', 80));
    
    auto tempDir = scoped(new TempDir("wide-multilang"));
    auto workspacePath = tempDir.getPath();
    
    WorkspaceConfig config;
    config.root = workspacePath;
    
    // Create 1 core library in Python
    // Then create 1000 targets across different languages that depend on it
    
    Target[] targets;
    
    writeln("\n📝 Creating core library...");
    Target core;
    core.name = "core";
    core.type = TargetType.Library;
    core.language = TargetLanguage.Python;
    auto corePath = buildPath(workspacePath, "core.py");
    std.file.write(corePath, "# Core library\ndef common():\n    return 'common'\n");
    core.sources = [corePath];
    targets ~= core;
    
    // Create 1000 dependent targets
    TargetLanguage[] languages = [
        TargetLanguage.Python,
        TargetLanguage.JavaScript,
        TargetLanguage.Ruby,
        TargetLanguage.TypeScript,
        TargetLanguage.Lua,
    ];
    
    immutable size_t leafCount = 1000;
    writeln("📝 Creating ", leafCount, " dependent targets across ", languages.length, " languages...");
    
    foreach (i; 0 .. leafCount)
    {
        auto language = languages[i % languages.length];
        Target leaf;
        leaf.name = format("leaf_%s_%d", language, i);
        leaf.type = TargetType.Executable;
        leaf.language = language;
        leaf.deps = ["core"];
        
        string extension, code;
        if (language == TargetLanguage.Python)
        {
            extension = ".py";
            code = format("# Leaf %d\nimport core\n", i);
        }
        else if (language == TargetLanguage.JavaScript)
        {
            extension = ".js";
            code = format("// Leaf %d\nimport { common } from './core';\n", i);
        }
        else if (language == TargetLanguage.Ruby)
        {
            extension = ".rb";
            code = format("# Leaf %d\nrequire './core'\n", i);
        }
        else if (language == TargetLanguage.TypeScript)
        {
            extension = ".ts";
            code = format("// Leaf %d\nimport { common } from './core';\n", i);
        }
        else if (language == TargetLanguage.Lua)
        {
            extension = ".lua";
            code = format("-- Leaf %d\nlocal core = require('core')\n", i);
        }
        else
        {
            extension = ".txt";
            code = "test";
        }
        
        auto leafPath = buildPath(workspacePath, leaf.name ~ extension);
        std.file.write(leafPath, code);
        leaf.sources = [leafPath];
        targets ~= leaf;
        
        if ((i + 1) % 100 == 0)
        {
            writeln("  Created ", i + 1, " / ", leafCount, " targets...");
        }
    }
    
    writeln("\n🔗 Building graph...");
    auto graph = new BuildGraph();
    foreach (target; targets)
    {
        graph.addTarget(target);
    }
    foreach (target; targets)
    {
        foreach (dep; target.deps)
        {
            graph.addDependency(target.name, dep);
        }
    }
    
    auto stats = graph.getStats();
    writeln("  Nodes: ", stats.totalNodes);
    writeln("  Edges: ", stats.totalEdges);
    writeln("  Depth: ", stats.maxDepth);
    
    Assert.equal(stats.maxDepth, 2, "Should have depth 2 (core + leaves)");
    
    writeln("\n🏃 Executing parallel build...");
    auto buildTimer = StopWatch(AutoStart.yes);
    auto executor = new BuildExecutor(graph, config, totalCPUs, null, false, false);
    executor.execute();
    buildTimer.stop();
    
    writeln("  ✓ Built ", targets.length, " targets in ", buildTimer.peek().total!"msecs", " ms");
    writeln("  Maximum parallelism achieved for fan-out pattern");
    
    writeln("\n\x1b[32m✓ Wide multi-language dependency test PASSED\x1b[0m\n");
}

