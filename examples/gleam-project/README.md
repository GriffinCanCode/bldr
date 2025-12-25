# Gleam Project Example

This example demonstrates **Gleam** language support in bldr.

## What is Gleam?

Gleam is a friendly language for building type-safe systems that scale. It compiles to:
- **Erlang** (BEAM VM) - for fault-tolerant, distributed systems
- **JavaScript** - for browser and Node.js applications

## Project Structure

```
gleam-project/
├── gleam.toml          # Gleam project manifest
├── Builderfile         # bldr build configuration
├── Builderspace        # bldr workspace config
├── src/
│   └── hello_gleam.gleam   # Main source file
└── test/
    └── hello_gleam_test.gleam  # Test file
```

## Prerequisites

- [Gleam](https://gleam.run/getting-started/installing/) installed
- Erlang/OTP installed (for BEAM target)

## Building with bldr

```bash
# Build the project
bldr build hello_gleam

# Run tests
bldr build hello_gleam_test

# Or build all targets
bldr build
```

## Building with Gleam directly

```bash
# Build
gleam build

# Run
gleam run

# Test
gleam test

# Format code
gleam format
```

## Features Demonstrated

- Basic Gleam syntax
- Function definitions with type annotations
- String concatenation with `<>`
- Pattern matching (in tests)
- Pipe operator `|>`
- Unit testing with gleeunit

## Configuration Options

The Builderfile supports these Gleam options:

```
gleam: {
    "target": "erlang",     // or "javascript"
    "format": {
        "enabled": true,
        "check": false
    },
    "warningsAsErrors": false
};
```

