module frontend.cli.commands.execution.discover;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.json;
import infrastructure.config.parsing.parser;
import infrastructure.analysis.inference.analyzer;
import engine.runtime.services;
import engine.graph;
import infrastructure.utils.logging.logger;
import infrastructure.errors;
import infrastructure.errors.formatting.format;

/// Discover command - preview dynamic dependency discovery without building
void discoverCommand(string[] args)
{
    Logger.info("Analyzing project for dynamic dependencies...");
    
    // Parse configuration
    auto configResult = ConfigParser.parseWorkspace(".");
    if (configResult.isErr)
    {
        Logger.error("Failed to parse workspace configuration");
        Logger.error(format(configResult.unwrapErr()));
        return;
    }
    
    auto config = configResult.unwrap();
    
    // Create analyzer with no incremental support (not needed for discovery)
    auto analyzer = new DependencyAnalyzer(config, null, ".builder-cache");
    
    // Analyze dependencies
    auto graphResult = analyzer.analyze("");
    if (graphResult.isErr)
    {
        Logger.error("Failed to analyze dependencies");
        Logger.error(format(graphResult.unwrapErr()));
        return;
    }
    
    auto graph = graphResult.unwrap();
    
    // Create dynamic graph wrapper
    auto dynamicGraph = new DynamicBuildGraph(graph);
    
    // Mark discoverable targets
    import engine.runtime.core.engine.discovery;
    DiscoveryMarker.markCodeGenTargets(dynamicGraph);
    
    // Count discoverable targets
    size_t discoverableCount = 0;
    string[] discoverableTargets;
    
    foreach (node; graph.nodes.values)
    {
        if (dynamicGraph.isDiscoverable(node.id))
        {
            discoverableCount++;
            discoverableTargets ~= node.idString;
        }
    }
    
    // Report findings
    writeln();
    Logger.success("Discovery Analysis Complete");
    writeln();
    writeln("Targets with discovery capability: " ~ discoverableCount.to!string);
    
    if (discoverableCount > 0)
    {
        writeln();
        writeln("Discoverable Targets:");
        foreach (target; discoverableTargets)
        {
            writeln("  • " ~ target);
            
            // Show what each target will discover
            if (auto node = target in graph.nodes)
            {
                if (node.target.language.to!string == "protobuf")
                {
                    writeln("    └─ Will discover: Generated source files + compile targets");
                }
                else if (node.target.type.to!string == "custom")
                {
                    writeln("    └─ Will discover: Custom generated targets");
                }
            }
        }
        
        writeln();
        writeln("💡 These targets will discover new dependencies at build time");
        writeln("   Run 'bldr build' to execute discovery and build");
    }
    else
    {
        writeln();
        writeln("ℹ️  No discoverable targets found in this project");
        writeln("   Dynamic discovery is useful for:");
        writeln("     • Protocol Buffer code generation");
        writeln("     • GraphQL schema generation");
        writeln("     • Template expansion");
        writeln("     • Dynamic test generation");
    }
    
    writeln();
}

/// Show discovery history from previous builds
void discoverHistoryCommand()
{
    Logger.info("Loading discovery history...");
    
    auto historyFile = ".builder-cache/discovery-history.json";
    if (!exists(historyFile))
    {
        Logger.warning("No discovery history found");
        writeln("Run 'bldr build' first to generate discovery data");
        return;
    }
    
    try
    {
        auto jsonContent = readText(historyFile);
        auto history = parseJSON(jsonContent);
        
        if ("discoveries" in history)
        {
            auto discoveries = history["discoveries"].array;
            
            writeln();
            Logger.success("Discovery History (" ~ discoveries.length.to!string ~ " discoveries)");
            writeln();
            
            foreach (i, discovery; discoveries)
            {
                auto origin = discovery["origin"].str;
                auto timestamp = discovery["timestamp"].str;
                auto outputs = discovery["outputs"].array.length;
                auto targets = discovery["newTargets"].array.length;
                
                writeln("Discovery #" ~ (i+1).to!string ~ ":");
                writeln("  Origin: " ~ origin);
                writeln("  Time: " ~ timestamp);
                writeln("  Outputs discovered: " ~ outputs.to!string);
                writeln("  Targets created: " ~ targets.to!string);
                
                if ("metadata" in discovery)
                {
                    writeln("  Metadata:");
                    foreach (key, value; discovery["metadata"].object)
                    {
                        writeln("    " ~ key ~ ": " ~ value.str);
                    }
                }
                
                writeln();
            }
        }
    }
    catch (Exception e)
    {
        Logger.error("Failed to read discovery history: " ~ e.msg);
    }
}


