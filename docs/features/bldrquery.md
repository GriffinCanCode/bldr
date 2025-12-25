# bldrquery - Build Query Language

Query language for exploring build dependency graphs, compatible with Bazel's query language.

## Overview

The query language enables:
- Exploring dependency relationships
- Finding paths between targets
- Filtering targets by type, attributes, or patterns
- Combining queries with set operations
- Exporting results in multiple formats

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

## Architecture

### Components

Located in `source/frontend/query/`:

- **Lexer** (`parsing/lexer.d`) - Tokenization
- **Parser** (`parsing/parser.d`) - Recursive descent parser
- **AST** (`parsing/ast.d`) - Immutable expression nodes
- **Algorithms** (`execution/algorithms.d`) - Graph traversal (BFS, DFS, path finding)
- **Operators** (`execution/operators.d`) - Set operations (union, intersect, except)
- **Evaluator** (`execution/evaluator.d`) - Visitor-based execution

### Grammar

```ebnf
query      := setExpr
setExpr    := primary (('+' | '&' | '-') primary)*
primary    := function | pattern | '(' query ')'
function   := FUNC '(' args ')'
args       := query (',' query)*
pattern    := PATTERN | STRING
```

## Syntax Reference

### Target Patterns

| Pattern | Description | Example |
|---------|-------------|---------|
| `//...` | All targets in workspace | `//...` |
| `//path/...` | All targets in path (recursive) | `//src/...` |
| `//path:target` | Specific target | `//src:app` |
| `//path:*` | All targets in directory | `//src:*` |

### Dependency Queries

#### `deps(expr)` / `deps(expr, depth)`
Returns transitive dependencies of targets.

```bash
bldr query 'deps(//src:app)'
bldr query 'deps(//src:app, 2)'  # Max depth 2
```

Implementation: BFS traversal - O(V + E)

#### `rdeps(expr)` / `rdeps(expr, depth)`
Returns reverse dependencies (what depends on these targets).

```bash
bldr query 'rdeps(//lib:utils)'
bldr query 'rdeps(//lib:utils, 3)'
```

Implementation: Reverse BFS - O(V + E)

### Path Queries

#### `allpaths(from, to)`
Finds all nodes on any path between targets.

```bash
bldr query 'allpaths(//a:x, //b:y)'
```

Implementation: DFS with backtracking - O(V! × E) worst case. Use with caution on large graphs.

#### `somepath(from, to)`
Finds any single path between targets (faster than `allpaths`).

```bash
bldr query 'somepath(//a:x, //b:y)'
```

Implementation: DFS with early exit - O(V + E)

#### `shortest(from, to)`
Finds the shortest path using BFS.

```bash
bldr query 'shortest(//a:x, //b:y)'
```

Implementation: BFS with parent tracking - O(V + E)

### Filtering

#### `kind(type, expr)`
Filters targets by type.

Types: `executable`, `binary`, `library`, `lib`, `test`, `custom`

```bash
bldr query 'kind(test, //...)'
bldr query 'kind(library, deps(//src:app))'
```

#### `attr(name, value, expr)`
Filters targets by exact attribute match in `langConfig`.

```bash
bldr query 'attr("language", "d", //...)'
```

#### `filter(attr, regex, expr)`
Filters targets using regular expressions.

```bash
bldr query 'filter("name", ".*test.*", //...)'
```

### Utility Queries

#### `siblings(expr)`
Returns all targets in the same directory as matched targets.

```bash
bldr query 'siblings(//src:app)'
```

#### `buildfiles(pattern)`
Finds all targets matching Builderfile directory pattern.

```bash
bldr query 'buildfiles("src")'
bldr query 'buildfiles("...")'  # All targets
```

#### `let(var, value, body)`
Binds a variable for reuse in queries.

```bash
bldr query 'let(mylibs, kind(library, //...), deps(//src:app) & mylibs)'
```

### Set Operations

#### Union (`+`)
```bash
bldr query '//src/... + //test/...'
```

#### Intersection (`&`)
```bash
bldr query 'deps(//lib:utils) & kind(test, //...)'
```

#### Difference (`-`)
```bash
bldr query '//src/... - //src/test/...'
```

All set operations: O(|A| + |B|)

## Output Formats

### Pretty (Default)
Human-readable format with colors.

```bash
bldr query 'deps(//src:app)' --format=pretty
```

### List
Newline-separated target names.

```bash
bldr query 'deps(//src:app)' --format=list
```

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

### DOT
GraphViz format for visualization.

```bash
bldr query 'deps(//src:app)' --format=dot > graph.dot
dot -Tpng graph.dot -o graph.png
```

## Examples

### Find circular dependencies
```bash
bldr query 'let($x, //..., $x & deps($x))'
```

### Find leaf libraries
```bash
bldr query 'kind(library, //...) - deps(kind(library, //...))'
```

### Test coverage analysis
```bash
bldr query '//src/... - rdeps(kind(test, //...))'
```

### Services depending on shared libraries
```bash
bldr query 'rdeps(//shared/...) & kind(executable, //services/...)'
```

## Complexity Summary

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `deps(expr)` | O(V + E) | BFS traversal |
| `rdeps(expr)` | O(V + E) | Reverse BFS |
| `shortest(a, b)` | O(V + E) | BFS with tracking |
| `somepath(a, b)` | O(V + E) | DFS early exit |
| `allpaths(a, b)` | O(V! × E) | Avoid on large graphs |
| `kind(t, expr)` | O(n) | Linear filter |
| `filter(a, r, expr)` | O(n × m) | Regex matching |
| `A + B` | O(\|A\| + \|B\|) | Set union |
| `A & B` | O(\|A\| + \|B\|) | Set intersection |
| `A - B` | O(\|A\| + \|B\|) | Set difference |

## Performance Tips

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

## Bazel Compatibility

### Supported (Bazel-compatible)
- `deps(expr)` / `deps(expr, depth)`
- `rdeps(expr)` / `rdeps(expr, depth)`
- `allpaths(from, to)`
- `kind(type, expr)`
- `attr(name, value, expr)`
- Target patterns (`//...`, `//path:target`)

### Extensions
- `somepath(from, to)` - Single path finding
- `shortest(from, to)` - Shortest path (BFS)
- `filter(attr, regex, expr)` - Regex filtering
- `siblings(expr)` - Same-directory targets
- `buildfiles(pattern)` - Find Builderfiles
- `let(var, value, body)` - Variable binding
- Set operators: `+`, `&`, `-`
- Multiple output formats

## Troubleshooting

### Query returns empty results
- Check target patterns match actual targets
- Verify Builderfile is parsed correctly: `bldr graph`
- Use `//...` to list all available targets

### Query is slow
- Avoid `allpaths` on large graphs
- Add depth limits: `deps(expr, 2)`
- Use `somepath` instead of `allpaths`

### Syntax errors
- Ensure quotes around query: `bldr query 'deps(//...)'`
- Check parentheses are balanced
- Use `()` for operator precedence clarity

## See Also

- [CLI Reference](../user-guides/CLI.md)
- [Dependency Graph](../architecture/overview.md)
