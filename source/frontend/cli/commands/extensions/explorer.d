module frontend.cli.commands.extensions.explorer;

import std.stdio;
import std.string;
import std.algorithm;
import std.conv;
import frontend.cli.explorer;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import engine.graph.persistence.index;
import engine.graph.persistence.queries;
import engine.graph.core.graph : BuildStatus;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Explorer command - Interactive dependency graph exploration
struct ExplorerCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    private static bool initialized = false;
    
    /// Initialize terminal and formatter
    private static void init() @system
    {
        if (!initialized)
        {
            auto caps = Capabilities.detect();
            terminal = Terminal(caps);
            formatter = Formatter(caps);
            initialized = true;
        }
    }
    
    /// Execute explore command - launch interactive TUI
    static void execute(
        string target = "",
        bool criticalPath = false,
        bool nonInteractive = false,
        string cacheDir = ".builder-cache") @system
    {
        init();
        
        // Check for non-interactive mode (scripting support)
        if (nonInteractive)
        {
            executeNonInteractive(target, criticalPath, cacheDir);
            return;
        }
        
        // Check terminal capability
        auto caps = Capabilities.detect();
        if (!caps.isInteractive)
        {
            terminal.writeColored("Error: ", Color.Red, Style.Bold);
            terminal.writeln("Interactive explore mode requires a TTY");
            terminal.writeln("Use --non-interactive for script-friendly output");
            terminal.flush();
            return;
        }
        
        // Launch interactive TUI
        try
        {
            auto explorer = new DependencyExplorer(cacheDir);
            
            if (criticalPath)
            {
                // Start in critical path view
                explorer.run(target);
            }
            else
            {
                explorer.run(target);
            }
        }
        catch (Exception e)
        {
            terminal.writeColored("Error: ", Color.Red, Style.Bold);
            terminal.writeln(e.msg);
            terminal.flush();
            
            structuredLog.debug_("explorer_error_").field("detail", "Explorer error: " ~ e.toString()).emit();
        }
    }
    
    /// Non-interactive mode for scripting
    private static void executeNonInteractive(string target, bool criticalPath, string cacheDir) @system
    {
        try
        {
            auto graphIndex = new GraphIndex(cacheDir);
            auto graphQuery = GraphQuery(graphIndex);
            auto graphRenderer = GraphRenderer(Capabilities.detect());
            
            if (criticalPath)
            {
                // Show critical path
                auto path = graphIndex.getCriticalPath();
                
                terminal.writeln();
                terminal.writeColored("Critical Path Analysis\n", Color.Cyan, Style.Bold);
                terminal.writeColored("══════════════════════════════════════\n\n", Color.BrightBlack);
                
                if (path.length == 0)
                {
                    terminal.writeln("  No critical path found (empty graph)");
                }
                else
                {
                    long totalTime;
                    foreach (i, nodeId; path)
                    {
                        auto nodeResult = graphIndex.getNode(nodeId);
                        auto duration = nodeResult.isOk ? nodeResult.unwrap().buildDuration : 0;
                        totalTime += duration;
                        
                        terminal.write(format("  %2d. ", i + 1));
                        terminal.writeColored(nodeId, Color.White);
                        
                        if (duration > 0)
                        {
                            terminal.write("  ");
                            terminal.writeColored(formatDurationMs(duration), Color.Yellow);
                        }
                        terminal.writeln();
                    }
                    
                    terminal.writeln();
                    terminal.write("  Total time: ");
                    terminal.writeColored(formatDurationMs(totalTime), Color.Green, Style.Bold);
                    terminal.write(format(" (%d steps)\n", path.length));
                }
            }
            else if (target.length > 0)
            {
                // Show target details
                auto nodeResult = graphIndex.getNode(target);
                
                if (nodeResult.isErr)
                {
                    terminal.writeColored("Error: ", Color.Red, Style.Bold);
                    terminal.writeln("Target not found: " ~ target);
                    return;
                }
                
                auto node = nodeResult.unwrap();
                auto deps = graphIndex.getDependencies(target);
                auto dependents = graphIndex.getDependents(target);
                auto impacted = graphQuery.getImpact(target);
                
                terminal.writeln();
                terminal.writeColored("Target Details: ", Color.Cyan, Style.Bold);
                terminal.writeColored(node.targetName ~ "\n", Color.White);
                terminal.writeColored("══════════════════════════════════════\n\n", Color.BrightBlack);
                
                printDetail("Type", node.targetType);
                printDetail("Status", statusString(node.status), statusColor(node.status));
                printDetail("Depth", node.depth.to!string);
                printDetail("Output", node.outputPath);
                
                if (node.buildDuration > 0)
                    printDetail("Build Time", formatDurationMs(node.buildDuration));
                
                if (node.hash.length > 0)
                    printDetail("Hash", node.hash[0 .. min(40, node.hash.length)] ~ "...");
                
                terminal.writeln();
                terminal.writeColored(format("  Dependencies (%d):\n", deps.length), Color.Yellow);
                foreach (i, dep; deps)
                {
                    if (i >= 10)
                    {
                        terminal.writeColored(format("    ... and %d more\n", deps.length - 10), Color.BrightBlack);
                        break;
                    }
                    terminal.write("    → ");
                    terminal.writeln(dep);
                }
                
                terminal.writeln();
                terminal.writeColored(format("  Dependents (%d):\n", dependents.length), Color.Magenta);
                foreach (i, dep; dependents)
                {
                    if (i >= 10)
                    {
                        terminal.writeColored(format("    ... and %d more\n", dependents.length - 10), Color.BrightBlack);
                        break;
                    }
                    terminal.write("    ← ");
                    terminal.writeln(dep);
                }
                
                terminal.writeln();
                terminal.writeColored(format("  Impact Analysis: ", Color.Red), Color.Red);
                terminal.writeln(format("%d targets would rebuild if this changes", impacted.length));
            }
            else
            {
                // Show graph summary
                auto stats = graphIndex.getStats();
                auto bottlenecks = graphQuery.findBottlenecks(5);
                
                terminal.writeln();
                terminal.writeColored("Build Graph Summary\n", Color.Cyan, Style.Bold);
                terminal.writeColored("══════════════════════════════════════\n\n", Color.BrightBlack);
                
                printDetail("Total Nodes", stats.totalNodes.to!string);
                printDetail("Total Edges", stats.totalEdges.to!string);
                printDetail("Max Depth", stats.maxDepth.to!string);
                printDetail("Cache Rate", format("%.1f%%", stats.cacheRate()));
                
                terminal.writeln();
                printDetail("Pending", stats.pendingNodes.to!string, Color.BrightBlack);
                printDetail("Success", stats.successNodes.to!string, Color.Green);
                printDetail("Cached", stats.cachedNodes.to!string, Color.Yellow);
                printDetail("Failed", stats.failedNodes.to!string, Color.Red);
                
                if (bottlenecks.length > 0)
                {
                    terminal.writeln();
                    terminal.writeColored("  Top Bottlenecks:\n", Color.Yellow, Style.Bold);
                    foreach (i, b; bottlenecks)
                    {
                        if (i >= 5) break;
                        terminal.write(format("    %d. ", i + 1));
                        terminal.writeColored(truncate(b.nodeId, 35), Color.White);
                        terminal.write(format(" (%d deps)\n", b.dependentCount));
                    }
                }
            }
            
            terminal.writeln();
            terminal.flush();
        }
        catch (Exception e)
        {
            terminal.writeColored("Error: ", Color.Red, Style.Bold);
            terminal.writeln(e.msg);
            terminal.flush();
        }
    }
    
    /// Print a detail row
    private static void printDetail(string label, string value, Color valueColor = Color.White) @system
    {
        terminal.write("  ");
        terminal.writeColored(format("%-14s", label ~ ":"), Color.BrightBlack);
        terminal.writeColored(value, valueColor);
        terminal.writeln();
    }
    
    /// Show explorer help
    static void showHelp() @system
    {
        init();
        
        terminal.writeln();
        terminal.writeColored("◈ BLDR Dependency Explorer\n", Color.Cyan, Style.Bold);
        terminal.writeln();
        
        terminal.writeln(formatter.section("Description"));
        terminal.writeln("  Interactive TUI for exploring the build dependency graph.");
        terminal.writeln("  Visualize dependencies, critical paths, and understand rebuilds.");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Usage"));
        terminal.writeln("  bldr explore [target] [options]");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Arguments"));
        terminal.writeln("  [target]          Focus on a specific target (optional)");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Options"));
        terminal.writeln("  --critical        Start with critical path view");
        terminal.writeln("  --non-interactive Output text (for scripting)");
        terminal.writeln("  --cache=<dir>     Cache directory (default: .builder-cache)");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Interactive Mode Keys"));
        terminal.writeln();
        terminal.writeColored("  Navigation:\n", Color.Yellow);
        terminal.writeln("    ↑/k, ↓/j        Move selection up/down");
        terminal.writeln("    ←/h, →/l        Collapse/expand node");
        terminal.writeln("    Enter           Select / toggle expand");
        terminal.writeln("    g / G           Jump to top / bottom");
        terminal.writeln();
        
        terminal.writeColored("  Views:\n", Color.Yellow);
        terminal.writeln("    1               Tree view (dependency hierarchy)");
        terminal.writeln("    2               Critical path (longest chain)");
        terminal.writeln("    3               Impact analysis (what rebuilds)");
        terminal.writeln("    4               Bottlenecks (blocking nodes)");
        terminal.writeln("    d               Node details panel");
        terminal.writeln("    /               Search targets");
        terminal.writeln();
        
        terminal.writeColored("  Actions:\n", Color.Yellow);
        terminal.writeln("    ?               Toggle help overlay");
        terminal.writeln("    r               Refresh graph data");
        terminal.writeln("    q / Esc         Quit explorer");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Examples"));
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr explore", Color.Green);
        terminal.writeln("                   Launch interactive explorer");
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr explore //src:app", Color.Green);
        terminal.writeln("       Focus on specific target");
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr explore --critical", Color.Green);
        terminal.writeln("        Start in critical path view");
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr explore --non-interactive", Color.Green);
        terminal.writeln(" Text output for scripts");
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("bldr explore //lib:utils --non-interactive", Color.Green);
        terminal.writeln();
        terminal.writeln("                                     Show target details in text");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Views Explained"));
        terminal.writeln();
        terminal.writeColored("  Tree View:\n", Color.Cyan);
        terminal.writeln("    Hierarchical view of all targets and their dependencies.");
        terminal.writeln("    Expand/collapse nodes to navigate the graph.");
        terminal.writeln();
        terminal.writeColored("  Critical Path:\n", Color.Cyan);
        terminal.writeln("    Shows the longest dependency chain. This determines minimum");
        terminal.writeln("    build time regardless of parallelism.");
        terminal.writeln();
        terminal.writeColored("  Impact Analysis:\n", Color.Cyan);
        terminal.writeln("    For the selected target, shows all targets that would need");
        terminal.writeln("    to rebuild if it changes. Useful for understanding change risk.");
        terminal.writeln();
        terminal.writeColored("  Bottleneck Detection:\n", Color.Cyan);
        terminal.writeln("    Identifies targets that block the most other builds.");
        terminal.writeln("    Focus optimization efforts here for maximum impact.");
        terminal.writeln();
        
        terminal.flush();
    }
}

// Helper functions
private string statusString(BuildStatus status) pure @safe
{
    final switch (status)
    {
        case BuildStatus.Pending: return "Pending";
        case BuildStatus.Building: return "Building";
        case BuildStatus.Success: return "Success";
        case BuildStatus.Failed: return "Failed";
        case BuildStatus.Cached: return "Cached";
    }
}

private Color statusColor(BuildStatus status) pure @safe
{
    final switch (status)
    {
        case BuildStatus.Pending: return Color.BrightBlack;
        case BuildStatus.Building: return Color.Cyan;
        case BuildStatus.Success: return Color.Green;
        case BuildStatus.Failed: return Color.Red;
        case BuildStatus.Cached: return Color.Yellow;
    }
}

private string formatDurationMs(long ms) pure @safe
{
    import std.format : format;
    if (ms < 1000) return format("%dms", ms);
    if (ms < 60_000) return format("%.1fs", ms / 1000.0);
    return format("%dm%ds", ms / 60_000, (ms % 60_000) / 1000);
}

private string truncate(string s, size_t maxLen) pure @safe
{
    return s.length <= maxLen ? s : s[0 .. maxLen - 3] ~ "...";
}

