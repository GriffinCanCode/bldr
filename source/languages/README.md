# Languages Package

Language-specific build handlers with dependency analysis, toolchain detection, and action-level caching.

## Architecture

### Hierarchy

```
languages/
├── base/              ← BaseLanguageHandler (universal base)
├── compiled/
│   ├── base.d         ← BaseCompiledLanguageHandler
│   └── {cpp,d,rust,zig,swift,...}/
├── scripting/
│   ├── base.d         ← BaseScriptingHandler
│   └── {python,ruby,go,php,lua,r,elixir,gleam,perl}/
├── jvm/               ← Java, Kotlin, Scala
├── dotnet/            ← C#, F#
├── web/               ← JavaScript, TypeScript, CSS, Elm
├── gpu/               ← CUDA, Metal, ROCm
├── wasm/              ← WebAssembly
└── registry.d         ← Central source of truth
```

### Base Classes

| Base Class | Location | Handles |
|------------|----------|---------|
| `BaseLanguageHandler` | `base/base.d` | Universal build interface |
| `BaseCompiledLanguageHandler` | `compiled/base.d` | C++, D, Rust, Zig, Swift, etc. |
| `BaseScriptingHandler` | `scripting/base.d` | Python, Ruby, Go, PHP, Lua, etc. |

### Dependency Linking

`base/linking.d` turns a target's `deps` into a link line. It resolves the
transitive set of library dependencies, orders them dependents-first for the
linker's single left-to-right pass, and classifies each as static or shared
from the dependency's own declared output type.

The closure is language-neutral; each toolchain family spells it in its own
dialect — `cFamilyLinkArgs` for gcc/clang, `zigLinkArgs`, `dLinkArgs`. Wired
into the C/C++, D and Zig builders. Rust, Nim and Go still treat `deps` as
ordering only.

`base/linking.d` also owns `artifactFileName`, the one definition of what a
target's artifact is called — a builder naming its output differently from what
the closure predicts would have a dependent link against a path that nothing
produces.

### Language Registry

The `registry.d` module is the single source of truth for:
- Language name aliases (e.g., "py" → Python, "c++" → C++)
- File extension mappings (e.g., ".ts" → TypeScript)
- Language display labels for UI
- Language categorization

**Important**: When adding a new language, update `registry.d` and it will automatically appear in help text, wizard, and all other places.

### Supported Languages

#### Compiled Languages
C, C++, D, Zig, Rust, Nim, OCaml, Haskell, Swift, Protobuf

#### Scripting Languages  
Python, Ruby, Go, Perl, PHP, Lua, R, Elixir, Gleam

#### JVM Languages
Java, Kotlin, Scala

#### .NET Languages
C#, F#

#### Web Languages
JavaScript, TypeScript, CSS, Elm

#### GPU Languages
CUDA, Metal (macOS), ROCm/HIP

#### WebAssembly (Wasm)
WebAssembly/WASI targets with runtimes wasmtime, wasmer, wasm3

### Module Structure

Each language has a modular structure:
- **core/** - Handler and configuration
- **analysis/** - Dependency analysis
- **tooling/** - Formatters, linters, tools
- **managers/** - Package manager integration
- **builders/** - Build system integration

## Usage

```d
import languages;

auto handler = LanguageFactory.create("python");
auto deps = handler.analyzeDependencies(sourceFile);

BuildContext ctx = { target: target, config: config, services: services };
handler.buildWithContext(ctx);
```

## Key Features

- **Action-level caching** – Hash-based caching of build steps
- **Automatic dependency detection** – Per-language import analysis
- **Toolchain auto-detection** – Find compilers, interpreters, formatters
- **Environment management** – Virtualenvs, version managers, containers
- **Quality tools** – Formatters, linters, type checkers
- **Incremental builds** – Recompile only changed files
- **Cross-compilation** – Platform-specific targets

