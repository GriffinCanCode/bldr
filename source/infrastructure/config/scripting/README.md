# Builder Scripting System

**Tier 1 of the Three-Tier Programmability Architecture**

## Overview

This module implements functional DSL extensions for Builderfiles, enabling:
- **Variables**: `let` and `const` bindings
- **Functions**: Pure functions with closures for code reuse
- **First-class Functions**: Pass functions as values, return from functions
- **Lambdas**: Anonymous functions `|x| x * 2`
- **Closures**: Functions capture their lexical environment
- **Conditionals**: `if`/`else` statements
- **Loops**: `for` loops and `range()` iteration
- **Macros**: Code generation at parse time
- **Built-ins**: 26 standard library functions
- **Type Safety**: Static type checking
- **Performance**: Compile-time evaluation

## Architecture

```
┌──────────────────────────────────────────────────┐
│                 Builderfile                      │
│  let pkgs = ["core", "api"];                     │
│  for pkg in pkgs { target(pkg) { ... } }         │
└──────────────────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────┐
│              Lexer (parsing/lexer.d)             │
│  Tokenize: let, for, in, identifiers, ...        │
└──────────────────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────┐
│             Parser (parsing/parser.d)            │
│  Parse: variable decls, loops, expressions       │
└──────────────────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────┐
│            Evaluator (evaluator.d)               │
│  Evaluate expressions, resolve variables         │
└──────────────────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────┐
│             Expander (expander.d)                │
│  Expand macros, generate targets                 │
└──────────────────────────────────────────────────┘
                        ↓
┌──────────────────────────────────────────────────┐
│          Target Configuration (schema)           │
│  Final target definitions ready for building     │
└──────────────────────────────────────────────────┘
```

## Modules

### types.d
- `Value`: Runtime value with dynamic type
- `ValueType`: Type enumeration (Null, Bool, Number, String, Array, Map, Function, Target)
- `Closure`: First-class function with captured lexical environment
- `TargetConfig`: Target configuration structure
- `TypeInfo`: Type information for expressions

**Design principles:**
- Variant-based value representation
- Type-safe conversions
- Efficient equality comparison
- Closures capture environment at definition time

### scopemanager.d
- `ScopeManager`: Lexical scope management
- `Symbol`: Variable binding with metadata (name, value, isConst, isFunction, scopeLevel)
- Nested scope support with automatic cleanup

**Features:**
- Stack-based symbol tables per name
- Const enforcement (cannot reassign)
- Shadowing detection (same-scope redefinition error)
- `ScopedBlock` RAII guard for automatic scope cleanup

### builtins.d
- `BuiltinRegistry`: Function registry
- 30+ standard library functions
- String, array, file, environment operations

**Functions:**
- String: `upper`, `lower`, `trim`, `split`, `join`, `replace`, `startsWith`, `endsWith`, `contains`
- Array: `len`, `append`, `range`
- Type: `str`, `int`, `bool`
- File: `glob`, `fileExists`, `readFile`, `basename`, `dirname`, `stripExtension`
- Environment: `env`, `platform`, `arch`

### evaluator.d
- `Evaluator`: Expression evaluation engine
- Binary/unary operations
- Function calls
- Array indexing and slicing
- Type inference

**Features:**
- String interpolation: `"${var}"`
- Arithmetic: `+`, `-`, `*`, `/`, `%`
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical: `&&`, `||`, `!`
- Type checking at evaluation time

### expander.d
- `MacroExpander`: Macro expansion engine
- `MacroDefinition`: Macro structure (name, parameters, body)
- `Statement`: Legacy statement struct for macro bodies

**Features:**
- Macro definitions with parameters
- Scoped argument binding during expansion
- Target generation (stub - needs completion)

### interpreter.d
- `Interpreter`: Statement execution engine
- Bridges AST statements to evaluator

**Features:**
- Variable declaration execution (`let`, `const`)
- Function declaration with closure capture
- Control flow (`if`/`else`, `for` loops)
- Block statements with scoping
- Expression statement evaluation

## Usage Examples

### Variables
```d
let version = "1.0.0";
const buildDir = "bin";

target("app-${version}") {
    output: buildDir + "/app";
}
```

### Conditionals
```d
let platform = env("OS", "linux");

if (platform == "linux") {
    let flags = ["-pthread"];
} else if (platform == "darwin") {
    let flags = ["-framework", "CoreFoundation"];
}
```

### Loops
```d
let packages = ["core", "api", "cli"];

for pkg in packages {
    target(pkg) {
        type: library;
        sources: ["lib/" + pkg + "/**/*.py"];
    }
}
```

### Functions with Closures
```d
fn pythonLib(name, srcs) {
    return {
        type: library,
        language: python,
        sources: srcs
    };
}

target("utils") = pythonLib("utils", ["lib/utils.py"]);

// Closures capture their environment
fn makeAdder(n) {
    return |x| x + n;  // Lambda captures 'n'
}

let add5 = makeAdder(5);
let result = add5(10);  // Returns 15
```

### First-Class Functions
```d
// Functions as values
fn double(x) { return x * 2; }
fn triple(x) { return x * 3; }

let ops = [double, triple];  // Array of functions

// Higher-order functions
fn apply(fn, val) { return fn(val); }
let result = apply(double, 5);  // Returns 10

// Lambdas
let square = |x| x * x;
let nums = [1, 2, 3];
// Use with built-in map: map(nums, square)
```

### Macros
```d
macro genServices(services) {
    for svc in services {
        target(svc.name) {
            type: executable;
            sources: ["services/" + svc.name + "/**/*.go"];
            env: {"PORT": str(svc.port)};
        }
    }
}

genServices([
    {name: "auth", port: 8001},
    {name: "api", port: 8002}
]);
```

## Implementation Status

### Phase 1: Core Infrastructure ✅
- [x] Type system (`types.d`)
- [x] Scope management (`scopemanager.d`)
- [x] Built-in functions (`builtins.d`) - 26 functions
- [x] Expression evaluator (`evaluator.d`)
- [x] Macro expander (`expander.d`) - full expansion with for/if support
- [x] Statement interpreter (`interpreter.d`)
- [x] Closures and first-class functions
- [x] Lambda expressions
- [x] Return statements with early exit

### Phase 2: Parser Integration ✅
- [x] Extend lexer with new tokens
- [x] Parse variable declarations (`let`, `const`)
- [x] Parse functions (`fn`) and macros (`macro`)
- [x] Parse conditionals (`if`/`else`) and loops (`for`)
- [x] Wire interpreter into semantic analysis pipeline

### Phase 3: Testing ✅
- [x] Unit tests for each module
- [x] Type, scope, builtin, evaluator tests
- [ ] Integration tests with full Builderfiles
- [ ] Performance benchmarks

## Performance

### Compile-Time Evaluation
Most operations happen at parse time:
- Variable resolution: O(1) hash table lookup
- Function calls: Inline expansion or memoization
- Conditionals: Evaluated once, dead code eliminated
- Loops: Unrolled at parse time

**Result**: Zero runtime overhead for most constructs.

### Optimization Strategies
1. **Constant Folding**: Evaluate constants at parse time
2. **Dead Code Elimination**: Remove unreachable branches
3. **Memoization**: Cache pure function results
4. **Inlining**: Inline small functions

## Type Safety

All expressions are type-checked:
- No runtime type errors
- Function signatures enforced
- Array/map types preserved

**Type Inference:**
```d
let x = 42;              // inferred as number
let name = "app";        // inferred as string
let flags = ["-O2"];     // inferred as array<string>
```

**Type Errors:**
```d
let x = "hello" + 42;    // ERROR: Cannot add string and number
target("app") {
    sources: unknownVar;  // ERROR: Undefined variable
}
```

## Integration

### With Parser
```d
// In parser
auto evaluator = new Evaluator();

// Define variables from let statements
evaluator.defineVariable("version", Value.makeString("1.0.0"), false);

// Evaluate expressions in target definitions
auto sourcesExpr = parseExpression();  // Parse DSL expression
auto sourcesValue = evaluator.evaluate(sourcesExpr);  // Evaluate to value
```

### With Target Schema
```d
// Convert Value to Target
auto targetValue = evaluator.evaluate(targetExpr);
auto configResult = TargetConfig.fromValue(targetValue);
if (configResult.isOk) {
    auto target = configResult.unwrap();
    // Use target configuration
}
```

## Testing

Run tests:
```bash
dmd -unittest -main config/scripting/*.d -of=test-scripting
./test-scripting
```

## Next Steps

1. **Integration Tests**: Add end-to-end tests with real Builderfile examples
2. **Performance Benchmarks**: Measure parsing/evaluation overhead
3. **Error Messages**: Improve error context and suggestions
4. **Additional Builtins**: Add `reduce`, `find`, `sort`, `keys`, `values`
5. **Documentation**: User guide with more examples

## Design Decisions

### Why Functional?
- **Predictability**: Pure functions, no side effects
- **Type Safety**: Static type checking
- **Performance**: Compile-time evaluation
- **Simplicity**: Limited scope prevents abuse

### Why Not Turing-Complete?
- **Build files should be declarative**: Prevents complex logic
- **Security**: Limits what malicious Builderfiles can do
- **Performance**: Compile-time evaluation simpler
- **For complex logic**: Use Tier 2 (D macros) or Tier 3 (plugins)

### Why Value-Based?
- **Flexibility**: Dynamic types when needed
- **Type Safety**: Static checking when possible
- **Simplicity**: No complex type system to learn

## References

- [Architecture Documentation](../../../docs/architecture/programmability.md)
- [DSL Specification](../../../docs/architecture/dsl.md)
- [Examples](../../../examples/)

