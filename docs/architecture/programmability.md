# Build System Programmability Architecture

**Date:** November 2, 2025  
**Version:** 1.0  
**Status:** Design & Implementation

---

## Executive Summary

Builder's programmability system addresses the gap between declarative simplicity and programmable power through a **three-tier progressive complexity model**. Unlike Bazel's single Starlark approach, Builder provides the right tool for each level of complexity.

### Why Not Just Embed Lua/Wren/Starlark?

**Traditional approach (Bazel, Buck2):**
- Single embedded scripting language (Starlark)
- Forces all users to learn new language
- Type safety boundaries
- External dependency
- Doesn't leverage host language strengths

**Builder's superior approach:**
- **Tier 1**: Functional DSL extensions (90% of needs)
- **Tier 2**: D-based macros (9% advanced cases)
- **Tier 3**: Process plugins (1% custom integrations)

**Key advantages:**
1. **Principle of least power**: Use simplest tool sufficient
2. **Progressive disclosure**: Complexity scales with needs
3. **Zero new dependencies**: Pure D implementation
4. **Type safety**: No language boundaries
5. **Leverage D**: Metaprogramming, CTFE, templates
6. **Performance**: Compile-time evaluation when possible

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Builder Core                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │   Tier 1        │  │  Tier 2      │  │   Tier 3      │ │
│  │   Functional    │  │  D Macros    │  │   Plugins     │ │
│  │   DSL (90%)     │  │  (9%)        │  │   (1%)        │ │
│  │                 │  │              │  │               │ │
│  │ • Variables     │  │ • D Code     │  │ • Custom      │ │
│  │ • Functions     │  │ • CTFE       │  │   Types       │ │
│  │ • Conditionals  │  │ • Templates  │  │ • External    │ │
│  │ • Loops         │  │ • Full AST   │  │   Tools       │ │
│  │ • Simple        │  │ • Advanced   │  │ • Process     │ │
│  │                 │  │              │  │   Isolated    │ │
│  └─────────────────┘  └──────────────┘  └───────────────┘ │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│              Evaluation Engine                              │
│  • Expression evaluator                                     │
│  • Symbol table / scope management                          │
│  • Macro expander                                           │
│  • Type checker                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Tier 1: Functional DSL Extensions

### Design Principles

1. **Keep it functional**: No side effects, pure functions
2. **Type-safe**: All expressions typed at parse time
3. **Limited scope**: Not Turing-complete (prevents abuse)
4. **Familiar syntax**: Natural extension of existing DSL
5. **Compile-time**: Evaluate during parsing when possible

### Features

#### 1. Variables and Constants

```d
// Builderfile
let version = "1.0.0";
let buildFlags = ["-O2", "-Wall", "-Werror"];
let pythonVersion = "3.11";

const maxJobs = 8;
const cacheDir = ".cache";

target("app-\${version}") {
    type: executable;
    language: python;
    flags: buildFlags;
}
```

**Implementation:**
- `let`: Mutable binding in current scope
- `const`: Immutable binding (compile-time constant)
- String interpolation with `${expr}` syntax
- Scoped to file or block

#### 2. Functions and Macros

```d
// Function: returns value, evaluated inline
fn pythonLib(name, srcs, deps = []) {
    return {
        type: library,
        language: python,
        sources: srcs,
        deps: deps
    };
}

// Use function
target("utils") = pythonLib("utils", ["lib/utils/**/*.py"]);

// Macro: generates code, expanded at parse time
macro genLibs(packages) {
    for pkg in packages {
        target(pkg) {
            type: library;
            language: d;
            sources: ["lib/" + pkg + "/**/*.d"];
        }
    }
}

// Expand macro
genLibs(["core", "utils", "api", "cli"]);
```

**Distinction:**
- **Functions**: Return values, compose expressions
- **Macros**: Generate AST nodes, expand to targets

#### 3. Conditionals

```d
// Platform detection
let platform = env("OS", "linux");

if (platform == "linux") {
    let flags = ["-pthread", "-lrt"];
} else if (platform == "darwin") {
    let flags = ["-framework", "CoreFoundation"];
} else {
    let flags = [];
}

// Conditional targets
if (env("BUILD_TESTS", "1") == "1") {
    target("tests") {
        type: test;
        sources: ["tests/**/*.py"];
    }
}

// Ternary operator
let optimization = env("DEBUG") == "1" ? "-O0" : "-O3";
```

#### 4. Loops and Iteration

```d
// For loop over array
let packages = ["core", "api", "cli", "utils"];

for pkg in packages {
    target(pkg) {
        type: library;
        language: python;
        sources: ["src/" + pkg + "/**/*.py"];
    }
}

// Range loop
for i in range(1, 5) {
    target("worker-" + str(i)) {
        type: executable;
        sources: ["worker.py"];
        env: {"WORKER_ID": str(i)};
    }
}

// Map/filter
let sources = glob("src/**/*.py")
    .filter(|f| !f.contains("test"))
    .map(|f| f.replace("src/", ""));
```

#### 5. Built-in Functions

```d
// String operations
let name = "my-app";
let upper = upper(name);           // "MY-APP"
let lower = lower(name);           // "my-app"
let joined = join(["a", "b"], "/"); // "a/b"

// Array operations
let items = ["a", "b", "c"];
let length = len(items);           // 3
let first = items[0];              // "a"
let sliced = items[1:];            // ["b", "c"]

// File operations
let files = glob("src/**/*.d");
let exists = fileExists("Builderfile");
let content = readFile("VERSION");

// Environment
let home = env("HOME");
let debug = env("DEBUG", "0");

// Platform detection
let os = platform();               // "linux" | "darwin" | "windows"
let arch = arch();                 // "x86_64" | "arm64"

// String interpolation
let version = readFile("VERSION").trim();
let output = "bin/\${name}-\${version}";
```

#### 6. Advanced Patterns

```d
// Compose functions
fn makeTarget(name, type, lang, srcs) {
    return {
        type: type,
        language: lang,
        sources: srcs,
        output: "bin/" + name
    };
}

fn pythonExe(name, srcs) {
    return makeTarget(name, executable, python, srcs);
}

// Higher-order functions
fn mapTargets(names, fn) {
    for name in names {
        target(name) = fn(name, ["src/" + name + ".py"]);
    }
}

mapTargets(["app", "cli", "server"], pythonExe);

// Partial application
let makeLib = partial(makeTarget, type=library, lang=python);

target("utils") = makeLib("utils", ["lib/utils.py"]);
```

### Type System

**Primitive Types:**
- `string`: Text values
- `number`: Integer and float
- `bool`: true/false
- `array<T>`: Homogeneous arrays
- `map<K, V>`: Key-value maps
- `target`: Target configuration object

**Type Inference:**
```d
let x = 42;              // number
let name = "app";        // string
let flags = ["-O2"];     // array<string>
let config = {           // map<string, any>
    "debug": true
};
```

**Type Checking:**
- All expressions type-checked at parse time
- Function signatures enforce types
- No implicit conversions (explicit `str()`, `int()`, etc.)

---

## Tier 2: D-Based Macro System

For advanced users who need full programmatic control, write build logic directly in D.

### Design Principles

1. **Full D access**: Templates, CTFE, metaprogramming
2. **Type-safe**: Leverage D's type system
3. **Compile-time when possible**: Generate code at build time
4. **Runtime option**: Embedded D interpreter for dynamic cases

### Approach A: Compile-Time Macros (CTFE)

```d
// Builderfile.d (D file alongside Builderfile)
module builderfile;

import builder.dsl;
import std.algorithm;
import std.array;
import std.range;

// Generate targets using D's metaprogramming
Target[] generatePythonLibs(string[] packages) {
    return packages.map!(pkg => 
        Target(
            pkg,
            TargetType.library,
            Language.python,
            ["lib/" ~ pkg ~ "/**/*.py"],
            []
        )
    ).array;
}

// Generate targets based on file system
Target[] inferTargets(string root) {
    import std.file : dirEntries, SpanMode;
    
    Target[] targets;
    foreach (entry; dirEntries(root ~ "/src", "*.py", SpanMode.depth)) {
        // Custom logic to infer targets
        auto name = entry.name.baseName.stripExtension;
        targets ~= Target(
            name,
            TargetType.executable,
            Language.python,
            [entry.name]
        );
    }
    return targets;
}

// Export for Builder to use
mixin BuilderMacros!(generatePythonLibs, inferTargets);
```

**Builderfile references the D code:**
```d
// Builderfile
import Builderfile.d;

// Call D function to generate targets
generatePythonLibs(["core", "api", "cli"]);

// Or use inline
target("app") {
    type: executable;
    sources: inferSources("./src");  // D function
}
```

### Approach B: Runtime D Interpreter

For cases requiring runtime evaluation:

```d
// Builderfile
dmacro {
    import std.file : readText;
    import std.json : parseJSON;
    
    // Read config at build time
    auto config = readText("config.json").parseJSON;
    
    foreach (service; config["services"].array) {
        target(service["name"].str) {
            type: executable;
            sources: [service["path"].str];
        }
    }
}
```

**Implementation:**
- Use `druntime` for runtime D evaluation
- Or embed `dmd` as library for JIT compilation
- Sandboxed execution with limited imports

---

## Tier 3: Plugin System (Existing)

For custom target types and external tool integration, use the existing plugin system.

**Already supports:**
- Custom target types
- Build lifecycle hooks
- Artifact processing
- External tool integration

**Example:** Docker build plugin
```d
// Builderfile
target("docker-image") {
    type: custom;
    plugin: "docker";
    config: {
        "dockerfile": "Dockerfile",
        "image": "myapp:latest",
        "platform": "linux/amd64"
    };
}
```

---

## Implementation Plan

### Phase 1: Core Infrastructure (Foundation)

**Module: `source/infrastructure/config/scripting/`**

```d
source/infrastructure/config/scripting/
├── package.d              // Public API
├── evaluator.d            // Expression evaluator
├── scopemanager.d         // Symbol table & scoping
├── types.d                // Type system
├── builtins.d             // Built-in functions
├── expander.d             // Macro expander
├── interpreter.d          // Statement interpreter
└── README.md              // Documentation
```

**Key Components:**

1. **Expression Evaluator** (`evaluator.d`)
   - Evaluate expressions in AST
   - Handle variables, functions, operators
   - Type checking and inference
   - Compile-time constant folding

2. **Scope Manager** (`scope.d`)
   - Symbol tables with lexical scoping
   - Variable binding (let/const)
   - Function definitions
   - Nested scopes

3. **Type System** (`types.d`)
   - Value types (string, number, bool, array, map, target)
   - Type checking and inference
   - Type coercion rules
   - Generic types

4. **Built-ins** (`builtins.d`)
   - String operations
   - Array operations
   - File I/O
   - Environment access
   - Platform detection

5. **Macro Expander** (`expander.d`)
   - Macro definitions and expansion
   - AST transformation
   - Hygiene (prevent name collisions)

### Phase 2: DSL Parser Extensions

**Module: `source/infrastructure/config/parsing/`**

Extend existing lexer and parser:

1. **Lexer Extensions** (`lexer.d`)
   - New tokens: `let`, `const`, `fn`, `macro`, `if`, `else`, `for`, `in`, `return`
   - Operators: `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `!`
   - String interpolation: `${expr}`

2. **Parser Extensions** (`parser.d`)
   - Parse variable declarations
   - Parse function definitions
   - Parse conditionals and loops
   - Parse macro definitions
   - Parse expressions

3. **AST Extensions** (`ast.d`)
   - New node types for all constructs
   - Expression nodes
   - Statement nodes

### Phase 3: D Macro System

**Module: `source/infrastructure/config/macros/`**

```d
source/infrastructure/config/macros/
├── package.d              // Public API
├── api.d                  // Macro API and builders
├── compiler.d             // D code compilation
├── ctfe.d                 // Compile-time function execution
├── loader.d               // Macro registry and loading
└── README.md
```

### Phase 4: Integration

1. **Config Parser Integration**
   - Wire evaluator into parser
   - Evaluate expressions during parsing
   - Expand macros before semantic analysis

2. **Error Handling**
   - Rich error messages with context
   - Type errors
   - Undefined variable errors
   - Macro expansion errors

3. **Testing**
   - Unit tests for each component
   - Integration tests
   - Example projects

---

## Examples

### Example 1: Multi-Platform Build

```d
// Builderfile
let platform = env("OS", "linux");
let arch = env("ARCH", "x86_64");

let platformFlags = {
    "linux": ["-pthread", "-ldl"],
    "darwin": ["-framework", "CoreFoundation"],
    "windows": ["-lws2_32"]
};

let archFlags = {
    "x86_64": ["-m64", "-march=x86-64"],
    "arm64": ["-march=armv8-a"],
    "aarch64": ["-march=armv8-a"]
};

target("app") {
    type: executable;
    language: c;
    sources: ["src/**/*.c"];
    flags: platformFlags[platform] + archFlags[arch];
    output: "bin/app-" + platform + "-" + arch;
}
```

### Example 2: Micro-services Generator

```d
// Builderfile
let services = [
    {name: "auth", port: 8001, db: "postgres"},
    {name: "api", port: 8002, db: "redis"},
    {name: "worker", port: 8003, db: "mongo"}
];

fn makeService(svc) {
    target(svc.name) {
        type: executable;
        language: go;
        sources: ["services/" + svc.name + "/**/*.go"];
        env: {
            "PORT": str(svc.port),
            "DATABASE": svc.db
        };
    }
}

for svc in services {
    makeService(svc);
}

// Generate docker-compose
macro genDockerCompose(services) {
    let content = "version: '3'\nservices:\n";
    for svc in services {
        content = content + "  " + svc.name + ":\n";
        content = content + "    build: services/" + svc.name + "\n";
        content = content + "    ports:\n      - " + str(svc.port) + ":" + str(svc.port) + "\n";
    }
    writeFile("docker-compose.yml", content);
}

genDockerCompose(services);
```

### Example 3: Code Generation Pipeline

```d
// Builderfile
let protoFiles = glob("proto/**/*.proto");

// Generate protobuf targets
macro genProtoTargets(files, lang) {
    for file in files {
        let name = basename(file).stripExtension();
        target(name + "-proto-" + lang) {
            type: custom;
            sources: [file];
            output: "gen/" + lang + "/" + name + ".pb";
            command: "protoc --" + lang + "_out=gen/" + lang + " " + file;
        }
    }
}

genProtoTargets(protoFiles, "python");
genProtoTargets(protoFiles, "go");
genProtoTargets(protoFiles, "rust");

// Main service depends on generated code
target("service") {
    type: executable;
    language: go;
    sources: ["cmd/**/*.go"];
    deps: protoFiles.map(|f| basename(f).stripExtension() + "-proto-go");
}
```

### Example 4: Matrix Builds

```d
// Builderfile
let pythonVersions = ["3.8", "3.9", "3.10", "3.11"];
let platforms = ["linux", "darwin", "windows"];

for pyVer in pythonVersions {
    for platform in platforms {
        target("app-py\${pyVer}-\${platform}") {
            type: executable;
            language: python;
            sources: ["src/**/*.py"];
            env: {
                "PYTHON_VERSION": pyVer,
                "TARGET_PLATFORM": platform
            };
            output: "dist/app-py\${pyVer}-\${platform}";
        }
    }
}
```

---

## Performance Considerations

### Compile-Time Evaluation

**Most computation happens at parse time:**
- Variable resolution: O(1) hash table lookup
- Function calls: Inline expansion or memoization
- Conditionals: Evaluate once, prune dead branches
- Loops: Unroll at parse time

**Result:** Zero runtime overhead for most constructs.

### Caching

1. **Parse Cache**: Cache parsed Builderfiles with resolved symbols
2. **Macro Cache**: Cache expanded macros (invalidate on source change)
3. **CTFE Cache**: Cache D compile-time function results

### Optimization

1. **Constant Folding**: Evaluate constant expressions at parse time
2. **Dead Code Elimination**: Remove unreachable branches
3. **Inlining**: Inline small functions
4. **Memoization**: Cache pure function results

---

## Type Safety

### Static Guarantees

- All expressions type-checked at parse time
- No runtime type errors
- Function signatures enforced
- Array/map types preserved

### Error Detection

```d
// Error: Type mismatch
let x = "hello" + 42;  // ERROR: Cannot add string and number

// Error: Undefined variable
target("app") {
    sources: unknownVar;  // ERROR: Undefined variable 'unknownVar'
}

// Error: Function arity
fn add(a, b) { return a + b; }
let result = add(1);  // ERROR: Function 'add' expects 2 arguments, got 1
```

---

## Migration Path

### Stage 1: Declarative Only (Current)
```d
target("app") {
    type: executable;
    sources: ["main.py"];
}
```

### Stage 2: Variables
```d
let sources = ["main.py", "utils.py"];

target("app") {
    type: executable;
    sources: sources;
}
```

### Stage 3: Functions
```d
fn pythonApp(name, srcs) {
    return {
        type: executable,
        language: python,
        sources: srcs
    };
}

target("app") = pythonApp("app", ["main.py"]);
```

### Stage 4: Macros
```d
macro genApps(names) {
    for name in names {
        target(name) = pythonApp(name, [name + ".py"]);
    }
}

genApps(["app", "cli", "server"]);
```

### Stage 5: D Macros (Advanced)
```d
import Builderfile.d;

// Full D power when needed
customLogic();
```

---

## Comparison with Alternatives

| Feature | Bazel (Starlark) | Buck2 (Starlark) | Builder (3-Tier) |
|---------|------------------|------------------|------------------|
| **Simple cases** | Complex | Complex | Simple (Declarative) |
| **Variables** | Yes | Yes | Yes (Tier 1) |
| **Functions** | Yes | Yes | Yes (Tier 1) |
| **Conditionals** | Yes | Yes | Yes (Tier 1) |
| **Loops** | Yes | Yes | Yes (Tier 1) |
| **Advanced logic** | Limited | Limited | Full D (Tier 2) |
| **Type safety** | Runtime | Runtime | Compile-time |
| **Performance** | Interpreted | Interpreted | Compile-time eval |
| **Learning curve** | High | High | Progressive |
| **External deps** | Python | Python | None |
| **Leverage host** | No | No | Yes (D) |

**Verdict:** Builder's three-tier approach is objectively superior:
1. **Simpler** for common cases
2. **More powerful** for advanced cases
3. **Better performance** (compile-time)
4. **Better type safety** (static)
5. **No external dependencies**

---

## Conclusion

Builder's three-tier programmability system provides the best of all worlds:

✅ **Tier 1 (Functional DSL)**: Handles 90% of use cases elegantly  
✅ **Tier 2 (D Macros)**: Full power for advanced users  
✅ **Tier 3 (Plugins)**: External integrations  

**Key advantages over Bazel/Buck2:**
- Progressive complexity (simple stays simple)
- Compile-time evaluation (faster)
- Type safety (catch errors early)
- Zero dependencies (pure D)
- Leverage D's strengths (metaprogramming)
- Better performance (no interpreter)

**This design unlocks:**
- Multi-platform builds
- Code generation pipelines
- Matrix builds
- Dynamic target creation
- Macro libraries
- Reusable build logic

**Next steps:** Implementation following the phased approach.

