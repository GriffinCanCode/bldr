/**
 * LSP Package - Language Server Protocol Implementation
 * 
 * This package provides comprehensive Language Server Protocol support for Builder,
 * enabling IDE features like code completion, go-to-definition, hover information,
 * and more for Builderfile editing.
 * 
 * ## Architecture
 * 
 * The LSP implementation uses an async message loop for non-blocking IO:
 * 
 * ```
 * StdioReader -> MessageQueue -> AsyncMessageLoop -> MessageDispatcher -> Handlers
 *                                       |
 *                                       v
 *                                  StdioWriter
 * ```
 * 
 * ### Core (`frontend.lsp.core`)
 * - **transport**: Async message queue, StdioReader/Writer threads
 * - **dispatch**: Message routing and handler registration
 * - **server**: LSP server orchestration (JSON-RPC 2.0 protocol)
 * - **protocol**: LSP protocol types and structures
 * - **main**: Entry point for the standalone LSP server binary
 * 
 * ### Workspace (`frontend.lsp.workspace`)
 * - **workspace**: Document and workspace state management
 * - **index**: Fast symbol indexing for lookups and cross-references
 * - **analysis**: Semantic analysis and validation
 * 
 * ### Providers (`frontend.lsp.providers`)
 * - **completion**: Code completion suggestions
 * - **hover**: Rich hover information with types and documentation
 * - **definition**: Go-to-definition navigation
 * - **references**: Find all references to symbols
 * - **rename**: Workspace-wide symbol renaming
 * - **symbols**: Document outline and symbol navigation
 * 
 * ## Usage
 * 
 * The LSP server is typically invoked automatically by editor extensions
 * (e.g., VS Code) and communicates via stdin/stdout using the LSP protocol.
 * 
 * For manual testing or integration:
 * ```d
 * import frontend.lsp;
 * 
 * void main()
 * {
 *     auto server = new LSPServer();
 *     server.start();  // Async message loop
 * }
 * ```
 */
module frontend.lsp;

// Re-export all submodules for convenience
public import frontend.lsp.core;
public import frontend.lsp.workspace;
public import frontend.lsp.providers;

