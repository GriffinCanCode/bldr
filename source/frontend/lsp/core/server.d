module frontend.lsp.core.server;

import std.json;
import std.stdio;
import std.conv;
import std.string;
import std.algorithm;
import std.array;
import std.exception;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import frontend.lsp.providers.completion;
import frontend.lsp.providers.hover;
import frontend.lsp.providers.definition;
import frontend.lsp.providers.references;
import frontend.lsp.providers.rename;
import frontend.lsp.providers.symbols;
import frontend.lsp.providers.graph;
import infrastructure.utils.logging.logger;

/// LSP Server implementation
/// Handles JSON-RPC 2.0 protocol over stdio
class LSPServer
{
    private WorkspaceManager workspace;
    private CompletionProvider completionProvider;
    private HoverProvider hoverProvider;
    private DefinitionProvider definitionProvider;
    private ReferencesProvider referencesProvider;
    private RenameProvider renameProvider;
    private SymbolsProvider symbolsProvider;
    private GraphProvider graphProvider;
    private bool running;
    private string rootUri;
    
    this()
    {
        Logger.info("Builder LSP Server starting...");
    }
    
    /// Start the LSP server (stdio transport)
    void start()
    {
        running = true;
        
        while (running)
        {
            try
            {
                auto message = readMessage();
                if (message.length == 0)
                    break;
                
                handleMessage(message);
            }
            catch (Exception e)
            {
                Logger.error("Error handling message: " ~ e.msg);
                // Continue running even on error
            }
        }
        
        Logger.info("Builder LSP Server stopped");
    }
    
    /// Read JSON-RPC message from stdin
    private string readMessage()
    {
        // Read headers
        int contentLength = 0;
        string line;
        
        while ((line = readln()) !is null)
        {
            line = line.strip();
            if (line.length == 0)
                break; // End of headers
            
            if (line.startsWith("Content-Length: "))
            {
                contentLength = line["Content-Length: ".length .. $].strip().to!int;
            }
        }
        
        if (contentLength == 0)
            return "";
        
        // Read content
        char[] buffer = new char[contentLength];
        stdin.rawRead(buffer);
        
        return cast(string)buffer;
    }
    
    /// Write JSON-RPC message to stdout
    private void writeMessage(string content)
    {
        auto output_ = stdout.lockingTextWriter();
        output_.put("Content-Length: ");
        output_.put(content.length.to!string);
        output_.put("\r\n\r\n");
        output_.put(content);
        stdout.flush();
    }
    
    /// Handle incoming JSON-RPC message
    private void handleMessage(string content)
    {
        auto json = parseJSON(content);
        
        // Check if it's a request or notification
        if ("id" in json)
        {
            // Request - needs response
            handleRequest(json);
        }
        else
        {
            // Notification - no response
            handleNotification(json);
        }
    }
    
    /// Handle JSON-RPC request
    private void handleRequest(JSONValue json)
    {
        auto method = json["method"].str;
        auto id = json["id"];
        
        Logger.debugLog("Request: " ~ method);
        
        try
        {
            JSONValue result;
            
            switch (method)
            {
                case "initialize":
                    result = handleInitialize(json["params"]);
                    break;
                
                case "shutdown":
                    result = handleShutdown();
                    break;
                
                case "textDocument/completion":
                    result = handleCompletion(json["params"]);
                    break;
                
                case "textDocument/hover":
                    result = handleHover(json["params"]);
                    break;
                
                case "textDocument/definition":
                    result = handleDefinition(json["params"]);
                    break;
                
                case "textDocument/references":
                    result = handleReferences(json["params"]);
                    break;
                
                case "textDocument/rename":
                    result = handleRename(json["params"]);
                    break;
                
                case "textDocument/documentSymbol":
                    result = handleDocumentSymbol(json["params"]);
                    break;
                
                case "workspace/executeCommand":
                    result = handleExecuteCommand(json["params"]);
                    break;
                
                default:
                    Logger.warning("Unhandled request: " ~ method);
                    sendError(id, -32601, "Method not found: " ~ method);
                    return;
            }
            
            sendResponse(id, result);
        }
        catch (Exception e)
        {
            Logger.error("Error handling request: " ~ e.msg);
            sendError(id, -32603, "Internal error: " ~ e.msg);
        }
    }
    
    /// Handle JSON-RPC notification
    private void handleNotification(JSONValue json)
    {
        auto method = json["method"].str;
        
        Logger.debugLog("Notification: " ~ method);
        
        try
        {
            switch (method)
            {
                case "initialized":
                    // Client initialized
                    Logger.info("Client initialized");
                    break;
                
                case "exit":
                    running = false;
                    break;
                
                case "textDocument/didOpen":
                    handleDidOpen(json["params"]);
                    break;
                
                case "textDocument/didChange":
                    handleDidChange(json["params"]);
                    break;
                
                case "textDocument/didClose":
                    handleDidClose(json["params"]);
                    break;
                
                case "textDocument/didSave":
                    // Refresh diagnostics on save
                    if ("params" in json && "textDocument" in json["params"])
                    {
                        auto uri = json["params"]["textDocument"]["uri"].str;
                        publishDiagnostics(uri);
                    }
                    break;
                
                default:
                    Logger.debugLog("Unhandled notification: " ~ method);
                    break;
            }
        }
        catch (Exception e)
        {
            Logger.error("Error handling notification: " ~ e.msg);
        }
    }
    
    /// Initialize LSP server
    private JSONValue handleInitialize(JSONValue params)
    {
        auto initParams = InitializeParams.fromJSON(params);
        rootUri = initParams.rootUri;
        
        // Create workspace manager
        workspace = new WorkspaceManager(rootUri);
        
        // Create providers
        completionProvider = CompletionProvider(workspace);
        hoverProvider = HoverProvider(workspace);
        definitionProvider = DefinitionProvider(workspace);
        referencesProvider = ReferencesProvider(workspace);
        renameProvider = RenameProvider(workspace);
        symbolsProvider = SymbolsProvider(workspace);
        
        // Create graph provider with workspace cache directory
        string cacheDir = uriToPath(rootUri) ~ "/.builder-cache";
        graphProvider = GraphProvider(workspace, cacheDir);
        
        Logger.info("Workspace root: " ~ rootUri);
        if (graphProvider.hasGraph)
            Logger.info("Graph provider initialized with build graph awareness");
        
        // Return capabilities
        InitializeResult result;
        return result.toJSON();
    }
    
    /// Shutdown server
    private JSONValue handleShutdown()
    {
        Logger.info("Shutting down...");
        return JSONValue(null);
    }
    
    /// Handle completion request
    private JSONValue handleCompletion(JSONValue params)
    {
        auto completionParams = CompletionParams.fromJSON(params);
        auto items = completionProvider.provideCompletion(
            completionParams.textDocument.uri,
            completionParams.position
        );
        
        JSONValue[] itemsJson;
        foreach (item; items)
        {
            itemsJson ~= item.toJSON();
        }
        
        return JSONValue(itemsJson);
    }
    
    /// Handle hover request
    private JSONValue handleHover(JSONValue params)
    {
        auto hoverParams = TextDocumentPositionParams.fromJSON(params);
        auto hover = hoverProvider.provideHover(
            hoverParams.textDocument.uri,
            hoverParams.position
        );
        
        if (hover is null)
            return JSONValue(null);
        
        return hover.toJSON();
    }
    
    /// Handle definition request
    private JSONValue handleDefinition(JSONValue params)
    {
        auto defParams = TextDocumentPositionParams.fromJSON(params);
        auto location = definitionProvider.provideDefinition(
            defParams.textDocument.uri,
            defParams.position
        );
        
        if (location is null)
            return JSONValue(null);
        
        return location.toJSON();
    }
    
    /// Handle references request
    private JSONValue handleReferences(JSONValue params)
    {
        auto refParams = TextDocumentPositionParams.fromJSON(params);
        bool includeDeclaration = true;
        if ("context" in params && "includeDeclaration" in params["context"])
        {
            includeDeclaration = params["context"]["includeDeclaration"].boolean;
        }
        
        auto locations = referencesProvider.provideReferences(
            refParams.textDocument.uri,
            refParams.position,
            includeDeclaration
        );
        
        JSONValue[] locsJson;
        foreach (loc; locations)
        {
            locsJson ~= loc.toJSON();
        }
        
        return JSONValue(locsJson);
    }
    
    /// Handle rename request
    private JSONValue handleRename(JSONValue params)
    {
        auto renameParams = RenameParams.fromJSON(params);
        auto edit = renameProvider.provideRename(
            renameParams.textDocument.uri,
            renameParams.position,
            renameParams.newName
        );
        
        if (edit is null)
            return JSONValue(null);
        
        return edit.toJSON();
    }
    
    /// Handle document symbol request
    private JSONValue handleDocumentSymbol(JSONValue params)
    {
        auto docParams = TextDocumentIdentifier.fromJSON(params["textDocument"]);
        auto symbols = symbolsProvider.provideDocumentSymbols(docParams.uri);
        
        JSONValue[] symbolsJson;
        foreach (sym; symbols)
        {
            symbolsJson ~= sym.toJSON();
        }
        
        return JSONValue(symbolsJson);
    }
    
    /// Handle workspace/executeCommand request
    private JSONValue handleExecuteCommand(JSONValue params)
    {
        auto cmdParams = ExecuteCommandParams.fromJSON(params);
        
        Logger.debugLog("Execute command: " ~ cmdParams.command);
        
        // Parse command and delegate to graph provider
        switch (cmdParams.command)
        {
            case "builder.goToDependency":
                return graphProvider.executeCommand(GraphCommand.GoToDependency, cmdParams.arguments);
                
            case "builder.findReverseDependencies":
                return graphProvider.executeCommand(GraphCommand.FindReverseDependencies, cmdParams.arguments);
                
            case "builder.showDependencyTree":
                return graphProvider.executeCommand(GraphCommand.ShowDependencyTree, cmdParams.arguments);
                
            case "builder.showImpactAnalysis":
                return graphProvider.executeCommand(GraphCommand.ShowImpactAnalysis, cmdParams.arguments);
                
            default:
                Logger.warning("Unknown command: " ~ cmdParams.command);
                JSONValue error;
                error["error"] = "Unknown command: " ~ cmdParams.command;
                return error;
        }
    }
    
    /// Handle didOpen notification
    private void handleDidOpen(JSONValue params)
    {
        auto openParams = DidOpenTextDocumentParams.fromJSON(params);
        workspace.openDocument(
            openParams.textDocument.uri,
            openParams.textDocument.text,
            openParams.textDocument.version_
        );
        
        // Publish diagnostics
        publishDiagnostics(openParams.textDocument.uri);
    }
    
    /// Handle didChange notification
    private void handleDidChange(JSONValue params)
    {
        auto changeParams = DidChangeTextDocumentParams.fromJSON(params);
        
        // For full sync, just take the last change
        if (changeParams.contentChanges.length > 0)
        {
            auto lastChange = changeParams.contentChanges[$ - 1];
            workspace.updateDocument(
                changeParams.textDocument.uri,
                lastChange.text,
                changeParams.textDocument.version_
            );
            
            // Publish diagnostics
            publishDiagnostics(changeParams.textDocument.uri);
        }
    }
    
    /// Handle didClose notification
    private void handleDidClose(JSONValue params)
    {
        auto closeParams = DidCloseTextDocumentParams.fromJSON(params);
        workspace.closeDocument(closeParams.textDocument.uri);
    }
    
    /// Publish diagnostics for a document
    private void publishDiagnostics(string uri)
    {
        auto diagnostics = workspace.getDiagnostics(uri);
        
        JSONValue notification;
        notification["jsonrpc"] = "2.0";
        notification["method"] = "textDocument/publishDiagnostics";
        
        JSONValue paramsJson;
        paramsJson["uri"] = uri;
        
        JSONValue[] diagsJson;
        foreach (diag; diagnostics)
        {
            diagsJson ~= diag.toJSON();
        }
        paramsJson["diagnostics"] = JSONValue(diagsJson);
        
        notification["params"] = paramsJson;
        
        writeMessage(notification.toString());
    }
    
    /// Send JSON-RPC response
    private void sendResponse(JSONValue id, JSONValue result)
    {
        JSONValue response;
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        response["result"] = result;
        
        writeMessage(response.toString());
    }
    
    /// Send JSON-RPC error
    private void sendError(JSONValue id, int code, string message)
    {
        JSONValue response;
        response["jsonrpc"] = "2.0";
        response["id"] = id;
        
        JSONValue error;
        error["code"] = code;
        error["message"] = message;
        response["error"] = error;
        
        writeMessage(response.toString());
    }
    
    /// Convert file:// URI to filesystem path
    private string uriToPath(string uri) const
    {
        if (uri.startsWith("file://"))
            return uri[7 .. $];
        return uri;
    }
}

/// Main entry point for LSP server
void runLSPServer()
{
    auto server = new LSPServer();
    server.start();
}

