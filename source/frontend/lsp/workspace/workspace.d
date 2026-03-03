module frontend.lsp.workspace.workspace;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv : to;
import std.datetime;
import std.range : empty;
import std.uni : toLower;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.index;
import frontend.lsp.workspace.analysis;
import infrastructure.config.workspace.ast : BuildFile, TargetDeclStmt, Field, Expr, ASTLocation = Location;
import infrastructure.config.parsing.lexer : Token;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Document state in workspace
struct Document
{
    string uri;
    string text;
    int version_;
    BuildFile ast;
    Token[] tokens;
    Diagnostic[] diagnostics;
    SysTime lastModified;
}

/// Workspace manager for LSP
/// Tracks open documents, ASTs, and provides query operations
class WorkspaceManager
{
    private Document[string] documents;
    private string rootUri;
    private Index index;
    private LSPSemanticAnalyzer analyzer;
    
    this(string rootUri)
    {
        this.rootUri = rootUri;
        this.index = Index();
        this.analyzer = LSPSemanticAnalyzer(&this.index);
        
        // Scan workspace for all Builderfiles on initialization
        scanWorkspace();
    }
    
    /// Scan workspace for all Builderfiles and index them
    void scanWorkspace()
    {
        string root = uriToPath(rootUri);
        if (root.length == 0 || !exists(root) || !isDir(root))
        {
            structuredLog.warning("cannot_scan_workspace_invalid_root_").field("detail", "Cannot scan workspace: invalid root " ~ root).emit();
            return;
        }
        
        structuredLog.info("scanning_workspace_for_builderfiles_").field("detail", "Scanning workspace for Builderfiles: " ~ root).emit();
        size_t fileCount = 0;
        
        try
        {
            foreach (entry; dirEntries(root, SpanMode.depth))
            {
                if (!entry.isFile) continue;
                
                string name = baseName(entry.name);
                if (name == "Builderfile" || name == "Builderspace" || 
                    name.endsWith(".builder") || name.endsWith(".builderfile"))
                {
                    indexFileFromDisk(entry.name);
                    fileCount++;
                }
            }
        }
        catch (FileException e)
        {
            structuredLog.warning("error_scanning_workspace_").field("detail", "Error scanning workspace: " ~ e.msg).emit();
        }
        
        structuredLog.info("indexed_").field("detail", "Indexed " ~ fileCount.to!string ~ " Builderfile(s), " ~ 
                   index.getAllTargetNames().length.to!string ~ " target(s)").emit();
    }
    
    /// Index a file from disk (not currently open in editor)
    private void indexFileFromDisk(string filePath)
    {
        string uri = pathToUri(filePath);
        
        // Skip if already open (editor version takes precedence)
        if (uri in documents) return;
        
        try
        {
            string content = readText(filePath);
            
            // Parse using unified parser
            import infrastructure.config.parsing.unified : parse;
            string rootPath = uriToPath(rootUri);
            auto parseResult = parse(content, filePath, rootPath, null);
            
            if (parseResult.isOk)
            {
                auto ast = parseResult.unwrap();
                index.indexDocument(uri, ast);
                structuredLog.debug_("indexed_").field("detail", "Indexed: " ~ filePath).emit();
            }
        }
        catch (Exception e)
        {
            structuredLog.debug_("failed_to_index_").field("detail", "Failed to index " ~ filePath ~ ": " ~ e.msg).emit();
        }
    }
    
    /// Get index for direct access
    @property ref Index getIndex() => index;
    
    /// Get workspace root URI
    @property string root() const => rootUri;
    
    /// Get workspace root path (filesystem)
    @property string rootPath() const => uriToPath(rootUri);
    
    /// Open a document
    void openDocument(string uri, string text, int version_)
    {
        Document doc;
        doc.uri = uri;
        doc.text = text;
        doc.version_ = version_;
        doc.lastModified = Clock.currTime;
        
        // Parse document
        parseDocument(doc);
        
        documents[uri] = doc;
        structuredLog.debug_("opened_document_").field("detail", "Opened document: " ~ uri).emit();
    }
    
    /// Update document content
    void updateDocument(string uri, string text, int version_)
    {
        if (uri !in documents)
        {
            // Document not open, open it
            openDocument(uri, text, version_);
            return;
        }
        
        Document* doc = &documents[uri];
        doc.text = text;
        doc.version_ = version_;
        doc.lastModified = Clock.currTime;
        
        // Re-parse document
        parseDocument(*doc);
        
        structuredLog.debug_("updated_document_").field("detail", "Updated document: " ~ uri).emit();
    }
    
    /// Close a document
    void closeDocument(string uri)
    {
        index.removeDocument(uri);
        documents.remove(uri);
        structuredLog.debug_("closed_document_").field("detail", "Closed document: " ~ uri).emit();
    }
    
    /// Get document by URI
    const(Document)* getDocument(string uri) const
    {
        auto doc = uri in documents;
        return doc;
    }
    
    /// Get all documents
    const(Document)[] getAllDocuments() const
    {
        return documents.values;
    }
    
    /// Get diagnostics for a document
    Diagnostic[] getDiagnostics(string uri) const
    {
        auto doc = getDocument(uri);
        if (doc is null)
            return [];
        return doc.diagnostics.dup;
    }
    
    /// Find target at position
    TargetDeclStmt findTargetAtPosition(string uri, Position pos) const
    {
        auto doc = getDocument(uri);
        if (doc is null)
            return null;
        
        // Find target that contains this position
        foreach (target; doc.ast.targets)
        {
            if (target.loc.line <= pos.line + 1)
            {
                // Check if position is within target body
                // (simplified - would need better range tracking)
                return target;
            }
        }
        
        return null;
    }
    
    /// Find field at position
    const(Field)* findFieldAtPosition(string uri, Position pos) const
    {
        auto target = findTargetAtPosition(uri, pos);
        if (target is null)
            return null;
        
        // Find field at this line
        foreach (ref field; target.fields)
        {
            if (field.loc.line == pos.line + 1)
                return &field;
        }
        
        return null;
    }
    
    /// Get all target names in workspace
    string[] getAllTargetNames() const
    {
        return index.getAllTargetNames();
    }
    
    /// Find all references to a target
    Location[] findReferences(string targetName) const
    {
        return index.getReferences(targetName);
    }
    
    /// Find definition of a target
    Location* findDefinition(string targetName) const
        => index.getDefinition(targetName);
    
    /// Get dependencies declared in a target's deps field
    string[] getDeclaredDependencies(string targetName) const
    {
        auto sym = index.getSymbol(targetName);
        return sym !is null ? sym.deps.dup : [];
    }
    
    /// Get targets that depend on a given target (from AST analysis)
    string[] getDeclaredDependents(string targetName) const
    {
        string[] dependents;
        foreach (name; index.getAllTargetNames())
        {
            auto sym = index.getSymbol(name);
            if (sym is null) continue;
            
            foreach (dep; sym.deps)
            {
                auto normalized = normalizeDep(dep);
                if (normalized == targetName)
                {
                    dependents ~= name;
                    break;
                }
            }
        }
        return dependents;
    }
    
    /// Search workspace symbols by query (for Ctrl+T / workspace/symbol)
    SymbolInformation[] searchWorkspaceSymbols(string query) const
    {
        SymbolInformation[] results;
        string lowerQuery = query.toLower();
        
        foreach (name; index.getAllTargetNames())
        {
            // Fuzzy match: query substring in name (case-insensitive)
            if (query.length == 0 || name.toLower().canFind(lowerQuery))
            {
                auto sym = index.getSymbol(name);
                if (sym is null) continue;
                
                SymbolInformation info;
                info.name = name;
                info.kind = LSPSymbolKind.Class;  // Targets are like classes
                info.location = Location(sym.uri, sym.range);
                
                // Container is the relative path from workspace root
                string path = uriToPath(sym.uri);
                string rootPath = uriToPath(rootUri);
                if (path.startsWith(rootPath))
                    info.containerName = path[rootPath.length .. $].stripLeft("/");
                else
                    info.containerName = baseName(path);
                
                results ~= info;
            }
        }
        
        // Sort by relevance: exact prefix matches first, then by name length
        results.sort!((a, b) {
            bool aPrefix = a.name.toLower().startsWith(lowerQuery);
            bool bPrefix = b.name.toLower().startsWith(lowerQuery);
            if (aPrefix != bPrefix) return aPrefix > bPrefix;
            return a.name.length < b.name.length;
        });
        
        return results;
    }
    
    /// Normalize dependency reference for lookup
    /// SIMD-accelerated prefix matching for better performance
    private string normalizeDep(string dep) const @trusted
    {
        import infrastructure.utils.simd.strings : SIMDStrings;
        
        if (SIMDStrings.startsWith(dep, ":"))
            return dep[1 .. $];
        if (SIMDStrings.startsWith(dep, "//"))
        {
            auto colonPos = dep.lastIndexOf(':');
            if (colonPos != -1)
                return dep[colonPos + 1 .. $];
        }
        return dep;
    }
    
    private void parseDocument(ref Document doc)
    {
        // Clear previous diagnostics
        doc.diagnostics = [];
        
        // Parse using unified parser
        import infrastructure.config.parsing.unified : parse;
        
        string filePath = uriToPath(doc.uri);
        string rootPath = uriToPath(rootUri);
        auto parseResult = parse(doc.text, filePath, rootPath, null);
        
        if (parseResult.isErr)
        {
            // Parser error
            auto error = parseResult.unwrapErr();
            doc.diagnostics ~= buildErrorToDiagnostic(error);
            return;
        }
        
        doc.ast = parseResult.unwrap();
        
        // Update index
        index.indexDocument(doc.uri, doc.ast);
        
        // Validate (basic checks)
        validateDocument(doc);
        
        // Semantic analysis
        auto semanticDiags = analyzer.analyze(doc.uri, doc.ast);
        doc.diagnostics ~= semanticDiags;
    }
    
    private void validateDocument(ref Document doc)
    {
        // Check for duplicate target names in same file
        bool[string] targetNames;
        
        foreach (ref target; doc.ast.targets)
        {
            if (target.name in targetNames)
            {
                Diagnostic diag;
                diag.severity = DiagnosticSeverity.Error;
                diag.message = "Duplicate target name: " ~ target.name;
                diag.range = Range(
                    Position(cast(uint)(target.loc.line - 1), 0),
                    Position(cast(uint)(target.loc.line - 1), 100)
                );
                diag.source = "builder-lsp";
                doc.diagnostics ~= diag;
            }
            targetNames[target.name] = true;
            
            // Validate required fields
            if (target.getField("type") is null)
            {
                Diagnostic diag;
                diag.severity = DiagnosticSeverity.Error;
                diag.message = "Missing required field 'type'";
                diag.range = Range(
                    Position(cast(uint)(target.loc.line - 1), 0),
                    Position(cast(uint)(target.loc.line - 1), 100)
                );
                diag.source = "builder-lsp";
                doc.diagnostics ~= diag;
            }
        }
    }
    
    private Diagnostic buildErrorToDiagnostic(BuildError error)
    {
        Diagnostic diag;
        diag.severity = DiagnosticSeverity.Error;
        diag.message = error.message;
        diag.source = "builder-lsp";
        
        // Try to get line information
        import infrastructure.errors.types.types : ParseError;
        if (auto parseError = cast(ParseError)error)
        {
            if (parseError.line > 0)
            {
                diag.range = Range(
                    Position(cast(uint)(parseError.line - 1), cast(uint)(parseError.column > 0 ? parseError.column - 1 : 0)),
                    Position(cast(uint)(parseError.line - 1), 100)
                );
            }
            else
            {
                diag.range = Range(Position(0, 0), Position(0, 100));
            }
        }
        else
        {
            diag.range = Range(Position(0, 0), Position(0, 100));
        }
        
        return diag;
    }
    
    private string uriToPath(string uri) const
    {
        if (uri.startsWith("file://"))
            return uri[7 .. $];
        return uri;
    }
    
    private string pathToUri(string path) const
    {
        return "file://" ~ path;
    }
}

