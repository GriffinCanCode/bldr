module frontend.query;

/// bldrquery - Bazel-compatible query language for Builder
/// 
/// Comprehensive query DSL for exploring dependency graphs
/// 
/// Features:
/// - Full Bazel query compatibility
/// - Set operations (union, intersect, except)
/// - Advanced path finding (shortest, somepath, allpaths)
/// - Regex filtering
/// - Multiple output formats (pretty, list, JSON, DOT)
/// 
/// Architecture:
/// - `parsing/` - Lexer, parser, and AST definitions
/// - `execution/` - Query evaluation and graph algorithms
/// - `output/` - Result formatting and display
/// 
/// Example Queries:
/// ```d
/// deps(//src:app)                    // All dependencies
/// rdeps(//lib:utils)                 // Reverse dependencies
/// allpaths(//a:x, //b:y)            // All paths between targets
/// shortest(//a:x, //b:y)            // Shortest path
/// kind(library, //...)               // All libraries
/// filter("name", ".*test.*", //...) // Regex filter
/// deps(//...) & kind(library)        // Set intersection
/// //src/... - //src/test/...        // Set difference
/// ```
/// 
/// Quick Start:
/// ```d
/// import frontend.query;
/// 
/// auto result = executeQuery("deps(//src:app)", buildGraph);
/// if (result.isOk) {
///     auto formatter = QueryFormatter(OutputFormat.Pretty);
///     writeln(formatter.formatResults(result.unwrap(), query));
/// }
/// ```
/// 
/// Optimized Execution (with predicate pushdown):
/// ```d
/// // Filters like kind/attr/filter are pushed down to traversal
/// auto result = executeQueryOptimized("kind(library, deps(//...))", graph);
/// ```

// Export submodules
public import frontend.query.parsing;
public import frontend.query.execution;
public import frontend.query.output;

// Convenience imports for common usage
import infrastructure.errors;
import engine.graph;