module frontend.lsp.providers.graph;

import std.algorithm : map, filter, sort, min, max;
import std.array : array, appender;
import std.string : startsWith;
import std.path : buildPath, dirName;
import std.conv : to;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import engine.graph.persistence.index;
import infrastructure.utils.logging.logger;

/// LSP commands for build graph navigation
enum GraphCommand : string
{
    GoToDependency = "builder.goToDependency",
    FindReverseDependencies = "builder.findReverseDependencies",
    ShowDependencyTree = "builder.showDependencyTree",
    ShowImpactAnalysis = "builder.showImpactAnalysis"
}

/// Result of dependency navigation
struct DependencyInfo
{
    string targetName;
    string targetType;
    Location location;
    int depth;  // 0 = direct, 1+ = transitive
}

/// Graph provider for build dependency navigation
/// Leverages GraphIndex for efficient dependency queries
struct GraphProvider
{
    private WorkspaceManager workspace;
    private GraphIndex graphIndex;
    private bool graphAvailable;

    this(WorkspaceManager workspace, string cacheDir = ".builder-cache")
    {
        this.workspace = workspace;
        
        // Try to initialize graph index
        try
        {
            this.graphIndex = new GraphIndex(cacheDir);
            this.graphAvailable = true;
            Logger.info("Graph provider initialized with cache: " ~ cacheDir);
        }
        catch (Exception e)
        {
            this.graphAvailable = false;
            Logger.warning("Graph index unavailable: " ~ e.msg);
        }
    }

    /// Check if graph data is available
    @property bool hasGraph() const => graphAvailable;

    /// Execute a graph command
    /// Returns JSON result for workspace/executeCommand response
    import std.json : JSONValue;
    JSONValue executeCommand(GraphCommand cmd, JSONValue args)
    {
        final switch (cmd)
        {
            case GraphCommand.GoToDependency:
                return goToDependency(args);
            case GraphCommand.FindReverseDependencies:
                return findReverseDependencies(args);
            case GraphCommand.ShowDependencyTree:
                return showDependencyTree(args);
            case GraphCommand.ShowImpactAnalysis:
                return showImpactAnalysis(args);
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Go to Dependency - Navigate to a target's dependencies
    // ─────────────────────────────────────────────────────────────────

    /// Get dependencies for target at position
    DependencyInfo[] getDependencies(string uri, Position pos, bool transitive = false)
    {
        auto targetName = resolveTargetAtPosition(uri, pos);
        if (targetName.length == 0)
            return [];

        return getDependenciesForTarget(targetName, transitive);
    }

    /// Get dependencies by target name
    DependencyInfo[] getDependenciesForTarget(string targetName, bool transitive = false)
    {
        DependencyInfo[] results;

        // First check workspace index for AST-level deps
        auto sym = workspace.getIndex.getSymbol(targetName);
        if (sym !is null)
        {
            foreach (dep; sym.deps)
            {
                auto depName = normalizeDependencyName(dep);
                auto depInfo = createDependencyInfo(depName, 0);
                if (depInfo.location.uri.length > 0)
                    results ~= depInfo;
            }
        }

        // Augment with graph index if available
        if (graphAvailable && transitive)
        {
            auto graphDeps = graphIndex.getTransitiveDeps(targetName);
            foreach (dep; graphDeps)
            {
                // Skip already-added direct deps
                if (!results.map!(r => r.targetName).filter!(n => n == dep).empty)
                    continue;

                auto depInfo = createDependencyInfo(dep, 1);
                if (depInfo.location.uri.length > 0)
                    results ~= depInfo;
            }
        }

        return results;
    }

    /// Provide locations for "Go to Dependency" command
    Location[] provideDependencyLocations(string uri, Position pos)
    {
        auto deps = getDependencies(uri, pos, false);
        return deps.map!(d => d.location).array;
    }

    // ─────────────────────────────────────────────────────────────────
    // Find Reverse Dependencies - Find what depends on a target
    // ─────────────────────────────────────────────────────────────────

    /// Get reverse dependencies (dependents) for target at position
    DependencyInfo[] getReverseDependencies(string uri, Position pos, bool transitive = false)
    {
        auto targetName = resolveTargetAtPosition(uri, pos);
        if (targetName.length == 0)
            return [];

        return getReverseDependenciesForTarget(targetName, transitive);
    }

    /// Get reverse dependencies by target name
    DependencyInfo[] getReverseDependenciesForTarget(string targetName, bool transitive = false)
    {
        DependencyInfo[] results;

        // Check workspace index - find all targets that depend on this
        foreach (name; workspace.getAllTargetNames())
        {
            auto sym = workspace.getIndex.getSymbol(name);
            if (sym is null) continue;

            foreach (dep; sym.deps)
            {
                if (normalizeDependencyName(dep) == targetName)
                {
                    auto depInfo = createDependencyInfo(name, 0);
                    if (depInfo.location.uri.length > 0)
                        results ~= depInfo;
                    break;
                }
            }
        }

        // Augment with graph index for transitive dependents
        if (graphAvailable && transitive)
        {
            auto dependents = graphIndex.getTransitiveDependents(targetName);
            foreach (dep; dependents)
            {
                if (!results.map!(r => r.targetName).filter!(n => n == dep).empty)
                    continue;

                auto depInfo = createDependencyInfo(dep, 1);
                if (depInfo.location.uri.length > 0)
                    results ~= depInfo;
            }
        }

        return results;
    }

    /// Provide locations for "Find Reverse Dependencies" command
    Location[] provideReverseDependencyLocations(string uri, Position pos)
    {
        auto deps = getReverseDependencies(uri, pos, false);
        return deps.map!(d => d.location).array;
    }

    // ─────────────────────────────────────────────────────────────────
    // Command Handlers - Return JSONValue for LSP responses
    // ─────────────────────────────────────────────────────────────────

    private JSONValue goToDependency(JSONValue args)
    {
        auto uri = extractUri(args);
        auto pos = extractPosition(args);
        auto transitive = extractBool(args, "transitive", false);

        auto deps = getDependencies(uri, pos, transitive);
        return depsToJSON(deps);
    }

    private JSONValue findReverseDependencies(JSONValue args)
    {
        auto uri = extractUri(args);
        auto pos = extractPosition(args);
        auto transitive = extractBool(args, "transitive", false);

        auto deps = getReverseDependencies(uri, pos, transitive);
        return depsToJSON(deps);
    }

    private JSONValue showDependencyTree(JSONValue args)
    {
        if (!graphAvailable)
            return JSONValue(["error": "Graph index not available"]);

        auto targetName = extractTargetName(args);
        if (targetName.length == 0)
            return JSONValue(["error": "No target specified"]);

        // Build tree structure
        JSONValue tree;
        tree["target"] = targetName;
        tree["dependencies"] = buildTreeNode(targetName, true, 0, 5);
        return tree;
    }

    private JSONValue showImpactAnalysis(JSONValue args)
    {
        if (!graphAvailable)
            return JSONValue(["error": "Graph index not available"]);

        auto targetName = extractTargetName(args);
        if (targetName.length == 0)
            return JSONValue(["error": "No target specified"]);

        // Use enhanced impact analysis
        auto impact = computeImpactAnalysis(targetName);
        return impact.toJSON();
    }

    // ─────────────────────────────────────────────────────────────────
    // Enhanced Impact Analysis
    // ─────────────────────────────────────────────────────────────────

    /// Compute full impact analysis for a target
    ImpactAnalysis computeImpactAnalysis(string targetName)
    {
        ImpactAnalysis impact;
        impact.targetName = targetName;

        // Get direct dependents from workspace
        auto directDeps = workspace.getDeclaredDependents(targetName);
        impact.directCount = directDeps.length;
        impact.directImpacts = directDeps.length <= 10 
            ? directDeps 
            : directDeps[0..10];  // Truncate for display

        // Get transitive dependents if graph available
        if (graphAvailable)
        {
            auto transitiveDeps = graphIndex.getTransitiveDependents(targetName);
            impact.transitiveCount = transitiveDeps.length;
            
            // Compute critical path
            impact.criticalPath = computeCriticalImpactPath(targetName, transitiveDeps);
            
            // Estimate rebuild time
            impact.estimatedRebuildTime = estimateRebuildTime(targetName, transitiveDeps);
        }
        else
        {
            impact.transitiveCount = impact.directCount;
        }

        // Determine severity
        impact.severity = computeSeverity(impact.transitiveCount);

        return impact;
    }

    /// Build a dependency tree structure for visualization
    DependencyNode buildDependencyTree(string targetName, bool reverse = false, int maxDepth = 5)
    {
        return buildTreeNodeRecursive(targetName, reverse, 0, maxDepth, null);
    }

    private DependencyNode buildTreeNodeRecursive(string name, bool reverse, int depth, int maxDepth, bool[string] visited)
    {
        if (visited is null)
            visited = new bool[string];
        
        DependencyNode node;
        node.name = name;
        node.depth = depth;

        // Get type from workspace or graph
        auto sym = workspace.getIndex.getSymbol(name);
        if (sym !is null)
            node.nodeType = sym.detail;
        else if (graphAvailable)
        {
            auto nodeResult = graphIndex.getNode(name);
            if (nodeResult.isOk)
                node.nodeType = nodeResult.unwrap().targetType;
        }

        // Check depth limit and cycles
        if (depth >= maxDepth || name in visited)
        {
            node.isLeaf = true;
            return node;
        }
        visited[name] = true;

        // Get children (deps or dependents)
        string[] children;
        if (reverse)
        {
            children = graphAvailable 
                ? graphIndex.getDependents(name)
                : workspace.getDeclaredDependents(name);
        }
        else
        {
            children = graphAvailable
                ? graphIndex.getDependencies(name)
                : workspace.getDeclaredDependencies(name);
        }

        node.isLeaf = children.length == 0;

        // Build child nodes
        foreach (child; children)
        {
            node.children ~= buildTreeNodeRecursive(child, reverse, depth + 1, maxDepth, visited);
        }

        return node;
    }

    private ImpactSeverity computeSeverity(size_t impactCount) pure @safe
    {
        if (impactCount < 5) return ImpactSeverity.Low;
        if (impactCount < 20) return ImpactSeverity.Medium;
        if (impactCount < 50) return ImpactSeverity.High;
        return ImpactSeverity.Critical;
    }

    private string[] computeCriticalImpactPath(string targetName, string[] impacted)
    {
        if (!graphAvailable || impacted.length == 0)
            return [];

        // Find the impacted node with the longest path from target
        int maxDepth = 0;
        string deepestNode;
        
        foreach (name; impacted)
        {
            auto nodeResult = graphIndex.getNode(name);
            if (nodeResult.isOk)
            {
                auto depth = nodeResult.unwrap().depth;
                if (depth > maxDepth)
                {
                    maxDepth = depth;
                    deepestNode = name;
                }
            }
        }

        if (deepestNode.length == 0)
            return [];

        // Trace path from target to deepest impacted
        return tracePath(targetName, deepestNode);
    }

    private string[] tracePath(string from, string to)
    {
        // BFS to find shortest path
        string[][string] pathTo;
        pathTo[from] = [from];
        
        string[] queue = [from];
        size_t idx = 0;
        
        while (idx < queue.length)
        {
            auto current = queue[idx++];
            if (current == to)
                return pathTo[to];
            
            auto dependents = graphIndex.getDependents(current);
            foreach (dep; dependents)
            {
                if (dep !in pathTo)
                {
                    pathTo[dep] = pathTo[current] ~ dep;
                    queue ~= dep;
                }
            }
        }
        
        return pathTo.get(to, []);
    }

    private long estimateRebuildTime(string targetName, string[] impacted)
    {
        if (!graphAvailable)
            return 0;

        long totalTime = 0;
        
        // Include target build time
        auto targetResult = graphIndex.getNode(targetName);
        if (targetResult.isOk)
            totalTime += targetResult.unwrap().buildDuration;
        
        // Sum up impacted build times
        foreach (name; impacted)
        {
            auto nodeResult = graphIndex.getNode(name);
            if (nodeResult.isOk)
            {
                auto duration = nodeResult.unwrap().buildDuration;
                // Use average if no recorded duration
                totalTime += duration > 0 ? duration : 500;
            }
        }
        
        return totalTime;
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    private string resolveTargetAtPosition(string uri, Position pos)
    {
        auto doc = workspace.getDocument(uri);
        if (doc is null) return "";

        auto target = workspace.findTargetAtPosition(uri, pos);
        return target !is null ? target.name : "";
    }

    private string normalizeDependencyName(string dep)
    {
        if (dep.startsWith(":"))
            return dep[1 .. $];
        
        if (dep.startsWith("//"))
        {
            import std.string : lastIndexOf;
            auto colonPos = dep.lastIndexOf(':');
            if (colonPos != -1)
                return dep[colonPos + 1 .. $];
        }
        return dep;
    }

    private DependencyInfo createDependencyInfo(string name, int depth)
    {
        DependencyInfo info;
        info.targetName = name;
        info.depth = depth;

        // Get location from workspace index
        auto loc = workspace.findDefinition(name);
        if (loc !is null)
            info.location = *loc;

        // Get type from workspace or graph
        auto sym = workspace.getIndex.getSymbol(name);
        if (sym !is null)
            info.targetType = sym.detail;
        else if (graphAvailable)
        {
            auto nodeResult = graphIndex.getNode(name);
            if (nodeResult.isOk)
                info.targetType = nodeResult.unwrap().targetType;
        }

        return info;
    }

    private JSONValue depsToJSON(DependencyInfo[] deps)
    {
        JSONValue[] items;
        foreach (d; deps)
        {
            JSONValue item;
            item["targetName"] = d.targetName;
            item["targetType"] = d.targetType;
            item["depth"] = d.depth;
            item["location"] = d.location.toJSON();
            items ~= item;
        }
        return JSONValue(items);
    }

    private JSONValue buildTreeNode(string name, bool isDeps, int depth, int maxDepth)
    {
        if (depth >= maxDepth)
            return JSONValue(["truncated": true]);

        string[] children;
        if (isDeps)
            children = graphIndex.getDependencies(name);
        else
            children = graphIndex.getDependents(name);

        JSONValue[] nodes;
        foreach (child; children)
        {
            JSONValue node;
            node["name"] = child;
            
            auto nodeResult = graphIndex.getNode(child);
            if (nodeResult.isOk)
                node["type"] = nodeResult.unwrap().targetType;
            
            node["children"] = buildTreeNode(child, isDeps, depth + 1, maxDepth);
            nodes ~= node;
        }

        return JSONValue(nodes);
    }

    // JSON extraction helpers
    private string extractUri(JSONValue args)
    {
        if ("uri" in args) return args["uri"].str;
        if ("textDocument" in args && "uri" in args["textDocument"])
            return args["textDocument"]["uri"].str;
        return "";
    }

    private Position extractPosition(JSONValue args)
    {
        if ("position" in args)
            return Position.fromJSON(args["position"]);
        return Position(0, 0);
    }

    private string extractTargetName(JSONValue args)
    {
        if ("target" in args) return args["target"].str;
        if ("targetName" in args) return args["targetName"].str;
        
        // Try to resolve from position
        auto uri = extractUri(args);
        auto pos = extractPosition(args);
        if (uri.length > 0)
            return resolveTargetAtPosition(uri, pos);
        
        return "";
    }

    private bool extractBool(JSONValue args, string key, bool defaultVal)
    {
        import std.json : JSONType;
        if (key in args && args[key].type == JSONType.true_)
            return true;
        if (key in args && args[key].type == JSONType.false_)
            return false;
        return defaultVal;
    }
}

/// Get list of supported graph commands
GraphCommand[] getSupportedCommands() pure nothrow @safe
{
    return [
        GraphCommand.GoToDependency,
        GraphCommand.FindReverseDependencies,
        GraphCommand.ShowDependencyTree,
        GraphCommand.ShowImpactAnalysis
    ];
}

