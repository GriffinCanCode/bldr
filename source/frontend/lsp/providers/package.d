/**
 * LSP Providers Module
 * 
 * This module contains all LSP feature providers:
 * - Completion: Code completion suggestions (fields, values, targets)
 * - Hover: Rich hover information with type and documentation
 * - Definition: Go-to-definition for targets and symbols
 * - References: Find all references to a symbol
 * - Rename: Workspace-wide symbol renaming
 * - Symbols: Document outline and symbol navigation
 * - Graph: Build dependency navigation (Go to Dependency, Find Reverse Dependencies)
 * 
 * Each provider implements a specific LSP capability and operates
 * on the workspace state maintained by the workspace module.
 */
module frontend.lsp.providers;

public import frontend.lsp.providers.completion;
public import frontend.lsp.providers.hover;
public import frontend.lsp.providers.definition;
public import frontend.lsp.providers.references;
public import frontend.lsp.providers.rename;
public import frontend.lsp.providers.symbols;
public import frontend.lsp.providers.graph;

