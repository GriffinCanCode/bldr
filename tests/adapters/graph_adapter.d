module tests.adapters.graph_adapter;

/// Adapter to make property tests work with actual BuildGraph API
/// Maps simplified test API to real implementation

import std.algorithm;
import std.array;
import infrastructure.config.schema.schema;
import RealGraph = engine.graph.core.graph;
import infrastructure.errors;

/// Simplified graph interface for property tests
class TestGraph
{
    private RealGraph.BuildGraph graph;
    private RealGraph.BuildNode[string] nodeMap;
    
    this()
    {
        graph = new RealGraph.BuildGraph();
    }
    
    void addNode(TestNode node)
    {
        auto target = Target();
        target.name = node.name;
        target.type = TargetType.Executable; // Was TargetKind.Binary
        
        auto result = graph.addTarget(target);
        if (result.isOk)
        {
            auto targetId = TargetId(node.name);
            auto graphNodePtr = graph.getNode(targetId);
            if (graphNodePtr !is null)
                nodeMap[node.name] = *graphNodePtr;
        }
    }
    
    bool addEdge(TestNode from, TestNode to)
    {
        auto fromNode = nodeMap.get(from.name, null);
        auto toNode = nodeMap.get(to.name, null);
        
        if (fromNode is null || toNode is null)
            return false;
        
        // Check if edge would create cycle
        if (wouldCreateCycle(fromNode, toNode))
            return false;
        
        auto result = graph.addDependency(from.name, to.name);
        return result.isOk;
    }
    
    bool hasCycle()
    {
        auto result = graph.topologicalSort();
        return result.isErr;
    }
    
    bool wouldCreateCycle(TestNode from, TestNode to)
    {
        auto fromNode = nodeMap.get(from.name, null);
        auto toNode = nodeMap.get(to.name, null);
        
        if (fromNode is null || toNode is null)
            return false;
            
        return wouldCreateCycle(fromNode, toNode);
    }

    bool wouldCreateCycle(RealGraph.BuildNode from, RealGraph.BuildNode to)
    {
        // DFS to check if adding edge from->to creates cycle
        // A cycle exists if there's already a path from to->from
        return hasPath(to, from);
    }
    
    private bool hasPath(RealGraph.BuildNode from, RealGraph.BuildNode to)
    {
        bool[RealGraph.BuildNode] visited;
        return dfsHasPath(from, to, visited);
    }
    
    private bool dfsHasPath(RealGraph.BuildNode current, RealGraph.BuildNode target, ref bool[RealGraph.BuildNode] visited)
    {
        if (current is target)
            return true;
        
        if (current in visited)
            return false;
        
        visited[current] = true;
        
        foreach (depId; current.dependencyIds)
        {
            // Need to resolve ID to node
            auto depPtr = graph.getNode(depId);
            if (depPtr !is null)
            {
                auto dep = *depPtr;
                if (dfsHasPath(dep, target, visited))
                    return true;
            }
        }
        
        return false;
    }
    
    TestNode[] topologicalSort()
    {
        auto result = graph.topologicalSort();
        if (result.isErr)
            return [];
        
        auto sorted = result.unwrap();
        TestNode[] testNodes;
        
        foreach (node; sorted)
        {
            testNodes ~= new TestNode(node.target.name);
        }
        
        return testNodes;
    }
    
    void removeNode(TestNode node)
    {
        if (node.name in graph.nodes)
            graph.nodes.remove(node.name);
        nodeMap.remove(node.name);
    }
    
    TestNode[] getAllDependencies(TestNode node)
    {
        auto graphNode = nodeMap.get(node.name, null);
        if (graphNode is null)
            return [];
        
        TestNode[] deps;
        bool[string] visited;
        collectAllDeps(graphNode, deps, visited);
        return deps;
    }
    
    private void collectAllDeps(RealGraph.BuildNode node, ref TestNode[] deps, ref bool[string] visited)
    {
        if (node.target.name in visited)
            return;
        
        visited[node.target.name] = true;
        
        foreach (depId; node.dependencyIds)
        {
            auto depPtr = graph.getNode(depId);
            if (depPtr !is null)
            {
                auto dep = *depPtr;
                deps ~= new TestNode(dep.target.name);
                collectAllDeps(dep, deps, visited);
            }
        }
    }
    
    @property TestNode[] nodes()
    {
        TestNode[] result;
        foreach (node; nodeMap.values)
        {
            result ~= new TestNode(node.target.name);
        }
        return result;
    }
}

/// Simplified node for property tests
class TestNode
{
    string name;
    TestNode[] dependencies;
    
    this(string name)
    {
        this.name = name;
    }
    
    override bool opEquals(Object other) const
    {
        if (auto otherNode = cast(TestNode)other)
            return name == otherNode.name;
        return false;
    }
    
    override size_t toHash() const nothrow @safe
    {
        return typeid(string).getHash(&name);
    }
}

// Aliases for cleaner test code
alias BuildGraph = TestGraph;
alias BuildNode = TestNode;
