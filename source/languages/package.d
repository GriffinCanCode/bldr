module languages;

/// Language Support Package
/// Language-specific build handlers and dependency analysis
/// 
/// Architecture:
///   registry.d   - **Central source of truth** for all language definitions, aliases, and metadata
///   base.d       - Base language interface
///   dynamic/     - Zero-code language addition via declarative specs
///   python/      - Python language support (modular)
///   javascript/  - JavaScript/Node.js support (modular)
///   typescript/  - TypeScript support with type checking (modular)
///   go/          - Go language support (modular)
///   rust/        - Rust language support (modular)
///   java/        - Java language support (modular - Maven, Gradle, builders, formatters, analysis)
///   cpp/         - C/C++ language support (modular)
///   csharp/      - C# language support (modular - dotnet, MSBuild, Native AOT, formatters, analyzers)
///   fsharp/      - F# language support (modular)
///   ruby/        - Ruby language support (modular)
///   perl/        - Perl language support (modular - scripts, modules, CPAN, prove)
///   php/         - PHP language support (modular)
///   r/           - R language support (modular - scripts, packages, Shiny, RMarkdown)
///   swift/       - Swift language support (modular - SPM, Xcode, cross-compilation)
///   kotlin/      - Kotlin language support (modular - Gradle, Maven, multiplatform, Android, KSP, detekt)
///   scala/       - Scala language support (modular)
///   elixir/      - Elixir language support (modular - scripts, Mix, Phoenix, Umbrella, Escript, Nerves)
///   gleam/       - Gleam language support (modular - BEAM/JS targets, Hex packages, formatting)
///   lua/         - Lua language support (modular - runtimes, LuaRocks, LuaJIT, formatters, linters, testers)
///   nim/         - Nim language support (modular)
///   zig/         - Zig language support (modular)
///   haskell/     - Haskell language support (modular - GHC, Cabal, Stack, HLint, Ormolu)
///   ocaml/       - OCaml language support (modular - dune, ocamlopt, ocamlc, opam)
///   protobuf/    - Protocol Buffers support (modular - protoc, buf, code generation)
///   elm/         - Elm language support (functional, web, compiles to JavaScript)
///   wasm/        - WebAssembly support (modular - wasm-pack, emscripten, wasmtime, wasmer, WASI)
/// 
/// Dynamic Language Support
///   Instead of 150+ lines of D code per language, define languages via JSON specs.
///   See languages/specs/ for examples (Crystal, Dart, V).
///   Community can contribute language support without knowing D!
///
/// IMPORTANT: When adding support for a new language:
/// 1. Add the language to the TargetLanguage enum in config/schema/schema.d
/// 2. Register it in languages/registry.d (aliases, extensions, category)
/// 3. Implement the language-specific handler
/// 4. The language will automatically appear in help text, wizard, and all other places
///
/// Usage:
///   import languages;
///   import languages.registry;
///   
///   // Query supported languages
///   auto supported = getSupportedLanguageNames();
///   
///   // Create language handler
///   auto handler = LanguageFactory.create("python");
///   auto deps = handler.analyzeDependencies(sourceFile);
///   BuildContext context;
///   context.target = target;
///   context.config = config;
///   context.services = services;  // IServiceContainer (DI)
///   handler.buildWithContext(context);

public import languages.base.base;
public import languages.base.mixins;
public import languages.dynamic;  // Universal Language Abstraction
public import languages.scripting.python;
public import languages.web;
public import languages.scripting.go;
public import languages.compiled.rust;
public import languages.compiled.d;
public import languages.jvm;
public import languages.compiled.cpp;
public import languages.dotnet;
public import languages.scripting.ruby;
public import languages.scripting.perl;
public import languages.scripting.php;
public import languages.scripting.r;
public import languages.compiled.swift;
public import languages.scripting.elixir;
public import languages.scripting.gleam;
public import languages.scripting.lua;
public import languages.compiled.nim;
public import languages.compiled.zig;
public import languages.compiled.haskell;
public import languages.wasm;  // WebAssembly/WASI

