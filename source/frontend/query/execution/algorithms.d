module frontend.query.execution.algorithms;

import std.algorithm;
import std.array;
import std.container : DList, RedBlackTree;
import std.range;
import std.string : toLower, lastIndexOf, indexOf;
import engine.graph;
import infrastructure.config.schema.schema;

/// Graph traversal algorithms library
/// 
/// Optimized implementations of standard graph algorithms
/// using D's compile-time features and efficient data structures

/// Result of a graph traversal
struct TraversalResult
{
    BuildNode[] nodes;
    size_t[][] paths;  // For path-finding algorithms
}

/// BFS queue item
private struct BfsItem
{
    BuildNode node;
    int depth;
}

/// Breadth-First Search with depth limit
/// 
/// Complexity: O(V + E) where depth is bounded
/// Memory: O(V) for visited set + O(W) for queue (W = width at current level)
BuildNode[] bfs(BuildGraph graph, BuildNode[] starts, int maxDepth = -1) @system
{
    if (starts.empty)
        return [];
    
    BuildNode[] result;
    bool[uint] visited;  // Index-based for O(1) lookup
    
    auto queue = DList!BfsItem();
    
    foreach (start; starts)
    {
        if (start is null)
            continue;
        queue.insertBack(BfsItem(start, 0));
        visited[start._nodeIndex] = true;
    }
    
    while (!queue.empty)
    {
        auto item = queue.front;
        queue.removeFront();
        
        auto node = item.node;
        auto depth = item.depth;
        
        result ~= node;
        
        if (maxDepth != -1 && depth >= maxDepth)
            continue;
        
        // Use indexed access for neighbors
        foreach (idx; node.dependencyIndices)
        {
            auto neighbor = graph.getNodeByIndex(idx);
            if (neighbor is null || neighbor._nodeIndex in visited)
                continue;
            
            visited[neighbor._nodeIndex] = true;
            queue.insertBack(BfsItem(neighbor, depth + 1));
        }
    }
    
    return result;
}

/// Depth-First Search with depth limit
/// 
/// Complexity: O(V + E)
/// Memory: O(V) for visited set + O(D) for recursion stack (D = max depth)
BuildNode[] dfs(BuildGraph graph, BuildNode[] starts, int maxDepth = -1) @system
{
    if (starts.empty)
        return [];
    
    BuildNode[] result;
    bool[uint] visited;  // Index-based for O(1) lookup
    
    void visit(BuildNode node, int depth) @system
    {
        if (node is null || node._nodeIndex in visited)
            return;
        
        visited[node._nodeIndex] = true;
        result ~= node;
        
        if (maxDepth != -1 && depth >= maxDepth)
            return;
        
        foreach (idx; node.dependencyIndices)
        {
            auto dep = graph.getNodeByIndex(idx);
            if (dep !is null)
                visit(dep, depth + 1);
        }
    }
    
    foreach (start; starts)
        visit(start, 0);
    
    return result;
}

/// Reverse BFS (following dependents instead of dependencies)
/// 
/// Finds all nodes that transitively depend on the given starts
BuildNode[] reverseBfs(BuildGraph graph, BuildNode[] starts, int maxDepth = -1) @system
{
    if (starts.empty)
        return [];
    
    BuildNode[] result;
    bool[uint] visited;  // Index-based for O(1) lookup
    auto queue = DList!BfsItem();
    
    foreach (start; starts)
    {
        if (start is null)
            continue;
        queue.insertBack(BfsItem(start, 0));
        visited[start._nodeIndex] = true;
    }
    
    while (!queue.empty)
    {
        auto item = queue.front;
        queue.removeFront();
        
        auto node = item.node;
        auto depth = item.depth;
        
        result ~= node;
        
        if (maxDepth != -1 && depth >= maxDepth)
            continue;
        
        // Explore dependents (reverse edges) using indexed access
        foreach (idx; node.dependentIndices)
        {
            auto neighbor = graph.getNodeByIndex(idx);
            if (neighbor is null || neighbor._nodeIndex in visited)
                continue;
            
            visited[neighbor._nodeIndex] = true;
            queue.insertBack(BfsItem(neighbor, depth + 1));
        }
    }
    
    return result;
}

/// Find shortest path using BFS (unweighted)
/// 
/// Returns: Array of nodes forming shortest path, or empty if no path exists
/// Complexity: O(V + E)
BuildNode[] shortestPath(BuildGraph graph, BuildNode from, BuildNode to) @system
{
    if (from is null || to is null)
        return [];
    
    if (from is to)
        return [from];
    
    // BFS with parent tracking using index-based maps
    uint[uint] parentIdx;  // nodeIndex → parentNodeIndex
    bool[uint] visited;
    auto queue = DList!BuildNode();
    
    queue.insertBack(from);
    visited[from._nodeIndex] = true;
    
    while (!queue.empty)
    {
        auto node = queue.front;
        queue.removeFront();
        
        if (node is to)
        {
            // Reconstruct path using indices
            BuildNode[] path;
            auto current = to;
            while (current !is null)
            {
                path = current ~ path;
                if (auto pIdx = current._nodeIndex in parentIdx)
                    current = graph.getNodeByIndex(*pIdx);
                else
                    current = null;
            }
            return path;
        }
        
        foreach (idx; node.dependencyIndices)
        {
            auto neighbor = graph.getNodeByIndex(idx);
            if (neighbor is null || neighbor._nodeIndex in visited)
                continue;
            
            visited[neighbor._nodeIndex] = true;
            parentIdx[neighbor._nodeIndex] = node._nodeIndex;
            queue.insertBack(neighbor);
        }
    }
    
    return [];  // No path found
}

/// Find all paths between two nodes using DFS
/// 
/// Returns: Array of all nodes that lie on any path from 'from' to 'to'
/// Complexity: O(V! * E) worst case (exponential in dense graphs)
/// Note: Use with caution on large graphs
BuildNode[] allPaths(BuildGraph graph, BuildNode from, BuildNode to) @system
{
    if (from is null || to is null)
        return [];
    
    BuildNode[] allNodesInPaths;
    bool[uint] globalVisited;  // Index-based
    BuildNode[] currentPath;
    bool[uint] pathVisited;    // Index-based
    
    void dfsAllPaths(BuildNode node) @system
    {
        if (node is null)
            return;
        
        pathVisited[node._nodeIndex] = true;
        currentPath ~= node;
        
        if (node is to)
        {
            // Found a path - mark all nodes in this path
            foreach (pathNode; currentPath)
            {
                if (pathNode._nodeIndex !in globalVisited)
                {
                    globalVisited[pathNode._nodeIndex] = true;
                    allNodesInPaths ~= pathNode;
                }
            }
        }
        else
        {
            // Continue searching using indexed access
            foreach (idx; node.dependencyIndices)
            {
                auto neighbor = graph.getNodeByIndex(idx);
                if (neighbor !is null && neighbor._nodeIndex !in pathVisited)
                    dfsAllPaths(neighbor);
            }
        }
        
        currentPath = currentPath[0 .. $ - 1];
        pathVisited.remove(node._nodeIndex);
    }
    
    dfsAllPaths(from);
    return allNodesInPaths;
}

/// Find any single path (faster than allPaths)
/// 
/// Returns: Nodes forming a single path, or empty if no path exists
/// Complexity: O(V + E)
BuildNode[] somePath(BuildGraph graph, BuildNode from, BuildNode to) @system
{
    if (from is null || to is null)
        return [];
    
    if (from is to)
        return [from];
    
    BuildNode[] path;
    bool[uint] visited;  // Index-based
    bool found = false;
    
    void dfs(BuildNode node) @system
    {
        if (found || node is null || node._nodeIndex in visited)
            return;
        
        visited[node._nodeIndex] = true;
        path ~= node;
        
        if (node is to)
        {
            found = true;
            return;
        }
        
        foreach (idx; node.dependencyIndices)
        {
            auto dep = graph.getNodeByIndex(idx);
            if (dep !is null)
            {
                dfs(dep);
                if (found)
                    return;
            }
        }
        
        if (!found)
            path = path[0 .. $ - 1];  // Backtrack
    }
    
    dfs(from);
    return found ? path : [];
}

/// Get all targets matching a pattern
/// 
/// Patterns:
/// - "//..." - all targets
/// - "//path/..." - all targets in path
/// - "//path:target" - specific target
/// - "//path:*" - all targets in directory
BuildNode[] matchPattern(BuildGraph graph, string pattern) @system
{
    BuildNode[] result;
    
    if (pattern == "//...")
    {
        // All targets - iterate _nodeArray for cache locality
        foreach (node; graph._nodeArray)
            if (node !is null)
                result ~= node;
    }
    else if (pattern.endsWith("..."))
    {
        // All targets in a path: //path/...
        string prefix = pattern[0 .. $ - 3];
        foreach (node; graph._nodeArray)
        {
            if (node !is null && node.idString.startsWith(prefix))
                result ~= node;
        }
    }
    else if (pattern.endsWith(":*"))
    {
        // All targets in a specific directory: //path:*
        string prefix = pattern[0 .. $ - 1];
        foreach (node; graph._nodeArray)
        {
            if (node !is null && node.idString.startsWith(prefix))
                result ~= node;
        }
    }
    else
    {
        // Specific target: //path:target - use indexed lookup
        auto node = graph.getNodeByKey(pattern);
        if (node !is null)
            result ~= node;
    }
    
    return result;
}

/// Filter nodes by target type
BuildNode[] filterByKind(BuildNode[] nodes, string kind) @system
{
    TargetType targetType;
    
    switch (kind.toLower())
    {
        case "executable":
        case "binary":
            targetType = TargetType.Executable;
            break;
        case "library":
        case "lib":
            targetType = TargetType.Library;
            break;
        case "test":
            targetType = TargetType.Test;
            break;
        case "custom":
            targetType = TargetType.Custom;
            break;
        default:
            return [];
    }
    
    return nodes.filter!(n => n !is null && n.target.type == targetType).array;
}

/// Filter nodes by attribute value
BuildNode[] filterByAttribute(BuildNode[] nodes, string attrName, string attrValue) @system
{
    return nodes.filter!(n => 
        n !is null && 
        attrName in n.target.langConfig && 
        n.target.langConfig[attrName] == attrValue
    ).array;
}

/// Filter nodes by regex on attribute
BuildNode[] filterByRegex(BuildNode[] nodes, string attrName, string regexPattern) @system
{
    import std.regex : regex, matchFirst;
    
    try
    {
        auto re = regex(regexPattern);
        return nodes.filter!(n => 
            n !is null && 
            attrName in n.target.langConfig && 
            !matchFirst(n.target.langConfig[attrName], re).empty
        ).array;
    }
    catch (Exception)
    {
        return [];  // Invalid regex returns empty set
    }
}

/// Get siblings (targets in same directory)
BuildNode[] getSiblings(BuildGraph graph, BuildNode[] targets) @system
{
    if (targets.empty)
        return [];
    
    bool[uint] result;  // Index-based
    BuildNode[] resultNodes;
    
    foreach (target; targets)
    {
        if (target is null)
            continue;
        
        // Extract directory from target ID (//path:target -> //path)
        string targetId = target.idString;
        auto colonPos = targetId.lastIndexOf(':');
        if (colonPos == -1)
            continue;
        
        string directory = targetId[0 .. colonPos];
        
        // Find all targets with same directory prefix using _nodeArray
        foreach (node; graph._nodeArray)
        {
            if (node !is null && node._nodeIndex !in result && node.idString.startsWith(directory ~ ":"))
            {
                result[node._nodeIndex] = true;
                resultNodes ~= node;
            }
        }
    }
    
    return resultNodes;
}

