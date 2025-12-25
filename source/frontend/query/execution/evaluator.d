module frontend.query.execution.evaluator;

import std.algorithm;
import std.array;
import std.file : exists, isFile, dirEntries, SpanMode;
import std.path : dirName, baseName;
import std.string : indexOf, startsWith;
import frontend.query.parsing.ast;
import frontend.query.execution.algorithms;
import frontend.query.execution.operators;
import engine.graph;
import infrastructure.errors;

/// Query evaluator - executes AST against build graph
/// 
/// Uses visitor pattern to traverse AST and accumulate results
final class QueryEvaluator : QueryVisitor
{
    private BuildGraph graph;
    private BuildNode[] currentResult;
    private BuildNode[][string] variables;  // For let expressions
    
    this(BuildGraph graph) pure nothrow @safe
    {
        this.graph = graph;
    }
    
    /// Evaluate query expression
    Result!(BuildNode[], string) evaluate(QueryExpr expr) @system
    {
        try
        {
            currentResult = [];
            expr.accept(this);
            return Result!(BuildNode[], string).ok(currentResult);
        }
        catch (Exception e)
        {
            return Result!(BuildNode[], string).err(e.msg);
        }
    }
    
    /// Visit target pattern
    override void visit(TargetPattern node) @system
    {
        // Check if it's a variable reference
        if (node.pattern in variables)
        {
            currentResult = variables[node.pattern];
            return;
        }
        
        currentResult = matchPattern(graph, node.pattern);
    }
    
    /// Visit deps expression
    override void visit(DepsExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Get dependencies
        if (node.depth == 1)
        {
            // Direct dependencies only (optimization)
            currentResult = getDirectDependencies(targets);
        }
        else
        {
            // Use BFS for transitive dependencies
            currentResult = bfs(graph, targets, node.depth);
            
            // Remove the original targets from result
            currentResult = except(currentResult, targets);
        }
    }
    
    /// Visit rdeps expression
    override void visit(RdepsExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Get reverse dependencies
        currentResult = reverseBfs(graph, targets, node.depth);
        
        // Remove the original targets from result
        currentResult = except(currentResult, targets);
    }
    
    /// Visit allpaths expression
    override void visit(AllPathsExpr node) @system
    {
        // Evaluate 'from' expression
        node.from.accept(this);
        auto fromTargets = currentResult;
        
        // Evaluate 'to' expression
        node.to.accept(this);
        auto toTargets = currentResult;
        
        // Find all paths between any from -> to pair
        bool[BuildNode] allPathNodes;
        
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to)
                    continue;
                
                auto pathNodes = allPaths(graph, from, to);
                foreach (pathNode; pathNodes)
                    allPathNodes[pathNode] = true;
            }
        }
        
        currentResult = allPathNodes.keys;
    }
    
    /// Visit somepath expression
    override void visit(SomePathExpr node) @system
    {
        // Evaluate 'from' expression
        node.from.accept(this);
        auto fromTargets = currentResult;
        
        // Evaluate 'to' expression
        node.to.accept(this);
        auto toTargets = currentResult;
        
        // Find any single path (try first pair that has a path)
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to)
                    continue;
                
                auto path = somePath(graph, from, to);
                if (!path.empty)
                {
                    currentResult = path;
                    return;
                }
            }
        }
        
        currentResult = [];
    }
    
    /// Visit shortest path expression
    override void visit(ShortestPathExpr node) @system
    {
        // Evaluate 'from' expression
        node.from.accept(this);
        auto fromTargets = currentResult;
        
        // Evaluate 'to' expression
        node.to.accept(this);
        auto toTargets = currentResult;
        
        // Find shortest path among all pairs
        BuildNode[] shortestFound;
        
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to)
                    continue;
                
                auto path = shortestPath(graph, from, to);
                if (!path.empty)
                {
                    if (shortestFound.empty || path.length < shortestFound.length)
                        shortestFound = path;
                }
            }
        }
        
        currentResult = shortestFound;
    }
    
    /// Visit kind expression
    override void visit(KindExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Filter by kind
        currentResult = filterByKind(targets, node.kind);
    }
    
    /// Visit attr expression
    override void visit(AttrExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Filter by attribute
        currentResult = filterByAttribute(targets, node.name, node.value);
    }
    
    /// Visit filter expression
    override void visit(FilterExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Filter by regex
        currentResult = filterByRegex(targets, node.attribute, node.regex);
    }
    
    /// Visit siblings expression
    override void visit(SiblingsExpr node) @system
    {
        // Evaluate inner expression
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Get siblings
        currentResult = getSiblings(graph, targets);
    }
    
    /// Visit buildfiles expression
    override void visit(BuildFilesExpr node) @system
    {
        // Find all Builderfile files matching pattern
        BuildNode[] result;
        
        // Extract directory from pattern
        string searchPath = node.pattern;
        if (searchPath.startsWith("//"))
            searchPath = searchPath[2 .. $];
        
        // Find all targets whose Builderfile matches
        foreach (graphNode; graph.nodes.values)
        {
            if (graphNode is null)
                continue;
            
            // Check if target's directory matches pattern
            string targetId = graphNode.idString;
            if (targetId.startsWith("//"))
            {
                auto colonPos = targetId.indexOf(':');
                if (colonPos != -1)
                {
                    string targetDir = targetId[2 .. colonPos];
                    if (searchPath == "..." || targetDir.startsWith(searchPath))
                        result ~= graphNode;
                }
            }
        }
        
        currentResult = result;
    }
    
    /// Visit union expression
    override void visit(UnionExpr node) @system
    {
        // Evaluate left
        node.left.accept(this);
        auto leftResult = currentResult;
        
        // Evaluate right
        node.right.accept(this);
        auto rightResult = currentResult;
        
        // Union
        currentResult = union_(leftResult, rightResult);
    }
    
    /// Visit intersect expression
    override void visit(IntersectExpr node) @system
    {
        // Evaluate left
        node.left.accept(this);
        auto leftResult = currentResult;
        
        // Evaluate right
        node.right.accept(this);
        auto rightResult = currentResult;
        
        // Intersect
        currentResult = intersect(leftResult, rightResult);
    }
    
    /// Visit except expression
    override void visit(ExceptExpr node) @system
    {
        // Evaluate left
        node.left.accept(this);
        auto leftResult = currentResult;
        
        // Evaluate right
        node.right.accept(this);
        auto rightResult = currentResult;
        
        // Except
        currentResult = except(leftResult, rightResult);
    }
    
    /// Visit let expression
    override void visit(LetExpr node) @system
    {
        // Evaluate value expression
        node.value.accept(this);
        auto value = currentResult;
        
        // Bind variable
        variables[node.variable] = value;
        
        // Evaluate body
        node.body.accept(this);
        
        // Unbind variable (lexical scoping)
        variables.remove(node.variable);
    }
    
    /// Helper: Get direct dependencies only
    private BuildNode[] getDirectDependencies(BuildNode[] targets) @system
    {
        bool[BuildNode] result;
        
        foreach (target; targets)
        {
            if (target is null)
                continue;
            
            foreach (depId; target.dependencyIds)
            {
                auto depKey = depId.toString();
                if (depKey in graph.nodes)
                    result[graph.nodes[depKey]] = true;
            }
        }
        
        return result.keys;
    }
}

/// Convenience function to parse and evaluate a query
Result!(BuildNode[], string) executeQuery(string queryString, BuildGraph graph) @system
{
    import frontend.query.parsing.lexer : QueryLexer;
    import frontend.query.parsing.parser : QueryParser;
    
    // Lex
    auto lexer = QueryLexer(queryString);
    auto tokensResult = lexer.tokenize();
    if (tokensResult.isErr)
        return Result!(BuildNode[], string).err("Lexer error: " ~ tokensResult.unwrapErr().message());
    
    // Parse
    auto parser = QueryParser(tokensResult.unwrap());
    auto astResult = parser.parse();
    if (astResult.isErr)
        return Result!(BuildNode[], string).err("Parser error: " ~ astResult.unwrapErr());
    
    // Evaluate
    auto evaluator = new QueryEvaluator(graph);
    return evaluator.evaluate(astResult.unwrap());
}

/// Execute query with optimization (predicate pushdown)
Result!(BuildNode[], string) executeQueryOptimized(string queryString, BuildGraph graph) @system
{
    import frontend.query.parsing.lexer : QueryLexer;
    import frontend.query.parsing.parser : QueryParser;
    import frontend.query.execution.planner : QueryPlanner;
    
    auto lexer = QueryLexer(queryString);
    auto tokensResult = lexer.tokenize();
    if (tokensResult.isErr)
        return Result!(BuildNode[], string).err("Lexer error: " ~ tokensResult.unwrapErr().message());
    
    auto parser = QueryParser(tokensResult.unwrap());
    auto astResult = parser.parse();
    if (astResult.isErr)
        return Result!(BuildNode[], string).err("Parser error: " ~ astResult.unwrapErr());
    
    // Plan and optimize
    auto planner = QueryPlanner();
    auto plan = planner.plan(astResult.unwrap());
    
    // Use optimized evaluator with predicate pushdown
    auto evaluator = new OptimizedQueryEvaluator(graph, plan);
    return evaluator.evaluate(plan.optimizedExpr !is null ? plan.optimizedExpr : plan.originalExpr);
}

/// Optimized query evaluator with predicate pushdown
/// 
/// Applies extracted predicates during traversal to reduce
/// the number of nodes loaded and processed
final class OptimizedQueryEvaluator : QueryVisitor
{
    private BuildGraph graph;
    private BuildNode[] currentResult;
    private BuildNode[][string] variables;
    private Predicate[] pushedPredicates;
    
    this(BuildGraph graph, QueryPlan plan) pure nothrow @safe
    {
        this.graph = graph;
        this.pushedPredicates = plan.pushedPredicates;
    }
    
    Result!(BuildNode[], string) evaluate(QueryExpr expr) @system
    {
        try
        {
            currentResult = [];
            expr.accept(this);
            return Result!(BuildNode[], string).ok(currentResult);
        }
        catch (Exception e)
        {
            return Result!(BuildNode[], string).err(e.msg);
        }
    }
    
    override void visit(TargetPattern node) @system
    {
        if (node.pattern in variables)
        {
            currentResult = variables[node.pattern];
            return;
        }
        
        // Apply predicate pushdown during pattern matching
        if (pushedPredicates.length > 0)
            currentResult = matchPatternWithPredicates(graph, node.pattern, pushedPredicates);
        else
            currentResult = matchPattern(graph, node.pattern);
    }
    
    override void visit(DepsExpr node) @system
    {
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Optimized: apply predicates during BFS traversal
        if (node.depth == 1)
        {
            currentResult = getDirectDependenciesFiltered(targets, pushedPredicates);
        }
        else if (pushedPredicates.length > 0)
        {
            currentResult = bfsWithPredicates(graph, targets, pushedPredicates, node.depth);
            currentResult = except(currentResult, targets);
        }
        else
        {
            currentResult = bfs(graph, targets, node.depth);
            currentResult = except(currentResult, targets);
        }
    }
    
    override void visit(RdepsExpr node) @system
    {
        node.inner.accept(this);
        auto targets = currentResult;
        
        // Optimized: apply predicates during reverse BFS
        if (pushedPredicates.length > 0)
        {
            currentResult = reverseBfsWithPredicates(graph, targets, pushedPredicates, node.depth);
            currentResult = except(currentResult, targets);
        }
        else
        {
            currentResult = reverseBfs(graph, targets, node.depth);
            currentResult = except(currentResult, targets);
        }
    }
    
    // Delegate remaining visitors to standard implementation
    override void visit(AllPathsExpr node) @system
    {
        node.from.accept(this);
        auto fromTargets = currentResult;
        node.to.accept(this);
        auto toTargets = currentResult;
        
        bool[BuildNode] allPathNodes;
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to) continue;
                foreach (pathNode; allPaths(graph, from, to))
                    allPathNodes[pathNode] = true;
            }
        }
        currentResult = allPathNodes.keys;
    }
    
    override void visit(SomePathExpr node) @system
    {
        node.from.accept(this);
        auto fromTargets = currentResult;
        node.to.accept(this);
        auto toTargets = currentResult;
        
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to) continue;
                auto path = somePath(graph, from, to);
                if (!path.empty) { currentResult = path; return; }
            }
        }
        currentResult = [];
    }
    
    override void visit(ShortestPathExpr node) @system
    {
        node.from.accept(this);
        auto fromTargets = currentResult;
        node.to.accept(this);
        auto toTargets = currentResult;
        
        BuildNode[] shortestFound;
        foreach (from; fromTargets)
        {
            foreach (to; toTargets)
            {
                if (from is null || to is null || from is to) continue;
                auto path = shortestPath(graph, from, to);
                if (!path.empty && (shortestFound.empty || path.length < shortestFound.length))
                    shortestFound = path;
            }
        }
        currentResult = shortestFound;
    }
    
    // Filter expressions are already pushed, just evaluate inner
    override void visit(KindExpr node) @system   { node.inner.accept(this); }
    override void visit(AttrExpr node) @system   { node.inner.accept(this); }
    override void visit(FilterExpr node) @system { node.inner.accept(this); }
    
    override void visit(SiblingsExpr node) @system
    {
        node.inner.accept(this);
        currentResult = getSiblings(graph, currentResult);
    }
    
    override void visit(BuildFilesExpr node) @system
    {
        BuildNode[] result;
        string searchPath = node.pattern;
        if (searchPath.startsWith("//")) searchPath = searchPath[2 .. $];
        
        foreach (graphNode; graph.nodes.values)
        {
            if (graphNode is null) continue;
            string targetId = graphNode.idString;
            if (targetId.startsWith("//"))
            {
                auto colonPos = targetId.indexOf(':');
                if (colonPos != -1)
                {
                    string targetDir = targetId[2 .. colonPos];
                    if (searchPath == "..." || targetDir.startsWith(searchPath))
                        result ~= graphNode;
                }
            }
        }
        currentResult = result;
    }
    
    override void visit(UnionExpr node) @system
    {
        node.left.accept(this);
        auto leftResult = currentResult;
        node.right.accept(this);
        currentResult = union_(leftResult, currentResult);
    }
    
    override void visit(IntersectExpr node) @system
    {
        node.left.accept(this);
        auto leftResult = currentResult;
        node.right.accept(this);
        currentResult = intersect(leftResult, currentResult);
    }
    
    override void visit(ExceptExpr node) @system
    {
        node.left.accept(this);
        auto leftResult = currentResult;
        node.right.accept(this);
        currentResult = except(leftResult, currentResult);
    }
    
    override void visit(LetExpr node) @system
    {
        node.value.accept(this);
        variables[node.variable] = currentResult;
        node.body.accept(this);
        variables.remove(node.variable);
    }
    
    /// Get direct dependencies with predicate filtering
    private BuildNode[] getDirectDependenciesFiltered(BuildNode[] targets, Predicate[] predicates) @system
    {
        bool[BuildNode] result;
        
        foreach (target; targets)
        {
            if (target is null) continue;
            
            foreach (depId; target.dependencyIds)
            {
                auto depKey = depId.toString();
                if (depKey !in graph.nodes) continue;
                
                auto dep = graph.nodes[depKey];
                if (predicates.all!(p => p.matches(dep)))
                    result[dep] = true;
            }
        }
        
        return result.keys;
    }
}

// Import Predicate and planner functions at module scope
import frontend.query.execution.planner : Predicate, QueryPlan,
    bfsWithPredicates, reverseBfsWithPredicates, matchPatternWithPredicates;

