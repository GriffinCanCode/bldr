module frontend.query.execution;

/// Query Execution Module
/// 
/// Evaluates query AST against build graph using efficient
/// graph algorithms and set operations.
/// 
/// Components:
/// - Evaluator: Visitor-based AST execution engine
/// - Algorithms: Graph traversal (BFS, DFS, path finding)
/// - Operators: Set operations (union, intersect, except)
/// - Planner: Query optimization with predicate pushdown
/// 
/// Example:
/// ```d
/// auto evaluator = new QueryEvaluator(buildGraph);
/// auto result = evaluator.evaluate(ast);
/// // result contains BuildNode[]
/// ```
/// 
/// Optimized Query Execution:
/// ```d
/// auto planner = QueryPlanner();
/// auto plan = planner.plan(ast);
/// auto evaluator = new OptimizedQueryEvaluator(buildGraph, plan);
/// auto result = evaluator.evaluate(plan.optimizedExpr);
/// ```

public import frontend.query.execution.evaluator;
public import frontend.query.execution.algorithms;
public import frontend.query.execution.operators;
public import frontend.query.execution.planner;

