module infrastructure.parsing.treesitter;

/// Tree-sitter integration for universal AST parsing
/// 
/// Provides grammar-based AST parsing for 20+ languages using tree-sitter.
/// Enables symbol-level incremental compilation across all supported languages.
/// 
/// Features:
///   - Incremental parsing using tree-sitter's edit API (10-100x faster re-parse)
///   - Parse tree caching for watch mode performance
///   - Symbol extraction with visibility and dependency tracking
/// 
/// Usage:
///     import infrastructure.parsing.treesitter;
///     
///     // Register tree-sitter parsers (call during initialization)
///     registerTreeSitterParsers();
///     
///     // Parse with incremental edits (watch mode)
///     auto edits = [TextEdit.fromBytes(0, 10, 15, oldContent)];
///     parser.parseContentWithEdits(newContent, path, edits);

public import infrastructure.parsing.treesitter.bindings;
public import infrastructure.parsing.treesitter.config;
public import infrastructure.parsing.treesitter.parser;
public import infrastructure.parsing.treesitter.registry;
public import infrastructure.parsing.treesitter.loader;
public import infrastructure.parsing.treesitter.deps;
public import infrastructure.parsing.treesitter.incremental;
public import infrastructure.parsing.treesitter.adapter;

