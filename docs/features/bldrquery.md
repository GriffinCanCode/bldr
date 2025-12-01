# bldrquery - Build Query Language

**bldrquery** is a powerful query language for exploring build dependency graphs, fully compatible with Bazel's query language while adding advanced features.

## Overview

The query language enables you to:
- Explore dependency relationships
- Find paths between targets
- Filter targets by type, attributes, or patterns
- Combine queries with set operations
- Export results in multiple formats

## Quick Start

```bash
# Find all dependencies of a target
bldr query 'deps(//src:app)'

# Find what depends on a library
bldr query 'rdeps(//lib:utils)'

# Find shortest path between targets
bldr query 'shortest(//a:x, //b:y)'

# Filter test targets
bldr query 'kind(test, //...)'

# Combine queries
bldr query 'deps(//src:app) & kind(library, //...)'
```

## Syntax Reference

### Target Patterns

| Pattern | Description | Example |
|---------|-------------|---------|
| `//...` | All targets in workspace | `//...` |
| `//path/...` | All targets in path (recursive) | `//src/...` |
| `//path:target` | Specific target | `//src:app` |
| `//path:*` | All targets in directory (non-recursive) | `//src:*` |

### Dependency Queries

#### `deps(expr)`
Returns all transitive dependencies of targets matched by `expr`.

```bash
# All dependencies of app
bldr query 'deps(//src:app)'

# Dependencies up to depth 2
bldr query 'deps(//src:app, 2)'
```

**Complexity:** O(V + E) using BFS

#### `rdeps(expr)`
Returns all reverse dependencies (what depends on these targets).

```bash
# What depends on utils
bldr query 'rdeps(//lib:utils)'

# Reverse deps up to depth 3
bldr query 'rdeps(//lib:utils, 3)'
```

**Complexity:** O(V + E) using reverse BFS

### Path Queries

#### `allpaths(from, to)`
Finds all nodes that lie on any path between `from` and `to`.

```bash
bldr query 'allpaths(//a:x, //b:y)'
```

**Complexity:** O(V! × E) worst case - use with caution on large graphs

#### `somepath(from, to)`
Finds any single path between targets (faster than `allpaths`).

```bash
bldr query 'somepath(//a:x, //b:y)'
```

**Complexity:** O(V + E) using DFS

#### `shortest(from, to)`
Finds the shortest path using BFS (unweighted).

```bash
bldr query 'shortest(//a:x, //b:y)'
```

**Complexity:** O(V + E) using BFS with parent tracking

### Filtering

#### `kind(type, expr)`
Filters targets by type.

Types: `executable`, `binary`, `library`, `lib`, `test`, `custom`

```bash
# All test targets
bldr query 'kind(test, //...)'

# Library dependencies of app
bldr query 'kind(library, deps(//src:app))'
```

**Complexity:** O(n) where n = result set size

#### `attr(name, value, expr)`
Filters targets by exact attribute match.

```bash
# Targets with specific language
bldr query 'attr("language", "d", //...)'
```

**Complexity:** O(n) where n = result set size

#### `filter(attr, regex, expr)`
Filters targets using regular expressions.

```bash
# Targets with "test" in name
bldr query 'filter("name", ".*test.*", //...)'

# Specific compiler flags
bldr query 'filter("flags", "-O3", //...)'
```

**Complexity:** O(n × m) where n = result set size, m = avg attr length

### Set Operations

bldrquery supports algebraic set operations for composing queries.

#### Union (`+`)
Returns all targets in either set.

```bash
# All sources and tests
bldr query '//src/... + //test/...'
```

**Complexity:** O(|A| + |B|)

#### Intersection (`&`)
Returns targets present in both sets.

```bash
# Test targets that depend on utils
bldr query 'deps(//lib:utils) & kind(test, //...)'
```

**Complexity:** O(|A| + |B|)

#### Difference (`-`)
Returns targets in first set but not second.

```bash
# Source targets excluding tests
bldr query '//src/... - //src/test/...'
```

**Complexity:** O(|A| + |B|)

### Utility Queries

#### `siblings(expr)`
Returns all targets in the same directory as matched targets.

```bash
bldr query 'siblings(//src:app)'
```

**Complexity:** O(V) where V = total targets

#### `buildfiles(pattern)`
Finds all targets in Builderfiles matching pattern.

```bash
# All targets in src directory
bldr query 'buildfiles("src")'

# All targets with Builderfiles
bldr query 'buildfiles("...")'
```

**Complexity:** O(V) where V = total targets

#### `let(var, value, body)`
Binds a variable for reuse in queries.

```bash
# Reuse a complex query
bldr query 'let(mylibs, kind(library, //...), deps(//src:app) & mylibs)'
```

**Complexity:** O(evaluation of body)

## Output Formats

bldrquery supports multiple output formats for different use cases.

### Pretty (Default)
Human-readable format with colors and metadata.

```bash
bldr query 'deps(//src:app)'
# or
bldr query 'deps(//src:app)' --format=pretty
```

### List
Simple newline-separated list of target names.

```bash
bldr query 'deps(//src:app)' --format=list
```

**Use case:** Piping to other tools

### JSON
Machine-readable structured format.

```bash
bldr query 'deps(//src:app)' --format=json
```

Output structure:
```json
{
  "query": "deps(//src:app)",
  "count": 5,
  "targets": [
    {
      "id": "//lib:utils",
      "type": "Library",
      "name": "utils",
      "sources": ["utils.d"],
      "dependencies": [],
      "dependents": ["//src:app"],
      "config": {}
    }
  ]
}
```

**Use case:** Integration with tools, analysis scripts

### DOT
GraphViz DOT format for visualization.

```bash
bldr query 'deps(//src:app)' --format=dot > graph.dot
dot -Tpng graph.dot -o graph.png
```

**Use case:** Visual dependency analysis

## Advanced Examples

### Find circular dependencies
```bash
# Find targets that depend on themselves (cycles)
bldr query 'let($x, //..., $x & deps($x))'
```

### Find leaf libraries
```bash
# Libraries with no dependencies
bldr query 'kind(library, //...) - deps(kind(library, //...))'
```

### Test coverage analysis
```bash
# Find untested code
bldr query '//src/... - rdeps(kind(test, //...))'
```

### Critical path analysis
```bash
# Targets with most dependents
bldr query --format=json '//...' | jq 'sort_by(.dependents|length)'
```

### Monorepo workspace analysis
```bash
# Services depending on shared libraries
bldr query 'rdeps(//shared/...) & kind(executable, //services/...)'
```

### Find duplicate dependencies
```bash
# Targets that both depend on
bldr query 'rdeps(//lib:a) & rdeps(//lib:b)'
```

## Performance Considerations

### Query Optimization Tips

1. **Use depth limits** for large graphs:
   ```bash
   deps(//..., 2)  # Faster than deps(//...)
   ```

2. **Prefer `somepath` over `allpaths`**:
   ```bash
   somepath(//a, //b)  # O(V+E)
   allpaths(//a, //b)  # O(V!×E)
   ```

3. **Filter early** in query chains:
   ```bash
   deps(kind(library, //src/...), 1)  # Better
   kind(library, deps(//src/..., 1))  # Worse
   ```

4. **Use set operations** instead of multiple queries:
   ```bash
   //src/... & kind(test, //...)  # Single pass
   ```

### Complexity Summary

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `deps(expr)` | O(V + E) | BFS traversal |
| `rdeps(expr)` | O(V + E) | Reverse BFS |
| `shortest(a, b)` | O(V + E) | BFS with tracking |
| `somepath(a, b)` | O(V + E) | DFS early exit |
| `allpaths(a, b)` | O(V! × E) | Exponential, avoid on large graphs |
| `kind(t, expr)` | O(n) | Linear filter |
| `filter(a, r, expr)` | O(n × m) | Regex matching |
| `A + B` | O(\|A\| + \|B\|) | Set union |
| `A & B` | O(\|A\| + \|B\|) | Set intersection |
| `A - B` | O(\|A\| + \|B\|) | Set difference |

## Comparison with Bazel Query

bldrquery is **fully compatible** with Bazel's query language while adding enhancements:

### Bazel-Compatible Features
✅ `deps(expr)` - Transitive dependencies  
✅ `rdeps(expr)` - Reverse dependencies  
✅ `allpaths(from, to)` - All paths  
✅ `kind(type, expr)` - Type filtering  
✅ `attr(name, value, expr)` - Attribute filtering  
✅ Target patterns (`//...`, `//path:target`)

### bldrquery Extensions
🆕 `somepath(from, to)` - Faster single path finding  
🆕 `shortest(from, to)` - Shortest path (BFS)  
🆕 `filter(attr, regex, expr)` - Regex filtering  
🆕 `siblings(expr)` - Same-directory targets  
🆕 `buildfiles(pattern)` - Find Builderfiles  
🆕 `let(var, value, body)` - Variable binding  
🆕 Set operators: `+` (union), `&` (intersect), `-` (except)  
🆕 Multiple output formats: pretty, list, JSON, DOT

## Implementation Details

### Architecture

bldrquery is implemented as a modular, composable system:

- **Lexer** (`core/query/lexer.d`) - Tokenization
- **Parser** (`core/query/parser.d`) - Recursive descent parser
- **AST** (`core/query/ast.d`) - Immutable expression nodes
- **Algorithms** (`core/query/algorithms.d`) - Graph traversal library
- **Operators** (`core/query/operators.d`) - Set algebra
- **Evaluator** (`core/query/evaluator.d`) - Visitor-based execution
- **Formatter** (`core/query/formatter.d`) - Multi-format output

### Design Principles

1. **Immutability** - AST nodes are immutable
2. **Composability** - Queries are algebraic expressions
3. **Type Safety** - Strong typing throughout
4. **Performance** - Optimized algorithms (BFS, DFS, etc.)
5. **Extensibility** - Easy to add new operations

### Testing

See `tests/integration/query.d` for comprehensive test suite covering:
- All query functions
- Set operations
- Edge cases (cycles, empty graphs)
- Performance benchmarks

## Troubleshooting

### Common Issues

**Query returns empty results**
- Check target patterns match actual targets
- Verify Builderfile is parsed correctly: `bldr graph`
- Use `//...` to list all available targets

**Query is slow**
- Avoid `allpaths` on large graphs
- Add depth limits: `deps(expr, 2)`
- Use `somepath` instead of `allpaths`
- Profile with `--format=json` to see result sizes

**Syntax errors**
- Ensure quotes around query: `bldr query 'deps(//...)'`
- Check parentheses are balanced
- Verify operator precedence: use `()` for clarity

**Regex not matching**
- Use `filter("attr", "pattern", expr)` not `attr`
- Check regex syntax: `.*` for wildcard, `\.` for literal dot
- Use `--format=list` to debug matches

## See Also

- [CLI Reference](../user-guides/cli.md)
- [Dependency Graph](../architecture/overview.md)
- [Build Configuration](../user-guides/examples.md)
- [Performance Tuning](performance.md)

