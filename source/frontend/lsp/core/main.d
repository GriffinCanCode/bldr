module frontend.lsp.core.main;

import frontend.lsp.core.server;
import infrastructure.utils.logging;

/// Entry point for the standalone LSP server binary
/// This is invoked automatically by VS Code, not by users
void main()
{
    // Initialize logger in silent mode (LSP uses stdio for protocol)
    Logger.initialize();
    Logger.setVerbose(false);
    
    // Run the LSP server
    auto server = new LSPServer();
    server.start();
}

