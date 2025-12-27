module frontend.lsp.providers.codelens;

import std.algorithm : map, filter, sort, uniq;
import std.array : array, appender, Appender;
import std.conv : to;
import std.json : JSONValue, JSONType;
import std.string : format;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import frontend.lsp.providers.graph;
import infrastructure.utils.logging;

/// CodeLens provider for inline dependency visualization
/// Shows dependency counts and impact analysis above each target
struct CodeLensProvider
{
    private WorkspaceManager workspace;
    private GraphProvider* graphProvider;

    this(WorkspaceManager workspace, GraphProvider* graphProvider)
    {
        this.workspace = workspace;
        this.graphProvider = graphProvider;
    }

    /// Provide CodeLens items for a document
    CodeLens[] provideCodeLenses(string uri)
    {
        auto doc = workspace.getDocument(uri);
        if (doc is null)
            return [];

        CodeLens[] lenses;

        foreach (ref target; doc.ast.targets)
        {
            auto targetLine = cast(uint)(target.loc.line - 1);
            auto targetRange = Range(
                Position(targetLine, 0),
                Position(targetLine, cast(uint)target.name.length)
            );

            // Dependency count lens
            lenses ~= buildDependencyLens(target.name, uri, targetRange);

            // Reverse dependency (dependents) lens
            lenses ~= buildDependentsLens(target.name, uri, targetRange);

            // Impact analysis lens (if graph available)
            if (graphProvider !is null && graphProvider.hasGraph)
                lenses ~= buildImpactLens(target.name, uri, targetRange);
        }

        return lenses;
    }

    /// Resolve CodeLens with full command details
    CodeLens resolveCodeLens(CodeLens lens)
    {
        // Lens is already fully resolved in provideCodeLenses
        return lens;
    }

private:
    CodeLens buildDependencyLens(string targetName, string uri, Range range)
    {
        auto deps = workspace.getDeclaredDependencies(targetName);
        auto count = deps.length;
        
        // Get transitive count if graph available
        size_t transitiveCount = count;
        if (graphProvider !is null && graphProvider.hasGraph)
        {
            auto transitiveDeps = graphProvider.getDependenciesForTarget(targetName, true);
            transitiveCount = transitiveDeps.length;
        }

        CodeLens lens;
        lens.range = range;
        
        // Build title
        string title = count == 0 
            ? "⚪ no dependencies"
            : format("⬇ %d %s", count, count == 1 ? "dependency" : "dependencies");
        
        if (transitiveCount > count)
            title ~= format(" (%d transitive)", transitiveCount);

        // Build command
        lens.command.title = title;
        lens.command.command = "builder.showDependencyGraph";
        
        JSONValue args;
        args["uri"] = uri;
        args["targetName"] = targetName;
        args["mode"] = "dependencies";
        lens.command.arguments = JSONValue([args]);
        
        return lens;
    }

    CodeLens buildDependentsLens(string targetName, string uri, Range range)
    {
        auto dependents = workspace.getDeclaredDependents(targetName);
        auto count = dependents.length;
        
        // Get transitive dependents if graph available
        size_t transitiveCount = count;
        if (graphProvider !is null && graphProvider.hasGraph)
        {
            auto transitiveDeps = graphProvider.getReverseDependenciesForTarget(targetName, true);
            transitiveCount = transitiveDeps.length;
        }

        CodeLens lens;
        lens.range = range;
        
        // Build title with color coding based on impact
        string icon = count == 0 ? "⚪" : (count < 5 ? "🟢" : (count < 20 ? "🟡" : "🔴"));
        string title = count == 0 
            ? "⚪ no dependents"
            : format("%s %d %s", icon, count, count == 1 ? "dependent" : "dependents");
        
        if (transitiveCount > count)
            title ~= format(" (%d transitive)", transitiveCount);

        lens.command.title = title;
        lens.command.command = "builder.findReverseDependencies";
        
        JSONValue args;
        args["uri"] = uri;
        args["targetName"] = targetName;
        args["transitive"] = true;
        lens.command.arguments = JSONValue([args]);
        
        return lens;
    }

    CodeLens buildImpactLens(string targetName, string uri, Range range)
    {
        // Get impact analysis from graph provider
        auto impact = graphProvider.computeImpactAnalysis(targetName);
        
        CodeLens lens;
        lens.range = range;
        
        // Build title with severity indicator
        string severityIcon;
        final switch (impact.severity) {
            case ImpactSeverity.Low: severityIcon = "🟢"; break;
            case ImpactSeverity.Medium: severityIcon = "🟡"; break;
            case ImpactSeverity.High: severityIcon = "🟠"; break;
            case ImpactSeverity.Critical: severityIcon = "🔴"; break;
        }
        
        string title = format("%s Impact: %s", severityIcon, impact.severityLabel);
        if (impact.estimatedRebuildTime > 0)
            title ~= format(" (~%s rebuild)", formatDuration(impact.estimatedRebuildTime));

        lens.command.title = title;
        lens.command.command = "builder.showImpactAnalysis";
        
        JSONValue args;
        args["targetName"] = targetName;
        args["uri"] = uri;
        lens.command.arguments = JSONValue([args]);
        
        // Store full impact data for rich display
        lens.data = impact.toJSON();
        
        return lens;
    }

    static string formatDuration(long ms) pure @safe
    {
        if (ms < 1000) return ms.to!string ~ "ms";
        if (ms < 60_000) return (ms / 1000).to!string ~ "s";
        return (ms / 60_000).to!string ~ "m " ~ ((ms % 60_000) / 1000).to!string ~ "s";
    }
}

/// Extended CodeLens features for dependency graph visualization
struct DependencyGraphLens
{
    /// Generate ASCII art dependency tree for display
    static string renderDependencyTree(DependencyNode root, int maxDepth = 5)
    {
        auto result = appender!string;
        renderNode(result, root, "", true, 0, maxDepth);
        return result.data;
    }

private:
    static void renderNode(ref Appender!string output, ref const DependencyNode node, 
                          string prefix, bool isLast, int depth, int maxDepth)
    {
        if (depth >= maxDepth)
        {
            output.put(prefix);
            output.put(isLast ? "└── " : "├── ");
            output.put("... (truncated)\n");
            return;
        }

        output.put(prefix);
        output.put(isLast ? "└── " : "├── ");
        output.put(node.name);
        if (node.nodeType.length > 0)
            output.put(format(" [%s]", node.nodeType));
        output.put("\n");

        auto newPrefix = prefix ~ (isLast ? "    " : "│   ");
        
        foreach (i, ref child; node.children)
        {
            bool childIsLast = (i == node.children.length - 1);
            renderNode(output, child, newPrefix, childIsLast, depth + 1, maxDepth);
        }
    }
}

