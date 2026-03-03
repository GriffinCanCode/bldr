module frontend.query.execution.planner;

import std.algorithm;
import std.array;
import std.conv : to;
import std.range;
import std.string : toLower;
import frontend.query.parsing.ast;
import engine.graph;
import infrastructure.config.schema.schema;

/// Predicate types that can be pushed down for early filtering
enum PredicateType { Kind, Attr, Filter, Pattern }

/// A predicate extracted from the query for pushdown optimization
struct Predicate {
    PredicateType type;
    string arg1;  // kind type, attr name, filter attr, or pattern
    string arg2;  // attr value or regex pattern (empty for Kind/Pattern)
    
    /// Apply predicate to a single node without loading full metadata
    bool matches(BuildNode node) const @system {
        if (node is null) return false;
        
        final switch (type) {
            case PredicateType.Kind:
                return matchKind(node, arg1);
            case PredicateType.Attr:
                return matchAttr(node, arg1, arg2);
            case PredicateType.Filter:
                return matchFilter(node, arg1, arg2);
            case PredicateType.Pattern:
                return matchPatternPredicate(node, arg1);
        }
    }
    
    private static bool matchKind(BuildNode node, string kind) @system {
        TargetType targetType;
        switch (kind.toLower()) {
            case "executable", "binary": targetType = TargetType.Executable; break;
            case "library", "lib":       targetType = TargetType.Library; break;
            case "test":                  targetType = TargetType.Test; break;
            case "custom":                targetType = TargetType.Custom; break;
            default:                      return false;
        }
        return node.target.type == targetType;
    }
    
    private static bool matchAttr(BuildNode node, string name, string value) @system =>
        name in node.target.langConfig && node.target.langConfig[name] == value;
    
    private static bool matchFilter(BuildNode node, string attr, string regexPattern) @system {
        import std.regex : regex, matchFirst;
        if (attr !in node.target.langConfig) return false;
        try {
            return !matchFirst(node.target.langConfig[attr], regex(regexPattern)).empty;
        } catch (Exception) {
            return false;
        }
    }
    
    private static bool matchPatternPredicate(BuildNode node, string pattern) @system {
        import std.string : startsWith, endsWith;
        string id = node.idString;
        if (pattern == "//...") return true;
        if (pattern.endsWith("...")) return id.startsWith(pattern[0 .. $ - 3]);
        if (pattern.endsWith(":*"))  return id.startsWith(pattern[0 .. $ - 1]);
        return id == pattern;
    }
}

/// Query execution plan with optimization hints
struct QueryPlan {
    QueryExpr originalExpr;
    QueryExpr optimizedExpr;    // Rewritten expression (predicates extracted)
    Predicate[] pushedPredicates;
    bool useLazyLoading;        // Can defer full metadata loading
    bool canShortCircuit;       // Can exit early on first match
    size_t estimatedCost;       // Relative cost estimate
}

/// Query planner - analyzes and optimizes queries
/// 
/// Optimization strategies:
/// 1. Predicate pushdown: Apply filters during traversal, not after
/// 2. Cost estimation: Estimate relative query cost
/// 3. Short-circuit detection: Identify queries that can exit early
struct QueryPlanner {
    /// Analyze and optimize a query expression
    QueryPlan plan(QueryExpr expr) @system {
        QueryPlan result;
        result.originalExpr = expr;
        
        // Extract pushable predicates
        auto extracted = extractPredicates(expr);
        result.pushedPredicates = extracted.predicates;
        result.optimizedExpr = extracted.remaining;
        
        // Analyze for optimization opportunities
        result.useLazyLoading = canUseLazyLoading(expr);
        result.canShortCircuit = canShortCircuit(expr);
        result.estimatedCost = estimateCost(expr);
        
        return result;
    }
    
    /// Extract predicates that can be pushed down
    private static PredicateExtraction extractPredicates(QueryExpr expr) @system {
        auto extractor = new PredicateExtractor();
        expr.accept(extractor);
        return PredicateExtraction(extractor.predicates.dup, extractor.innerExpr);
    }
    
    /// Check if lazy loading can be used
    private static bool canUseLazyLoading(QueryExpr expr) @system {
        auto analyzer = new LazyLoadAnalyzer();
        expr.accept(analyzer);
        return analyzer.canLazyLoad;
    }
    
    /// Check if query can short-circuit
    private static bool canShortCircuit(QueryExpr expr) @system {
        // SomePath and ShortestPath can exit early when path found
        auto analyzer = new ShortCircuitAnalyzer();
        expr.accept(analyzer);
        return analyzer.canShortCircuit;
    }
    
    /// Estimate relative cost of query
    private static size_t estimateCost(QueryExpr expr) @system {
        auto analyzer = new CostEstimator();
        expr.accept(analyzer);
        return analyzer.cost;
    }
}

private struct PredicateExtraction {
    Predicate[] predicates;
    QueryExpr remaining;
}

/// Visitor to extract pushable predicates from outer expressions
private final class PredicateExtractor : QueryVisitor {
    Predicate[] predicates;
    QueryExpr innerExpr;
    
    override void visit(KindExpr node) @system {
        predicates ~= Predicate(PredicateType.Kind, node.kind, "");
        innerExpr = node.inner;
        // Recursively check for more pushable predicates
        node.inner.accept(this);
    }
    
    override void visit(AttrExpr node) @system {
        predicates ~= Predicate(PredicateType.Attr, node.name, node.value);
        innerExpr = node.inner;
        node.inner.accept(this);
    }
    
    override void visit(FilterExpr node) @system {
        predicates ~= Predicate(PredicateType.Filter, node.attribute, node.regex);
        innerExpr = node.inner;
        node.inner.accept(this);
    }
    
    // Non-pushable expressions - stop extraction, keep as innerExpr
    override void visit(TargetPattern node)    { if (innerExpr is null) innerExpr = node; }
    override void visit(DepsExpr node)         { if (innerExpr is null) innerExpr = node; }
    override void visit(RdepsExpr node)        { if (innerExpr is null) innerExpr = node; }
    override void visit(AllPathsExpr node)     { if (innerExpr is null) innerExpr = node; }
    override void visit(SomePathExpr node)     { if (innerExpr is null) innerExpr = node; }
    override void visit(ShortestPathExpr node) { if (innerExpr is null) innerExpr = node; }
    override void visit(SiblingsExpr node)     { if (innerExpr is null) innerExpr = node; }
    override void visit(BuildFilesExpr node)   { if (innerExpr is null) innerExpr = node; }
    override void visit(UnionExpr node)        { if (innerExpr is null) innerExpr = node; }
    override void visit(IntersectExpr node)    { if (innerExpr is null) innerExpr = node; }
    override void visit(ExceptExpr node)       { if (innerExpr is null) innerExpr = node; }
    override void visit(LetExpr node)          { if (innerExpr is null) innerExpr = node; }
}

/// Analyzer for lazy loading eligibility
private final class LazyLoadAnalyzer : QueryVisitor {
    bool canLazyLoad = true;
    
    // AllPaths requires full graph traversal - no lazy loading
    override void visit(AllPathsExpr node) @system {
        canLazyLoad = false;
        node.from.accept(this);
        node.to.accept(this);
    }
    
    // Propagate through nested expressions
    override void visit(KindExpr node) @system    { node.inner.accept(this); }
    override void visit(AttrExpr node) @system    { node.inner.accept(this); }
    override void visit(FilterExpr node) @system  { node.inner.accept(this); }
    override void visit(SiblingsExpr node) @system { node.inner.accept(this); }
    override void visit(DepsExpr node) @system    { node.inner.accept(this); }
    override void visit(RdepsExpr node) @system   { node.inner.accept(this); }
    override void visit(UnionExpr node) @system {
        node.left.accept(this);
        node.right.accept(this);
    }
    override void visit(IntersectExpr node) @system {
        node.left.accept(this);
        node.right.accept(this);
    }
    override void visit(ExceptExpr node) @system {
        node.left.accept(this);
        node.right.accept(this);
    }
    override void visit(SomePathExpr node) @system {
        node.from.accept(this);
        node.to.accept(this);
    }
    override void visit(ShortestPathExpr node) @system {
        node.from.accept(this);
        node.to.accept(this);
    }
    override void visit(LetExpr node) @system {
        node.value.accept(this);
        node.body.accept(this);
    }
    
    // Leaf nodes - no-op
    override void visit(TargetPattern node)  {}
    override void visit(BuildFilesExpr node) {}
}

/// Analyzer for short-circuit opportunities
private final class ShortCircuitAnalyzer : QueryVisitor {
    bool canShortCircuit = false;
    
    override void visit(SomePathExpr node)     { canShortCircuit = true; }
    override void visit(ShortestPathExpr node) { canShortCircuit = true; }
    
    // Non short-circuitable
    override void visit(TargetPattern node)    {}
    override void visit(DepsExpr node)         {}
    override void visit(RdepsExpr node)        {}
    override void visit(AllPathsExpr node)     {}
    override void visit(KindExpr node)         {}
    override void visit(AttrExpr node)         {}
    override void visit(FilterExpr node)       {}
    override void visit(SiblingsExpr node)     {}
    override void visit(BuildFilesExpr node)   {}
    override void visit(UnionExpr node)        {}
    override void visit(IntersectExpr node)    {}
    override void visit(ExceptExpr node)       {}
    override void visit(LetExpr node)          {}
}

/// Cost estimator for query optimization decisions
private final class CostEstimator : QueryVisitor {
    size_t cost = 0;
    
    // High cost operations
    override void visit(AllPathsExpr node) @system {
        cost += 1000;  // Exponential worst case
        node.from.accept(this);
        node.to.accept(this);
    }
    
    override void visit(DepsExpr node) @system {
        cost += node.depth == -1 ? 100 : cast(size_t)(10 * node.depth);
        node.inner.accept(this);
    }
    
    override void visit(RdepsExpr node) @system {
        cost += node.depth == -1 ? 100 : cast(size_t)(10 * node.depth);
        node.inner.accept(this);
    }
    
    // Medium cost
    override void visit(SomePathExpr node) @system {
        cost += 50;
        node.from.accept(this);
        node.to.accept(this);
    }
    
    override void visit(ShortestPathExpr node) @system {
        cost += 50;
        node.from.accept(this);
        node.to.accept(this);
    }
    
    override void visit(SiblingsExpr node) @system {
        cost += 20;
        node.inner.accept(this);
    }
    
    // Low cost - filtering
    override void visit(KindExpr node) @system   { cost += 1; node.inner.accept(this); }
    override void visit(AttrExpr node) @system   { cost += 2; node.inner.accept(this); }
    override void visit(FilterExpr node) @system { cost += 5; node.inner.accept(this); }  // Regex is slower
    
    // Set operations
    override void visit(UnionExpr node) @system {
        cost += 5;
        node.left.accept(this);
        node.right.accept(this);
    }
    
    override void visit(IntersectExpr node) @system {
        cost += 5;
        node.left.accept(this);
        node.right.accept(this);
    }
    
    override void visit(ExceptExpr node) @system {
        cost += 5;
        node.left.accept(this);
        node.right.accept(this);
    }
    
    override void visit(LetExpr node) @system {
        node.value.accept(this);
        node.body.accept(this);
    }
    
    // Leaf costs
    override void visit(TargetPattern node)  { cost += 10; }
    override void visit(BuildFilesExpr node) { cost += 15; }
}

/// Apply pushed predicates during graph traversal (BFS with filtering)
/// 
/// This is the core optimization: instead of loading all nodes then filtering,
/// we filter during traversal to avoid loading metadata for non-matching nodes
BuildNode[] bfsWithPredicates(
    BuildGraph graph,
    BuildNode[] starts,
    Predicate[] predicates,
    int maxDepth = -1
) @system {
    import std.container : DList;
    
    if (starts.empty) return [];
    
    BuildNode[] result;
    bool[uint] visited;  // Index-based for O(1) lookup
    
    struct Item { BuildNode node; int depth; }
    auto queue = DList!Item();
    
    foreach (start; starts) {
        if (start is null) continue;
        queue.insertBack(Item(start, 0));
        visited[start._nodeIndex] = true;
    }
    
    while (!queue.empty) {
        auto item = queue.front;
        queue.removeFront();
        
        // Apply predicates early - skip nodes that don't match
        bool matches = true;
        foreach (pred; predicates) {
            if (!pred.matches(item.node)) {
                matches = false;
                break;
            }
        }
        
        if (matches)
            result ~= item.node;
        
        if (maxDepth != -1 && item.depth >= maxDepth)
            continue;
        
        // Explore neighbors using indexed access
        foreach (idx; item.node.dependencyIndices) {
            auto neighbor = graph.getNodeByIndex(idx);
            if (neighbor is null || neighbor._nodeIndex in visited) continue;
            
            visited[neighbor._nodeIndex] = true;
            queue.insertBack(Item(neighbor, item.depth + 1));
        }
    }
    
    return result;
}

/// Reverse BFS with predicate filtering
BuildNode[] reverseBfsWithPredicates(
    BuildGraph graph,
    BuildNode[] starts,
    Predicate[] predicates,
    int maxDepth = -1
) @system {
    import std.container : DList;
    
    if (starts.empty) return [];
    
    BuildNode[] result;
    bool[uint] visited;  // Index-based for O(1) lookup
    
    struct Item { BuildNode node; int depth; }
    auto queue = DList!Item();
    
    foreach (start; starts) {
        if (start is null) continue;
        queue.insertBack(Item(start, 0));
        visited[start._nodeIndex] = true;
    }
    
    while (!queue.empty) {
        auto item = queue.front;
        queue.removeFront();
        
        // Apply predicates early
        bool matches = predicates.all!(p => p.matches(item.node));
        if (matches)
            result ~= item.node;
        
        if (maxDepth != -1 && item.depth >= maxDepth)
            continue;
        
        // Explore dependents using indexed access
        foreach (idx; item.node.dependentIndices) {
            auto neighbor = graph.getNodeByIndex(idx);
            if (neighbor is null || neighbor._nodeIndex in visited) continue;
            
            visited[neighbor._nodeIndex] = true;
            queue.insertBack(Item(neighbor, item.depth + 1));
        }
    }
    
    return result;
}

/// Pattern matching with predicate filtering
BuildNode[] matchPatternWithPredicates(
    BuildGraph graph,
    string pattern,
    Predicate[] predicates
) @system {
    import std.string : startsWith, endsWith;
    
    BuildNode[] result;
    
    bool matchesPattern(BuildNode node) {
        string id = node.idString;
        if (pattern == "//...") return true;
        if (pattern.endsWith("...")) return id.startsWith(pattern[0 .. $ - 3]);
        if (pattern.endsWith(":*"))  return id.startsWith(pattern[0 .. $ - 1]);
        return id == pattern;
    }
    
    // Use _nodeArray for cache locality
    foreach (node; graph._nodeArray) {
        if (node is null) continue;
        if (!matchesPattern(node)) continue;
        if (predicates.all!(p => p.matches(node)))
            result ~= node;
    }
    
    return result;
}

