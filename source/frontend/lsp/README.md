# Builder Language Server Protocol (LSP) Implementation

This directory contains the complete Language Server Protocol implementation for Builder, providing rich IDE features for Builderfile editing.

## 📁 Directory Structure

```
lsp/
├── core/              # Core LSP server and protocol
│   ├── server.d       # LSP server with async message loop
│   ├── transport.d    # Async message queue and stdio threads
│   ├── dispatch.d     # Message routing and handler registration
│   ├── protocol.d     # LSP protocol types and structures
│   ├── main.d         # Entry point for standalone server
│   └── package.d      # Module barrel export
│
├── workspace/         # Workspace and document management
│   ├── workspace.d    # Document state and workspace manager
│   ├── index.d        # Fast symbol indexing and lookups
│   ├── analysis.d     # Semantic analysis and validation
│   └── package.d      # Module barrel export
│
├── providers/         # LSP feature providers
│   ├── completion.d   # Code completion (fields, values, targets)
│   ├── hover.d        # Hover information with types and docs
│   ├── definition.d   # Go-to-definition navigation
│   ├── references.d   # Find all references
│   ├── rename.d       # Symbol renaming
│   ├── symbols.d      # Document symbols and outline
│   └── package.d      # Module barrel export
│
├── package.d          # Root module barrel export
└── README.md          # This file
```

## 🏗️ Architecture

### Core Module (`frontend.lsp.core`)

The core module handles the fundamental LSP server infrastructure using an async message loop:

```
┌─────────────┐    ┌──────────────┐    ┌───────────────┐    ┌────────────────┐
│ StdioReader │───>│ MessageQueue │───>│ AsyncMsgLoop  │───>│ MessageDispatch│
│   (thread)  │    │  (bounded)   │    │  (consumer)   │    │   (routing)    │
└─────────────┘    └──────────────┘    └───────────────┘    └────────────────┘
                                               │
                                               v
                                       ┌─────────────┐
                                       │ StdioWriter │
                                       │ (responses) │
                                       └─────────────┘
```

- **transport.d**: Async message queue and stdio threading
  - `MessageQueue`: Bounded, thread-safe queue with condition variables
  - `StdioReader`: Background thread reading JSON-RPC from stdin
  - `StdioWriter`: Thread-safe mutex-protected stdout writes
  - `AsyncTransport`: Combines reader, writer, and queue

- **dispatch.d**: Message routing and handler registration
  - `MessageDispatcher`: Routes messages to registered handlers
  - `AsyncMessageLoop`: Consumer loop processing queued messages
  - Separates routing from business logic for testability

- **server.d**: LSP server orchestration
  - Handler registration for requests and notifications
  - Provider coordination and lifecycle management
  - Uses async infrastructure for non-blocking operation

- **protocol.d**: Defines all LSP protocol types
  - Position, Range, Location
  - Diagnostic, CompletionItem, Hover
  - TextDocumentIdentifier, VersionedTextDocumentIdentifier
  - InitializeParams, InitializeResult, ServerCapabilities

- **main.d**: Entry point for the standalone LSP server binary
  - Invoked automatically by editor extensions
  - Sets up logging and starts the server

### Workspace Module (`frontend.lsp.workspace`)

The workspace module manages document state and provides efficient querying:

- **workspace.d**: WorkspaceManager class
  - Tracks open documents and their versions
  - Parses Builderfiles into ASTs
  - Maintains diagnostics (syntax and semantic errors)
  - Provides query methods for document content

- **index.d**: Fast symbol indexing
  - O(1) lookups for definitions and references
  - Cross-document symbol tracking
  - Efficient incremental updates

- **analysis.d**: Semantic analyzer
  - Validates target dependencies
  - Detects cyclic dependencies
  - Type-specific validation rules
  - Deep validation beyond syntax checking

### Providers Module (`frontend.lsp.providers`)

The providers module implements LSP feature capabilities:

- **completion.d**: Code completion provider
  - Context-aware suggestions (field names, type values, languages)
  - Target dependency completion with cross-references
  - Smart templates for common patterns (executable, library, test)

- **hover.d**: Hover information provider
  - Rich markdown-formatted hover content
  - Type information and documentation
  - Field value details

- **definition.d**: Go-to-definition provider
  - Navigate to target definitions
  - Dependency resolution

- **references.d**: Find all references
  - Workspace-wide reference search
  - Include/exclude declaration option

- **rename.d**: Symbol renaming provider
  - Workspace edits for renaming targets
  - Updates all references atomically

- **symbols.d**: Document symbols provider
  - Document outline view
  - Symbol hierarchy (targets and fields)

## 🚀 Usage

### As a Library

```d
import frontend.lsp;

void main()
{
    auto server = new LSPServer();
    server.start();  // Async message loop runs until shutdown
    
    // Or start in background for embedding
    // server.startAsync();
    // ... do other work ...
    // server.stop();
}
```

### With VS Code

The LSP server is automatically invoked by the Builder VS Code extension. The extension is located at:
```
distribution/editors/vscode/
```

### Standalone Testing

Build and run the LSP server:
```bash
# Build the builder-lsp binary
make lsp

# Run manually (communicates via stdin/stdout)
./bin/bldr-lsp
```

## 🔌 LSP Features Supported

| Feature | Status | Description |
|---------|--------|-------------|
| **textDocument/completion** | ✅ | Context-aware code completion |
| **textDocument/hover** | ✅ | Hover information with types |
| **textDocument/definition** | ✅ | Go-to-definition navigation |
| **textDocument/references** | ✅ | Find all references |
| **textDocument/rename** | ✅ | Symbol renaming |
| **textDocument/documentSymbol** | ✅ | Document outline |
| **textDocument/publishDiagnostics** | ✅ | Real-time error checking |
| **textDocument/didOpen** | ✅ | Document lifecycle |
| **textDocument/didChange** | ✅ | Incremental updates |
| **textDocument/didClose** | ✅ | Document cleanup |
| **textDocument/didSave** | ✅ | Save notifications |

## 🧪 Testing

The LSP implementation can be tested in several ways:

1. **Integration tests**: Use `tests/integration/lsp_test.d`
2. **Manual testing**: Use the VS Code extension in development mode
3. **Unit tests**: Test individual providers with mock workspace data

## 📝 Adding New Features

To add a new LSP feature:

1. **Add protocol types** (if needed) to `core/protocol.d`
2. **Create provider** in `providers/` directory
3. **Update server** in `core/server.d` to route requests
4. **Export in package.d** files for proper module visibility
5. **Update capabilities** in `InitializeResult.toJSON()`

Example:
```d
// 1. Add to core/protocol.d
struct MyFeatureParams { ... }

// 2. Create providers/myfeature.d
module frontend.lsp.providers.myfeature;
struct MyFeatureProvider { ... }

// 3. Update core/server.d
import frontend.lsp.providers.myfeature;
private MyFeatureProvider myFeatureProvider;
// Add case in handleRequest()

// 4. Update providers/package.d
public import frontend.lsp.providers.myfeature;
```

## 🔍 Debugging

Enable debug logging:
```d
Logger.setVerbose(true);
```

The LSP server logs to stderr (stdout is reserved for LSP protocol messages).

## 📚 Resources

- [LSP Specification](https://microsoft.github.io/language-server-protocol/)
- [JSON-RPC 2.0](https://www.jsonrpc.org/specification)
- [VS Code Extension API](https://code.visualstudio.com/api)

## 🤝 Contributing

When contributing to the LSP implementation:

1. Follow the existing module structure
2. Keep protocol types in `core/protocol.d`
3. Put feature logic in `providers/`
4. Update all package.d files for new modules
5. Add comprehensive documentation
6. Test with the VS Code extension

## 📄 License

This LSP implementation is part of the Builder project and follows the same license.
