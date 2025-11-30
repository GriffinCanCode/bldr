module tests.unit.properties.graph_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import tests.harness;
import tests.property;
import tests.adapters.graph_adapter;

version(unittest):

/// Test that build graphs maintain acyclicity through all operations
@("property.graph.acyclicity.add_node")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph acyclicity - add_node");
    
    auto config = PropertyConfig(numTests: 50);
    auto test = property!string(config);
    
    static bool acyclicAfterAddNode(string nodeName)
    {
        auto graph = new BuildGraph();
        
        // Add some initial nodes
        auto node1 = new BuildNode("base1");
        auto node2 = new BuildNode("base2");
        graph.addNode(node1);
        graph.addNode(node2);
        
        // Add new node
        auto newNode = new BuildNode(nodeName.length > 0 ? nodeName : "node");
        graph.addNode(newNode);
        
        // Graph should still be acyclic
        return !graph.hasCycle();
    }
    
    auto result = test.forAll!acyclicAfterAddNode(new StringGen(1, 20));
    checkProperty(result, "graph.acyclicity.add_node");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that adding edges maintains acyclicity or fails appropriately
@("property.graph.acyclicity.add_edge")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph acyclicity - add_edge");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool noCyclesIntroduced(int[][] adjacency)
    {
        // Skip empty graphs
        if (adjacency.length == 0) return true;
        
        auto graph = new BuildGraph();
        BuildNode[] nodes;
        
        // Create nodes
        foreach (i; 0 .. adjacency.length)
        {
            auto node = new BuildNode("node" ~ i.to!string);
            nodes ~= node;
            graph.addNode(node);
        }
        
        // Try to add edges from adjacency list
        foreach (i, edges; adjacency)
        {
            foreach (j; edges)
            {
                if (j >= 0 && j < nodes.length && i != j)
                {
                    // Only add edge if it doesn't create a cycle
                    if (!graph.wouldCreateCycle(nodes[i], nodes[j]))
                    {
                        graph.addEdge(nodes[i], nodes[j]);
                    }
                }
            }
        }
        
        // Graph should never have cycles
        return !graph.hasCycle();
    }
    
    auto test = property!(int[][])(config);
    auto result = test.forAll!noCyclesIntroduced(new GraphGen(2, 10, 0.3));
    checkProperty(result, "graph.acyclicity.add_edge");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test topological sort always produces valid ordering for acyclic graphs
@("property.graph.topological_sort.valid_ordering")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph topological sort validity");
    
    auto config = PropertyConfig(numTests: 30);
    
    static bool topologicalSortValid(int[][] adjacency)
    {
        // Skip empty graphs
        if (adjacency.length < 2) return true;
        
        auto graph = new BuildGraph();
        BuildNode[] nodes;
        
        // Create nodes
        foreach (i; 0 .. adjacency.length)
        {
            auto node = new BuildNode("node" ~ i.to!string);
            nodes ~= node;
            graph.addNode(node);
        }
        
        // Add edges (only if no cycle)
        foreach (i, edges; adjacency)
        {
            foreach (j; edges)
            {
                if (j >= 0 && j < nodes.length && i != j)
                {
                    if (!graph.wouldCreateCycle(nodes[i], nodes[j]))
                    {
                        graph.addEdge(nodes[i], nodes[j]);
                    }
                }
            }
        }
        
        // Get topological sort
        auto sorted = graph.topologicalSort();
        
        // Verify ordering: for every edge (u, v), u appears before v
        size_t[BuildNode] positions;
        foreach (idx, node; sorted)
        {
            positions[node] = idx;
        }
        
        foreach (node; sorted)
        {
            foreach (dep; node.dependencies)
            {
                // dependency must come before node in sorted order
                if (positions[dep] >= positions[node])
                {
                    return false;
                }
            }
        }
        
        return true;
    }
    
    auto test = property!(int[][])(config);
    auto result = test.forAll!topologicalSortValid(new GraphGen(2, 8, 0.25));
    checkProperty(result, "graph.topological_sort.valid_ordering");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that removing nodes maintains acyclicity
@("property.graph.acyclicity.remove_node")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph acyclicity - remove_node");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool acyclicAfterRemove(int[][] adjacency)
    {
        // Need at least 2 nodes
        if (adjacency.length < 2) return true;
        
        auto graph = new BuildGraph();
        BuildNode[] nodes;
        
        // Create nodes
        foreach (i; 0 .. adjacency.length)
        {
            auto node = new BuildNode("node" ~ i.to!string);
            nodes ~= node;
            graph.addNode(node);
        }
        
        // Add edges (only if no cycle)
        foreach (i, edges; adjacency)
        {
            foreach (j; edges)
            {
                if (j >= 0 && j < nodes.length && i != j)
                {
                    if (!graph.wouldCreateCycle(nodes[i], nodes[j]))
                    {
                        graph.addEdge(nodes[i], nodes[j]);
                    }
                }
            }
        }
        
        // Remove a random node
        if (nodes.length > 0)
        {
            graph.removeNode(nodes[$ - 1]);
        }
        
        // Graph should still be acyclic
        return !graph.hasCycle();
    }
    
    auto test = property!(int[][])(config);
    auto result = test.forAll!acyclicAfterRemove(new GraphGen(2, 10, 0.3));
    checkProperty(result, "graph.acyclicity.remove_node");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that graph operations are idempotent
@("property.graph.idempotence.add_node")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph add_node idempotence");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool addNodeIdempotent(string nodeName)
    {
        if (nodeName.length == 0) nodeName = "node";
        
        auto graph1 = new BuildGraph();
        auto graph2 = new BuildGraph();
        
        auto node1 = new BuildNode(nodeName);
        auto node2 = new BuildNode(nodeName);
        
        // Add once
        graph1.addNode(node1);
        
        // Add twice
        graph2.addNode(node2);
        graph2.addNode(node2);  // Second add should be no-op or handled gracefully
        
        // Both graphs should have same number of nodes
        return graph1.nodes.length == graph2.nodes.length;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!addNodeIdempotent(new StringGen(1, 20));
    checkProperty(result, "graph.idempotence.add_node");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test transitive dependency closure correctness
@("property.graph.transitive_closure")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build graph transitive closure");
    
    auto config = PropertyConfig(numTests: 30);
    
    static bool transitiveClosureValid(int[][] adjacency)
    {
        // Need at least 3 nodes for interesting transitivity
        if (adjacency.length < 3) return true;
        
        auto graph = new BuildGraph();
        BuildNode[] nodes;
        
        // Create nodes
        foreach (i; 0 .. adjacency.length)
        {
            auto node = new BuildNode("node" ~ i.to!string);
            nodes ~= node;
            graph.addNode(node);
        }
        
        // Add edges
        foreach (i, edges; adjacency)
        {
            foreach (j; edges)
            {
                if (j >= 0 && j < nodes.length && i != j)
                {
                    if (!graph.wouldCreateCycle(nodes[i], nodes[j]))
                    {
                        graph.addEdge(nodes[i], nodes[j]);
                    }
                }
            }
        }
        
        // Check transitive property: if A depends on B and B depends on C, 
        // then A transitively depends on C
        foreach (node; nodes)
        {
            auto allDeps = graph.getAllDependencies(node);
            
            foreach (directDep; node.dependencies)
            {
                auto transitiveDeps = graph.getAllDependencies(directDep);
                
                // All transitive dependencies of direct dependencies
                // should also be dependencies of the node
                foreach (transDep; transitiveDeps)
                {
                    if (!allDeps.canFind(transDep))
                        return false;
                }
            }
        }
        
        return true;
    }
    
    auto test = property!(int[][])(config);
    auto result = test.forAll!transitiveClosureValid(new GraphGen(3, 8, 0.2));
    checkProperty(result, "graph.transitive_closure");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

