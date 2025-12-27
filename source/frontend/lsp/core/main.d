module frontend.lsp.core.main;

import frontend.lsp.core.server;

/// Entry point for the standalone LSP server binary
/// This is invoked automatically by VS Code, not by users
void main()
{
    // Run the LSP server (LSP uses stdio for protocol, logging auto-initialized)
    auto server = new LSPServer();
    server.start();
}

