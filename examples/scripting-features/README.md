# Scripting Features Examples

This directory contains examples demonstrating Builder's Tier 1 programmability features.

## Examples

### 1. `Builderfile.variables` - Variables and Constants
Demonstrates `let` and `const` declarations with different types.

### 2. `Builderfile.loops` - For Loops
Shows how to generate multiple targets from arrays using `for` loops.

### 3. `Builderfile.conditionals` - If/Else Statements
Platform-specific and conditional target generation.

### 4. `Builderfile.functions` - Functions and Closures
User-defined functions for reusable target templates.

### 5. `Builderfile.builtins` - Built-in Functions
Using built-in functions for string manipulation, file operations, etc.

### 6. `Builderfile.complete` - Complete Example
A comprehensive example combining all features.

## Running Examples

```bash
# Test parsing each example
bldr parse examples/scripting-features/Builderfile.variables
bldr parse examples/scripting-features/Builderfile.loops
bldr parse examples/scripting-features/Builderfile.conditionals
bldr parse examples/scripting-features/Builderfile.functions
bldr parse examples/scripting-features/Builderfile.builtins
bldr parse examples/scripting-features/Builderfile.complete

# Build with a specific example
cp examples/scripting-features/Builderfile.complete Builderfile
bldr build
```

## Features Demonstrated

| Feature | File | Description |
|---------|------|-------------|
| `let` declarations | variables | Mutable variables |
| `const` declarations | variables | Immutable constants |
| String interpolation | variables | `"prefix-${var}"` |
| `for` loops | loops | Iterate over arrays |
| `range()` | loops | Generate numeric ranges |
| `if`/`else` | conditionals | Conditional branching |
| `fn` definitions | functions | User-defined functions |
| Closures | functions | Functions capturing environment |
| Lambdas | functions | Anonymous functions `\|x\| x * 2` |
| `upper`/`lower` | builtins | String case conversion |
| `split`/`join` | builtins | String manipulation |
| `filter`/`map` | builtins | Array transformations |
| `env()` | builtins | Environment variables |
| `platform()` | builtins | OS detection |
| `glob()` | builtins | File pattern matching |

