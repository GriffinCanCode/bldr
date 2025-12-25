# Examples

This document covers Builder examples across multiple languages and scenarios.

## Quick Start

```bash
cd examples/simple
../../bin/bldr build
```

## Examples

### Simple Python (`examples/simple/`)

Basic Python project with library and executable.

**Builderfile:**
```d
target("utils") {
    type: library;
    language: python;
    sources: ["utils.py"];
}

target("app") {
    type: executable;
    language: python;
    sources: ["main.py"];
    deps: [":utils"];
}
```

**Run:**
```bash
cd examples/simple
../../bin/bldr build
python3 main.py
```

---

### Python Multi-Module (`examples/python-multi/`)

Python project with multiple dependencies.

**Structure:**
```
python-multi/
├── lib/
│   ├── math_utils.py
│   └── string_utils.py
├── calculator.py
└── Builderfile
```

**Builderfile:**
```d
target("math-utils") {
    type: library;
    language: python;
    sources: ["lib/math_utils.py"];
}

target("string-utils") {
    type: library;
    language: python;
    sources: ["lib/string_utils.py"];
}

target("calculator") {
    type: executable;
    language: python;
    sources: ["calculator.py"];
    deps: [":math-utils", ":string-utils"];
}
```

**Run:**
```bash
cd examples/python-multi
../../bin/bldr build
python3 calculator.py
```

---

### JavaScript/TypeScript (`examples/javascript/`)

Multiple JavaScript examples demonstrating different bundling strategies.

#### Node.js Script (`javascript-node/`)

Simple Node.js with no bundling.

```bash
cd examples/javascript/javascript-node
../../bin/bldr build
node app.js
```

#### Browser Bundle (`javascript-browser/`)

Browser application with esbuild bundling.

```bash
cd examples/javascript/javascript-browser
../../bin/bldr build
# Open index.html in browser
```

#### Library Distribution (`javascript-library/`)

Multi-format library builds (ESM, CommonJS, UMD).

```bash
cd examples/javascript/javascript-library
../../bin/bldr build //.:lib-esm //.:lib-cjs //.:lib-umd
```

#### React with Vite (`javascript-vite-react/`)

React application with Vite bundler.

**Builderfile:**
```d
target("app") {
    type: executable;
    language: javascript;
    sources: ["src/**/*.jsx", "src/**/*.js", "src/**/*.css"];
    output: "bundle.js";
    
    javascript: {
        "mode": "bundle",
        "bundler": "vite",
        "entry": "src/main.jsx",
        "platform": "browser",
        "format": "esm",
        "minify": true,
        "sourcemap": true,
        "target": "es2020",
        "jsx": true,
        "installDeps": true
    };
}
```

```bash
cd examples/javascript/javascript-vite-react
npm install
../../bin/bldr build
```

#### Vue with Vite (`javascript-vite-vue/`)

Vue 3 application with Vite.

```bash
cd examples/javascript/javascript-vite-vue
npm install
../../bin/bldr build
```

#### TypeScript (`examples/typescript-app/`)

TypeScript with type checking.

```bash
cd examples/typescript-app
../../bin/bldr build
node dist/app.js
```

**JavaScript Configuration Options:**

| Option | Values | Description |
|--------|--------|-------------|
| `mode` | `node`, `bundle`, `library` | Execution target |
| `bundler` | `esbuild`, `vite`, `webpack`, `rollup`, `none` | Bundler selection |
| `entry` | path | Entry point file |
| `platform` | `browser`, `node`, `neutral` | Target platform |
| `format` | `esm`, `cjs`, `iife`, `umd` | Output format |
| `minify` | boolean | Enable minification |
| `sourcemap` | boolean | Generate source maps |
| `target` | `es2020`, etc. | JS target version |
| `jsx` | boolean | Enable JSX transform |
| `external` | array | External dependencies |

**Bundler Selection Guide:**

- **esbuild** (default) - Fast builds, good for most projects
- **vite** - React/Vue apps, development with HMR
- **webpack** - Complex projects with custom loaders
- **rollup** - Libraries needing tree-shaking
- **none** - Simple Node.js scripts

---

### Go (`examples/go-project/`)

Native Go application.

**Structure:**
```
go-project/
├── greeter.go      - Library
├── greeter_test.go - Tests
├── main.go         - Application
└── go.mod
```

**Run:**
```bash
cd examples/go-project
../../bin/bldr build
./bin/go-app
```

---

### D Language (`examples/d-project/`)

Native D application.

```bash
cd examples/d-project
../../bin/bldr build
./bin/d-hello
```

---

### Mixed Language (`examples/mixed-lang/`)

Multi-language project with Python, JavaScript, and Go.

**Structure:**
```
mixed-lang/
├── core.py         - Python library
├── processor.py    - Python processor
├── ui.js           - JavaScript UI
├── main.go         - Go service
├── service.go      - Go library
└── Builderfile
```

```bash
cd examples/mixed-lang
../../bin/bldr build
```

---

### Additional Examples

| Directory | Language | Description |
|-----------|----------|-------------|
| `cpp-project/` | C++ | Native compilation |
| `rust-project/` | Rust | Cargo integration |
| `java-project/` | Java | JVM compilation |
| `csharp-project/` | C# | .NET compilation |
| `ruby-project/` | Ruby | Ruby scripts |
| `php-project/` | PHP | PHP scripts |
| `lua-project/` | Lua | Lua scripts |
| `nim-project/` | Nim | Nim compilation |
| `zig-project/` | Zig | Zig compilation |
| `haskell-project/` | Haskell | GHC compilation |
| `ocaml-project/` | OCaml | OCaml compilation |
| `elm-project/` | Elm | Elm compilation |
| `gleam-project/` | Gleam | Gleam compilation |
| `r-project/` | R | R scripts |
| `perl-project/` | Perl | Perl scripts |

---

## Build Features

### Dependency Graph

```bash
cd examples/python-multi
../../bin/bldr graph
```

Output shows build order and dependencies:
```
Build Graph:
============
Target: //.:math-utils
  Type: Library
  Dependents: //.:calculator

Target: //.:calculator
  Type: Executable
  Dependencies: //.:math-utils, //.:string-utils
```

### Incremental Builds

Builder uses content-based caching:

```bash
# First build
bldr build
# Built: 3, Cached: 0

# No changes
bldr build
# Built: 0, Cached: 2

# Modify one file
echo "# comment" >> lib/math_utils.py
bldr build
# Built: 2, Cached: 1
```

### Parallel Builds

Builder parallelizes independent targets:

```bash
bldr build -v
# Building //.:math-utils...
# Building //.:string-utils...
# (Both build simultaneously)
```

### Clean

```bash
bldr clean
```

---

## Running All Examples

```bash
# Sequential
./examples/run-all-examples.sh

# Parallel
./examples/run-all-examples-parallel.sh
```

---

## Contributing

Add new examples under `examples/` with:
- Source files
- `Builderfile` configuration
- `Builderspace` workspace marker
- README explaining the example

See [CONTRIBUTING.md](../../CONTRIBUTING.md).
