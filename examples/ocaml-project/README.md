# OCaml Example Project

This example demonstrates how to build OCaml applications using the Builder build system.

## Features

This example showcases:
- Basic OCaml module structure
- Recursive functions (factorial, Fibonacci)
- List operations (map, filter, fold)
- Pattern matching
- Higher-order functions
- Multiple build targets (native and bytecode)

## Project Structure

```
ocaml-project/
├── Builderfile        # Build configuration
├── Builderspace       # Workspace configuration
├── src/
│   ├── main.ml        # Main entry point
│   └── utils.ml       # Utility functions
└── README.md
```

## Building

### Using Builder (Auto-detection)

Builder will automatically detect and use the best available OCaml compiler:

```bash
bldr build ocaml-app
```

This will:
1. Auto-detect the OCaml compiler (prefers dune > ocamlopt > ocamlc)
2. Compile with optimization level 2
3. Output to `bin/ocaml-app`

### Build Native Executable

```bash
bldr build ocaml-app
```

Compiles to native code using ocamlopt for best performance.

### Build Bytecode Executable

```bash
bldr build ocaml-bytecode
```

Compiles to bytecode using ocamlc for portability.

### Build All Targets

```bash
bldr build
```

## Running

After building, run the executable:

```bash
./bin/ocaml-app
```

Or with Builder:

```bash
builder run ocaml-app
```

## Expected Output

```
OCaml Example Application
=========================

Hello, Alice! Welcome to OCaml.
Hello, Bob! Welcome to OCaml.
Hello, Charlie! Welcome to OCaml.

Factorial Tests:
factorial(0) = 1
factorial(1) = 1
factorial(2) = 2
factorial(3) = 6
factorial(4) = 24
factorial(5) = 120
...

Fibonacci Sequence:
fib(0) = 0
fib(1) = 1
fib(2) = 1
fib(3) = 2
fib(4) = 3
fib(5) = 5
...

Sum of [1; 2; 3; 4; 5; 6; 7; 8; 9; 10] = 55
Doubled: [2; 4; 6; 8; 10; 12; 14; 16; 18; 20]
Even numbers: [2; 4; 6; 8; 10]

Build successful with Builder!
```

## Configuration Options

The Builderfile demonstrates various OCaml build configurations:

### Compiler Selection

```d
config: {
    "compiler": "auto"  // Options: auto, dune, ocamlopt, ocamlc, ocamlbuild
}
```

### Optimization Levels

```d
config: {
    "optimize": "2"  // Options: 0, 1, 2, 3
}
```

### Output Types

```d
config: {
    "outputType": "executable"  // Options: executable, library, bytecode, native
}
```

### Additional Options

```d
config: {
    "debugInfo": true,        // Include debug symbols
    "warnings": true,         // Enable compiler warnings
    "runFormat": true,        // Run ocamlformat before building
    "libs": ["unix", "str"]   // Link OCaml libraries
}
```

## Using with Dune

If you have a `dune` file in your project, Builder will automatically detect and use dune:

```bash
# Builder will detect dune-project or dune file
bldr build
```

## Prerequisites

Install OCaml and related tools:

### Ubuntu/Debian
```bash
sudo apt install ocaml opam
opam init
opam install dune
```

### macOS
```bash
brew install ocaml opam
opam init
opam install dune
```

### Windows
Use WSL or download from https://ocaml.org/docs/install.html

## Learn More

- [OCaml Documentation](https://ocaml.org/docs)
- [Real World OCaml](https://dev.realworldocaml.org/)
- [OCaml Tutorials](https://ocaml.org/learn/)
- [Builder OCaml Support](../../source/languages/compiled/ocaml/README.md)


