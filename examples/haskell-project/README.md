# Haskell Project Example

This example demonstrates how to build Haskell projects using Builder with support for GHC, Cabal, and Stack.

## Features

- **GHC Direct Compilation**: Compile simple Haskell programs directly with GHC
- **Cabal Support**: Build projects with Cabal package manager
- **Stack Support**: Build projects with Stack build tool
- **HLint Integration**: Run HLint for code quality checks
- **Ormolu/Fourmolu**: Format code with Ormolu or Fourmolu
- **Optimization Levels**: Configure GHC optimization (-O0, -O1, -O2)
- **Language Extensions**: Enable GHC language extensions
- **Parallel Builds**: Support for parallel compilation

## Project Structure

```
haskell-project/
├── Main.hs          # Main Haskell source file
├── Builderfile      # Build configuration
├── Builderspace     # Workspace configuration
└── README.md        # This file
```

## Building

### Build with GHC (default)

```bash
bldr build hello-ghc
```

This will compile `Main.hs` directly using GHC with `-O2` optimization.

### Build with Cabal

First, create a `.cabal` file:

```bash
cabal init
```

Then uncomment the Cabal target in `Builderfile` and build:

```bash
bldr build hello-cabal
```

### Build with Stack

First, create a `stack.yaml` file:

```bash
stack init
```

Then uncomment the Stack target in `Builderfile` and build:

```bash
bldr build hello-stack
```

### Build with HLint

```bash
bldr build hello-lint
```

This will run HLint to check for code quality issues before building.

## Running

After building, run the executable:

```bash
./bin/hello-ghc
# Output: Hello, World!
# Factorial of 10: 3628800
# Is 17 prime? True
# Sorted list: [1,2,5,8,9]

# Or with a custom name:
./bin/hello-ghc Alice
# Output: Hello, Alice!
```

## Configuration Options

The Haskell handler supports many configuration options in the Builderfile:

### Build Tools

```yaml
config:
  haskell:
    buildTool: ghc      # Options: auto, ghc, cabal, stack
```

### Optimization

```yaml
config:
  haskell:
    optLevel: "2"       # Options: "0", "1", "2" (default: "2")
```

### Language Extensions

```yaml
config:
  haskell:
    extensions:
      - OverloadedStrings
      - GADTs
      - TypeFamilies
```

### GHC Options

```yaml
config:
  haskell:
    ghcOptions:
      - -Wall
      - -Wcompat
      - -Wno-unused-imports
```

### Code Quality Tools

```yaml
config:
  haskell:
    hlint: true         # Run HLint
    ormolu: true        # Run Ormolu formatter
    fourmolu: false     # Run Fourmolu formatter (alternative to Ormolu)
```

### Parallel Builds

```yaml
config:
  haskell:
    parallel: true
    jobs: 4             # Number of parallel jobs (0 = auto)
```

### Profiling and Coverage

```yaml
config:
  haskell:
    profiling: true     # Enable profiling
    coverage: true      # Enable code coverage
```

### Stack Configuration

```yaml
config:
  haskell:
    buildTool: stack
    resolver: "lts-21.22"  # LTS resolver version
```

### Cabal Configuration

```yaml
config:
  haskell:
    buildTool: cabal
    cabalFile: "myproject.cabal"
    cabalFreeze: true   # Use cabal.project.freeze
```

## Advanced Examples

### Library Project

```yaml
- name: mylib
  type: library
  language: haskell
  sources:
    - src/Lib.hs
    - src/Utils.hs
  config:
    haskell:
      buildTool: cabal
      mode: library
      haddock: true       # Generate documentation
```

### Test Suite

```yaml
- name: tests
  type: test
  language: haskell
  sources:
    - test/Spec.hs
  config:
    haskell:
      buildTool: cabal
      mode: test
      testOptions:
        - --test-show-details=direct
```

### Threaded Runtime

```yaml
config:
  haskell:
    threaded: true      # Enable threaded runtime
```

### Static Linking

```yaml
config:
  haskell:
    static: true        # Enable static linking
```

## Prerequisites

To use Haskell support in Builder, you need:

1. **GHC** (Glasgow Haskell Compiler)
   ```bash
   # Using GHCup (recommended)
   curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh
   
   # Or using package managers
   # macOS
   brew install ghc
   
   # Ubuntu/Debian
   sudo apt-get install ghc
   ```

2. **Cabal** (optional, for Cabal-based projects)
   ```bash
   ghcup install cabal
   ```

3. **Stack** (optional, for Stack-based projects)
   ```bash
   curl -sSL https://get.haskellstack.org/ | sh
   ```

4. **HLint** (optional, for linting)
   ```bash
   cabal install hlint
   # or
   stack install hlint
   ```

5. **Ormolu** (optional, for formatting)
   ```bash
   cabal install ormolu
   # or
   stack install ormolu
   ```

## Learn More

- [Haskell Official Site](https://www.haskell.org/)
- [GHC User Guide](https://downloads.haskell.org/ghc/latest/docs/users_guide/)
- [Cabal Documentation](https://www.haskell.org/cabal/)
- [Stack Documentation](https://docs.haskellstack.org/)
- [HLint](https://github.com/ndmitchell/hlint)
- [Ormolu](https://github.com/tweag/ormolu)

## Notes

- By default, Builder will auto-detect the build tool based on the presence of `.cabal` or `stack.yaml` files
- For simple single-file projects, GHC direct compilation is the fastest option
- For larger projects with dependencies, use Cabal or Stack
- HLint and formatters are only run if they are installed and explicitly enabled in the configuration

