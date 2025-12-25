module frontend.lsp.core.server;

import std.json;
import std.json : JSONType;
import std.stdio;
import std.conv;
import std.string;
import std.algorithm;
import std.array;
import std.exception;
import frontend.lsp.core.protocol;
import frontend.lsp.core.transport;
import frontend.lsp.core.dispatch;
import frontend.lsp.workspace.workspace;
import frontend.lsp.providers.completion;
import frontend.lsp.providers.hover;
import frontend.lsp.providers.definition;
import frontend.lsp.providers.references;
import frontend.lsp.providers.rename;
import frontend.lsp.providers.symbols;
import frontend.lsp.providers.graph;
import frontend.lsp.providers.codelens;
import infrastructure.utils.logging.logger;

/// LSP Server implementation with async message loop
/// Handles JSON-RPC 2.0 protocol over stdio using async transport
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
    private CodeLensProvider codeLensProvider;
    private string rootUri;
    
    // Async infrastructure
    private AsyncTransport transport;
    private MessageDispatcher dispatcher;
    private AsyncMessageLoop messageLoop;
    
    @system this()
    {
        Logger.info("Builder LSP Server starting...");
        transport = new AsyncTransport();
        dispatcher = new MessageDispatcher();
        messageLoop = new AsyncMessageLoop(transport, dispatcher);
        registerHandlers();
    }
    
    /// Start the LSP server (async message loop)
    @system void start()
    {
        messageLoop.run();
        Logger.info("Builder LSP Server stopped");
    }
    
    /// Start server in background thread
    @system void startAsync() { messageLoop.runAsync(); }
    
    /// Stop server
    @system void stop() { messageLoop.stop(); }
    
    /// Send notification to client
    @system void notify(string method, JSONValue params) { messageLoop.notify(method, params); }
    
    /// Register all request/notification handlers
    private void registerHandlers() @system
    {
        // Requests
        dispatcher.onRequest("initialize", (p) => handleInitialize(p));
        dispatcher.onRequest("shutdown", (_) => handleShutdown());
        dispatcher.onRequest("textDocument/completion", (p) => handleCompletion(p));
        dispatcher.onRequest("textDocument/hover", (p) => handleHover(p));
        dispatcher.onRequest("textDocument/definition", (p) => handleDefinition(p));
        dispatcher.onRequest("textDocument/references", (p) => handleReferences(p));
        dispatcher.onRequest("textDocument/rename", (p) => handleRename(p));
        dispatcher.onRequest("textDocument/documentSymbol", (p) => handleDocumentSymbol(p));
        dispatcher.onRequest("workspace/symbol", (p) => handleWorkspaceSymbol(p));
        dispatcher.onRequest("textDocument/codeLens", (p) => handleCodeLens(p));
        dispatcher.onRequest("codeLens/resolve", (p) => handleCodeLensResolve(p));
        dispatcher.onRequest("workspace/executeCommand", (p) => handleExecuteCommand(p));
        
        // Notifications
        dispatcher.onNotification("initialized", (_) { Logger.info("Client initialized"); });
        dispatcher.onNotification("exit", (_) { stop(); });
        dispatcher.onNotification("textDocument/didOpen", (p) => handleDidOpen(p));
        dispatcher.onNotification("textDocument/didChange", (p) => handleDidChange(p));
        dispatcher.onNotification("textDocument/didClose", (p) => handleDidClose(p));
        dispatcher.onNotification("textDocument/didSave", (p) => handleDidSave(p));
    }
    
    /// Handle didSave notification
    private void handleDidSave(JSONValue params) @system
    {
        if ("textDocument" in params)
            publishDiagnostics(params["textDocument"]["uri"].str);
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
        
        // Create CodeLens provider with graph awareness
        codeLensProvider = CodeLensProvider(workspace, &graphProvider);
        
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
            symbolsJson ~= sym.toJSON();
        
        return JSONValue(symbolsJson);
    }
    
    /// Handle workspace symbol request (Ctrl+T search)
    private JSONValue handleWorkspaceSymbol(JSONValue params)
    {
        auto wsParams = WorkspaceSymbolParams.fromJSON(params);
        auto symbols = workspace.searchWorkspaceSymbols(wsParams.query);
        
        JSONValue[] symbolsJson;
        foreach (ref sym; symbols)
            symbolsJson ~= sym.toJSON();
        
        return JSONValue(symbolsJson);
    }
    
    /// Handle CodeLens request - provides inline dependency visualization
    private JSONValue handleCodeLens(JSONValue params)
    {
        auto lensParams = CodeLensParams.fromJSON(params);
        auto lenses = codeLensProvider.provideCodeLenses(lensParams.textDocument.uri);
        
        JSONValue[] lensesJson;
        foreach (ref lens; lenses)
            lensesJson ~= lens.toJSON();
        
        return JSONValue(lensesJson);
    }
    
    /// Handle CodeLens resolve request
    private JSONValue handleCodeLensResolve(JSONValue params)
    {
        auto lens = CodeLens.fromJSON(params);
        auto resolved = codeLensProvider.resolveCodeLens(lens);
        return resolved.toJSON();
    }
    
    /// Handle workspace/executeCommand request
    private JSONValue handleExecuteCommand(JSONValue params)
    {
        auto cmdParams = ExecuteCommandParams.fromJSON(params);
        
        Logger.debugLog("Execute command: " ~ cmdParams.command);
        
        // Extract args from array if needed
        JSONValue args = cmdParams.arguments;
        if (args.type == JSONType.array && args.array.length > 0)
            args = args.array[0];
        
        // Parse command and delegate to graph provider
        switch (cmdParams.command)
        {
            case "builder.goToDependency":
                return graphProvider.executeCommand(GraphCommand.GoToDependency, args);
                
            case "builder.findReverseDependencies":
                return graphProvider.executeCommand(GraphCommand.FindReverseDependencies, args);
                
            case "builder.showDependencyTree":
                return graphProvider.executeCommand(GraphCommand.ShowDependencyTree, args);
                
            case "builder.showImpactAnalysis":
                return graphProvider.executeCommand(GraphCommand.ShowImpactAnalysis, args);
            
            case "builder.showDependencyGraph":
                return handleShowDependencyGraph(args);
            
            case "builder.navigateToTarget":
                return handleNavigateToTarget(args);
                
            default:
                Logger.warning("Unknown command: " ~ cmdParams.command);
                JSONValue error;
                error["error"] = "Unknown command: " ~ cmdParams.command;
                return error;
        }
    }
    
    /// Handle showDependencyGraph command - builds visual tree
    private JSONValue handleShowDependencyGraph(JSONValue args)
    {
        string targetName;
        if ("targetName" in args)
            targetName = args["targetName"].str;
        else if ("target" in args)
            targetName = args["target"].str;
        
        if (targetName.length == 0)
            return JSONValue(["error": "No target specified"]);
        
        bool isDeps = true;
        if ("mode" in args && args["mode"].str == "dependents")
            isDeps = false;
        
        // Build dependency tree structure
        auto tree = graphProvider.buildDependencyTree(targetName, !isDeps);
        
        JSONValue result;
        result["target"] = targetName;
        result["mode"] = isDeps ? "dependencies" : "dependents";
        result["tree"] = tree.toJSON();
        result["ascii"] = DependencyGraphLens.renderDependencyTree(tree);
        
        return result;
    }
    
    /// Handle navigateToTarget command
    private JSONValue handleNavigateToTarget(JSONValue args)
    {
        string targetName;
        if ("targetName" in args)
            targetName = args["targetName"].str;
        else if ("target" in args)
            targetName = args["target"].str;
        
        if (targetName.length == 0)
            return JSONValue(["error": "No target specified"]);
        
        auto loc = workspace.findDefinition(targetName);
        if (loc is null)
            return JSONValue(["error": "Target not found: " ~ targetName]);
        
        return loc.toJSON();
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
    private void publishDiagnostics(string uri) @system
    {
        if (workspace is null) return;
        
        auto diagnostics = workspace.getDiagnostics(uri);
        
        JSONValue params;
        params["uri"] = uri;
        
        JSONValue[] diagsJson;
        foreach (diag; diagnostics)
            diagsJson ~= diag.toJSON();
        params["diagnostics"] = JSONValue(diagsJson);
        
        notify("textDocument/publishDiagnostics", params);
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

