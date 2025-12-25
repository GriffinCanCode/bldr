# Build System Programmability Architecture

**Status:** Implemented (Tier 1), Design (Tier 2-3)  
**Version:** 1.0

---

## Overview

Builder provides programmability through a three-tier model:

| Tier | Description | Status |
|------|-------------|--------|
| **Tier 1** | Functional DSL extensions | ✅ Implemented |
| **Tier 2** | D-based macros | 📋 Design |
| **Tier 3** | Process plugins | ✅ Implemented |

Most use cases (estimated 90%) are handled by Tier 1.

---

## Architecture

```
source/infrastructure/config/scripting/
├── types.d          # Value types and closures
├── scopemanager.d   # Lexical scoping
├── builtins.d       # Built-in functions (26)
├── evaluator.d      # Expression evaluation
├── expander.d       # Macro expansion
├── interpreter.d    # Statement execution
└── package.d        # Public API
```

---

## Tier 1: Functional DSL Extensions

### Variables

```d
let version = "1.0.0";
const buildDir = "bin";

target("app-${version}") {
    output: buildDir + "/app";
}
```

- `let`: Mutable binding in current scope
- `const`: Immutable binding (reassignment error)
- `${expr}`: String interpolation

### Functions

```d
fn pythonLib(name, srcs, deps = []) {
    return {
        type: library,
        language: python,
        sources: srcs,
        deps: deps
    };
}

target("utils") = pythonLib("utils", ["lib/utils/**/*.py"]);
```

Functions support:
- Parameters with default values
- Closures capturing lexical environment
- Return values

### Lambdas

```d
let double = |x| x * 2;
let nums = [1, 2, 3].map(|n| n * 2);
let evens = [1, 2, 3, 4].filter(|n| n % 2 == 0);
```

### Conditionals

```d
let platform = env("OS", "linux");

if (platform == "linux") {
    let flags = ["-pthread"];
} else if (platform == "darwin") {
    let flags = ["-framework", "CoreFoundation"];
} else {
    let flags = [];
}

// Ternary
let opt = env("DEBUG") == "1" ? "-O0" : "-O3";
```

### Loops

```d
let packages = ["core", "api", "cli"];

for pkg in packages {
    target(pkg) {
        type: library;
        sources: ["src/" + pkg + "/**/*.py"];
    }
}

for i in range(1, 5) {
    target("worker-" + str(i)) {
        type: executable;
    }
}
```

### Macros

```d
macro genLibs(packages) {
    for pkg in packages {
        target(pkg) {
            type: library;
            sources: ["lib/" + pkg + "/**/*.d"];
        }
    }
}

genLibs(["core", "utils", "api"]);
```

---

## Built-in Functions

### String Operations

| Function | Description | Example |
|----------|-------------|---------|
| `upper(str)` | Uppercase | `upper("hello")` → `"HELLO"` |
| `lower(str)` | Lowercase | `lower("HELLO")` → `"hello"` |
| `trim(str)` | Strip whitespace | `trim("  x  ")` → `"x"` |
| `split(str, sep)` | Split string | `split("a,b", ",")` → `["a", "b"]` |
| `join(arr, sep)` | Join array | `join(["a", "b"], "/")` → `"a/b"` |
| `replace(str, old, new)` | Replace | `replace("ab", "a", "x")` → `"xb"` |
| `startsWith(str, prefix)` | Check prefix | `startsWith("foo", "f")` → `true` |
| `endsWith(str, suffix)` | Check suffix | `endsWith("foo", "o")` → `true` |
| `contains(str, substr)` | Check contains | `contains("foo", "oo")` → `true` |

### Array Operations

| Function | Description | Example |
|----------|-------------|---------|
| `len(arr)` | Length | `len([1, 2, 3])` → `3` |
| `append(arr, elem)` | Append | `append([1], 2)` → `[1, 2]` |
| `range(start, end)` | Integer range | `range(1, 4)` → `[1, 2, 3]` |
| `filter(arr, fn)` | Filter | `filter([1,2,3], \|x\| x > 1)` |
| `map(arr, fn)` | Transform | `map([1,2], \|x\| x * 2)` |

### Type Conversions

| Function | Description |
|----------|-------------|
| `str(value)` | Convert to string |
| `int(value)` | Convert to integer |
| `bool(value)` | Convert to boolean |

### File Operations

| Function | Description |
|----------|-------------|
| `glob(pattern)` | Match files |
| `fileExists(path)` | Check file exists |
| `readFile(path)` | Read file contents |
| `basename(path)` | Get filename |
| `dirname(path)` | Get directory |
| `stripExtension(path)` | Remove extension |

### Environment

| Function | Description |
|----------|-------------|
| `env(name, default)` | Get env variable |
| `platform()` | OS name (`linux`/`darwin`/`windows`) |
| `arch()` | Architecture (`x86_64`/`arm64`) |

---

## Type System

### Value Types

```d
enum ValueType {
    Null,
    Bool,
    Number,
    String,
    Array,
    Map,
    Function,  // Closures
    Target     // Target configuration
}
```

### Type Inference

```d
let x = 42;              // Number
let name = "app";        // String
let flags = ["-O2"];     // Array
let config = {key: true}; // Map
```

### Operators

- **Arithmetic**: `+`, `-`, `*`, `/`, `%`
- **Comparison**: `==`, `!=`, `<`, `>`, `<=`, `>=`
- **Logical**: `&&`, `||`, `!`
- **Concatenation**: `+` (strings and arrays)

---

## Scoping

The `ScopeManager` provides lexical scoping:

```d
let x = 1;
{
    let x = 2;  // Shadows outer x
    // x == 2 here
}
// x == 1 here
```

**Scope Rules:**
- Variables resolved from innermost to outermost scope
- `const` variables cannot be reassigned
- Shadowing allowed across scopes but not within same scope
- Functions capture their lexical environment (closures)

---

## Examples

### Multi-Platform Build

```d
let platform = env("OS", "linux");
let arch = env("ARCH", "x86_64");

let platformFlags = {
    "linux": ["-pthread", "-ldl"],
    "darwin": ["-framework", "CoreFoundation"],
    "windows": ["-lws2_32"]
};

target("app") {
    type: executable;
    sources: ["src/**/*.c"];
    flags: platformFlags[platform];
    output: "bin/app-" + platform + "-" + arch;
}
```

### Microservices Generator

```d
let services = [
    {name: "auth", port: 8001},
    {name: "api", port: 8002},
    {name: "worker", port: 8003}
];

for svc in services {
    target(svc.name) {
        type: executable;
        language: go;
        sources: ["services/" + svc.name + "/**/*.go"];
        env: {"PORT": str(svc.port)};
    }
}
```

### Matrix Builds

```d
let versions = ["3.9", "3.10", "3.11"];
let platforms = ["linux", "darwin"];

for ver in versions {
    for plat in platforms {
        target("app-py" + ver + "-" + plat) {
            type: executable;
            language: python;
            sources: ["src/**/*.py"];
            env: {"PYTHON_VERSION": ver, "TARGET_PLATFORM": plat};
        }
    }
}
```

---

## Tier 2: D Macros (Design)

For advanced cases requiring full programmatic control:

```d
// Builderfile.d
import builder.dsl;

Target[] generateTargets(string root) {
    import std.file : dirEntries, SpanMode;
    Target[] targets;
    foreach (entry; dirEntries(root ~ "/src", "*.py", SpanMode.depth)) {
        targets ~= Target(entry.name.baseName.stripExtension, ...);
    }
    return targets;
}

mixin BuilderMacros!(generateTargets);
```

**Note:** Tier 2 is in design phase.

---

## Tier 3: Plugins

For custom target types and external tool integration, see [Plugin Architecture](PLUGINS.md).

---

## Performance

| Operation | Typical Time |
|-----------|--------------|
| Variable lookup | O(1) hash lookup |
| Function call | Inline expansion |
| Conditionals | Evaluated once |
| Loops | Unrolled at parse time |

Most evaluation happens at parse time with no runtime overhead.

---

## Related Documentation

- [Scripting README](../../source/infrastructure/config/scripting/README.md)
- [Built-in Functions](../../source/infrastructure/config/scripting/builtins.d)
- [Evaluator](../../source/infrastructure/config/scripting/evaluator.d)
- [Plugin Architecture](PLUGINS.md)
