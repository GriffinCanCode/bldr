module languages.compiled;

/// Compiled Languages Package
/// 
/// This package contains handlers for compiled languages including:
///   - C/C++ (modular structure with builders, toolchain, analysis)
///   - D (native language)
///   - Rust (with cargo and rustc support)
///   - Nim
///   - Zig
///   - OCaml (dune, ocamlopt, ocamlc support)
///   - Protocol Buffers (protoc/buf compiler support)
///
/// Note: GPU languages (CUDA, Metal, ROCm) are in languages.gpu package

public import languages.compiled.base;
public import languages.compiled.cpp;
public import languages.compiled.d;
public import languages.compiled.rust;
public import languages.compiled.nim;
public import languages.compiled.zig;
public import languages.compiled.ocaml;
public import languages.compiled.protobuf;
