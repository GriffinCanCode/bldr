module infrastructure.parsing.treesitter.grammars;

/// Tree-sitter grammar loaders
/// 
/// This package provides bindings to tree-sitter language grammars.
/// Grammars are loaded dynamically - if a grammar is not available,
/// the system falls back to file-level incremental compilation.
///
/// To add a language:
/// 1. Create <lang>.d module with grammar loader
/// 2. Declare extern(C) grammar function
/// 3. Register in static constructor
/// 4. Import here for automatic loading

// Import all grammar modules
// Each module uses version() to conditionally load if grammar is available
public import infrastructure.parsing.treesitter.grammars.c;
public import infrastructure.parsing.treesitter.grammars.cpp;
public import infrastructure.parsing.treesitter.grammars.python;
public import infrastructure.parsing.treesitter.grammars.java;
public import infrastructure.parsing.treesitter.grammars.javascript;
public import infrastructure.parsing.treesitter.grammars.typescript;
public import infrastructure.parsing.treesitter.grammars.go;
public import infrastructure.parsing.treesitter.grammars.rust;
public import infrastructure.parsing.treesitter.grammars.csharp;
public import infrastructure.parsing.treesitter.grammars.ruby;
public import infrastructure.parsing.treesitter.grammars.php;
public import infrastructure.parsing.treesitter.grammars.swift;
public import infrastructure.parsing.treesitter.grammars.kotlin;
public import infrastructure.parsing.treesitter.grammars.scala;
public import infrastructure.parsing.treesitter.grammars.elixir;
public import infrastructure.parsing.treesitter.grammars.lua;
public import infrastructure.parsing.treesitter.grammars.perl;
public import infrastructure.parsing.treesitter.grammars.r;
public import infrastructure.parsing.treesitter.grammars.haskell;
public import infrastructure.parsing.treesitter.grammars.ocaml;
public import infrastructure.parsing.treesitter.grammars.nim;
public import infrastructure.parsing.treesitter.grammars.zig;
public import infrastructure.parsing.treesitter.grammars.d;
public import infrastructure.parsing.treesitter.grammars.elm;
public import infrastructure.parsing.treesitter.grammars.fsharp;
public import infrastructure.parsing.treesitter.grammars.css;
public import infrastructure.parsing.treesitter.grammars.protobuf;

/// Initialize all available grammars
/// Call this during startup to load grammar modules
void initializeGrammars() @system {
    // Grammars with version() statements will auto-register via shared static this()
    // This function provides explicit initialization point for logging
    
    import infrastructure.utils.logging;
    structuredLog.debug_("grammar_loaders_initialized").emit();
}

