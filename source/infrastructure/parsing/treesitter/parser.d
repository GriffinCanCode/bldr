module infrastructure.parsing.treesitter.parser;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.path;
import std.string;
import std.datetime;
import std.regex;
import engine.caching.incremental.ast_dependency;
import infrastructure.analysis.ast.parser;
import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.incremental;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Universal tree-sitter based AST parser
/// Works with any language that has a tree-sitter grammar
/// Supports incremental parsing for watch mode performance
final class TreeSitterParser : BaseASTParser {
    private const(TSLanguage)* grammar;
    private LanguageConfig config;
    private Regex!char publicNameRegex;
    private Regex!char privateNameRegex;
    private bool incrementalEnabled;
    
    this(const(TSLanguage)* grammar, LanguageConfig config, bool enableIncremental = true) @system {
        super(config.displayName, config.extensions.dup);
        this.grammar = grammar;
        this.config = config;
        this.incrementalEnabled = enableIncremental;
        
        // Compile visibility patterns
        if (!config.visibility.publicNamePattern.empty)
            publicNameRegex = regex(config.visibility.publicNamePattern);
        if (!config.visibility.privateNamePattern.empty)
            privateNameRegex = regex(config.visibility.privateNamePattern);
        
        // Register grammar with incremental cache
        if (enableIncremental)
            incrementalTreeCache().registerGrammar(config.languageId, grammar);
    }
    
    /// Check if incremental parsing is enabled
    bool isIncrementalEnabled() const pure nothrow @nogc { 
        return incrementalEnabled; 
    }
    
    /// Get language ID
    string languageId() const @safe { 
        return config.languageId; 
    }
    
    override BuildResult!FileAST parseFile(string filePath) @system {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!FileAST.err(
                Errors.generic("File not found: " ~ filePath, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        try {
            auto content = readText(filePath);
            return parseContent(content, filePath);
        } catch (Exception e) {
            return BuildResult!FileAST.err(
                Errors.generic("Failed to read file: " ~ filePath ~ " - " ~ e.msg, ErrorCode.FileReadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
    }
    
    override BuildResult!FileAST parseContent(string content, string filePath) @system {
        return parseContentWithEdits(content, filePath, null);
    }
    
    /// Parse content with incremental edits for watch mode performance
    /// When edits are provided and a cached tree exists, uses tree-sitter's
    /// incremental parsing which can be 10-100x faster than full re-parse
    BuildResult!FileAST parseContentWithEdits(
        string content,
        string filePath,
        const TextEdit[] edits
    ) @system {
        try {
            TSNode root;
            
            if (incrementalEnabled) {
                // Use incremental cache for efficient re-parsing
                auto result = incrementalTreeCache().parseIncremental(
                    filePath, content, config.languageId, edits);
                
                if (result.isErr)
                    return BuildResult!FileAST.err(result.unwrapErr());
                
                auto parsed = result.unwrap();
                root = parsed.root();
            } else {
                // Fallback to full parse
                auto parser = Parser(grammar);
                if (!parser.handle())
                    return BuildResult!FileAST.err(
                        Errors.generic("Failed to create parser", ErrorCode.InternalError)
                            .withLocation(__FILE__, __LINE__)
                            .build());
                
                auto treeWrapper = Tree(ts_parser_parse_string(
                    parser.handle(), null, content.ptr, cast(uint)content.length));
                
                if (!treeWrapper.handle())
                    return BuildResult!FileAST.err(
                        Errors.generic("Failed to parse: " ~ filePath, ErrorCode.ParseFailed)
                            .withLocation(__FILE__, __LINE__)
                            .build());
                
                root = treeWrapper.root();
                // Note: treeWrapper owns the tree, will be freed on scope exit
            }
            
            if (ts_node_is_null(root))
                return BuildResult!FileAST.err(
                    Errors.generic("Invalid parse tree for: " ~ filePath, ErrorCode.ParseFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build());
            
            // Build AST
            FileAST ast;
            ast.filePath = filePath;
            ast.fileHash = FastHash.hashString(content);
            ast.timestamp = Clock.currTime();
            
            // Extract symbols
            ast.symbols = extractSymbols(root, content);
            
            // Extract imports
            ast.includes = extractImports(root, content);
            
            Logger.debugLog("Parsed " ~ filePath ~ ": " ~ 
                          ast.symbols.length.to!string ~ " symbols, " ~
                          ast.includes.length.to!string ~ " imports");
            
            return BuildResult!FileAST.ok(ast);
        } catch (Exception e) {
            return BuildResult!FileAST.err(
                Errors.generic("Parse error: " ~ filePath ~ " - " ~ e.msg, ErrorCode.ParseFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
    }
    
    /// Parse file with incremental edits
    BuildResult!FileAST parseFileWithEdits(string filePath, const TextEdit[] edits) @system {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!FileAST.err(
                Errors.generic("File not found: " ~ filePath, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        try {
            auto content = readText(filePath);
            return parseContentWithEdits(content, filePath, edits);
        } catch (Exception e) {
            return BuildResult!FileAST.err(
                Errors.generic("Failed to read file: " ~ filePath ~ " - " ~ e.msg, ErrorCode.FileReadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
    }
    
    /// Invalidate cached parse tree for a file
    void invalidateCache(string filePath) @system {
        if (incrementalEnabled)
            incrementalTreeCache().invalidate([filePath]);
    }
    
    /// Get incremental parsing statistics
    IncrementalTreeCache.Stats getIncrementalStats() @system {
        return incrementalTreeCache().getStats();
    }
    
    /// Extract all symbols from the tree
    private ASTSymbol[] extractSymbols(TSNode root, string content) @system {
        ASTSymbol[] symbols;
        auto lines = content.split("\n");
        
        // Use cursor for efficient traversal
        auto cursor = Cursor(root);
        extractSymbolsRecursive(*cursor.handle(), content, lines, symbols);
        
        return symbols;
    }
    
    /// Recursively extract symbols from tree
    private void extractSymbolsRecursive(
        ref TSTreeCursor cursor,
        string content,
        string[] lines,
        ref ASTSymbol[] symbols
    ) @system {
        // Process current node
        auto node = ts_tree_cursor_current_node(&cursor);
        processNode(node, content, lines, symbols);
        
        // Visit children
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            do {
                extractSymbolsRecursive(cursor, content, lines, symbols);
            } while (ts_tree_cursor_goto_next_sibling(&cursor));
            ts_tree_cursor_goto_parent(&cursor);
        }
    }
    
    /// Process a single node and extract symbol if applicable
    private void processNode(
        TSNode node,
        string content,
        string[] lines,
        ref ASTSymbol[] symbols
    ) @system {
        if (ts_node_is_null(node) || !ts_node_is_named(node))
            return;
        
        // Get node type
        auto nodeType = fromStringz(ts_node_type(node)).idup;
        
        // Skip if configured to skip
        if (config.skipNodeTypes.canFind(nodeType))
            return;
        
        // Check if this is a symbol we care about
        auto symbolType = nodeType in config.nodeTypeMap;
        if (!symbolType)
            return;
        
        // Extract symbol info
        ASTSymbol symbol;
        symbol.type = *symbolType;
        
        // Get location
        auto startPoint = ts_node_start_point(node);
        auto endPoint = ts_node_end_point(node);
        symbol.startLine = cast(size_t)(startPoint.row + 1);
        symbol.endLine = cast(size_t)(endPoint.row + 1);
        
        // Extract name
        symbol.name = extractSymbolName(node, content);
        if (symbol.name.empty)
            return;  // Can't extract name, skip
        
        // Extract signature
        symbol.signature = extractNodeText(node, content).strip;
        
        // Hash content
        if (symbol.startLine > 0 && symbol.endLine <= lines.length)
            symbol.contentHash = hashSymbolContent(lines, symbol.startLine, symbol.endLine);
        
        // Determine visibility
        symbol.isPublic = determineVisibility(node, symbol.name, content);
        
        // Extract dependencies and used types
        symbol.usedTypes = extractUsedTypes(node, content);
        symbol.dependencies = extractDependencies(node, content);
        
        symbols ~= symbol;
    }
    
    /// Extract symbol name from node
    private string extractSymbolName(TSNode node, string content) @system {
        // Try to find name field based on config
        string fieldName = "name";  // Default
        
        // Get name from appropriate field
        auto nameNode = ts_node_child_by_field_name(node, fieldName.ptr, cast(uint)fieldName.length);
        
        if (ts_node_is_null(nameNode)) {
            // Fallback: try first named child
            if (ts_node_named_child_count(node) > 0)
                nameNode = ts_node_named_child(node, 0);
        }
        
        if (ts_node_is_null(nameNode))
            return "";
        
        return extractNodeText(nameNode, content);
    }
    
    /// Extract text content of a node
    private string extractNodeText(TSNode node, string content) @system {
        if (ts_node_is_null(node))
            return "";
        
        auto startByte = ts_node_start_byte(node);
        auto endByte = ts_node_end_byte(node);
        
        if (startByte >= content.length || endByte > content.length || startByte >= endByte)
            return "";
        
        return content[startByte..endByte].idup;
    }
    
    /// Determine if symbol is public
    private bool determineVisibility(TSNode node, string name, string content) @system {
        // Check for explicit modifiers
        foreach (modType; config.visibility.modifierNodeTypes) {
            auto modNode = ts_node_child_by_field_name(node, modType.ptr, cast(uint)modType.length);
            if (!ts_node_is_null(modNode)) {
                auto modText = extractNodeText(modNode, content);
                if (config.visibility.publicModifiers.canFind(modText))
                    return true;
                if (config.visibility.privateModifiers.canFind(modText))
                    return false;
            }
        }
        
        // Check name-based patterns (Python: _private, Go: Uppercase public)
        if (!config.visibility.publicNamePattern.empty && !publicNameRegex.empty) {
            if (!matchFirst(name, publicNameRegex).empty)
                return true;
        }
        if (!config.visibility.privateNamePattern.empty && !privateNameRegex.empty) {
            if (!matchFirst(name, privateNameRegex).empty)
                return false;
        }
        
        return config.visibility.defaultPublic;
    }
    
    /// Extract types used in this symbol
    private string[] extractUsedTypes(TSNode node, string content) @system {
        string[] types;
        
        // Recursively find type usage nodes
        auto cursor = Cursor(node);
        extractTypesRecursive(*cursor.handle(), content, types);
        
        return types;
    }
    
    private void extractTypesRecursive(
        ref TSTreeCursor cursor,
        string content,
        ref string[] types
    ) @system {
        auto node = ts_tree_cursor_current_node(&cursor);
        auto nodeType = fromStringz(ts_node_type(node)).idup;
        
        if (config.dependencies.typeUsageNodeTypes.canFind(nodeType)) {
            auto typeName = extractNodeText(node, content);
            if (!typeName.empty && !types.canFind(typeName))
                types ~= typeName;
        }
        
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            do {
                extractTypesRecursive(cursor, content, types);
            } while (ts_tree_cursor_goto_next_sibling(&cursor));
            ts_tree_cursor_goto_parent(&cursor);
        }
    }
    
    /// Extract symbol dependencies
    private string[] extractDependencies(TSNode node, string content) @system {
        // For now, just return used types as dependencies
        // More sophisticated analysis can be added later
        return extractUsedTypes(node, content);
    }
    
    /// Extract imports/includes
    private string[] extractImports(TSNode root, string content) @system {
        string[] imports;
        
        auto cursor = Cursor(root);
        extractImportsRecursive(*cursor.handle(), content, imports);
        
        return imports;
    }
    
    private void extractImportsRecursive(
        ref TSTreeCursor cursor,
        string content,
        ref string[] imports
    ) @system {
        auto node = ts_tree_cursor_current_node(&cursor);
        auto nodeType = fromStringz(ts_node_type(node)).idup;
        
        if (config.importNodeTypes.canFind(nodeType)) {
            // Extract import path based on language-specific patterns
            foreach (pattern, fieldName; config.dependencies.importPatterns) {
                if (nodeType == pattern) {
                    auto importNode = ts_node_child_by_field_name(
                        node, fieldName.ptr, cast(uint)fieldName.length);
                    if (!ts_node_is_null(importNode)) {
                        auto importPath = extractNodeText(importNode, content);
                        if (!importPath.empty && !imports.canFind(importPath))
                            imports ~= importPath;
                    }
                }
            }
        }
        
        if (ts_tree_cursor_goto_first_child(&cursor)) {
            do {
                extractImportsRecursive(cursor, content, imports);
            } while (ts_tree_cursor_goto_next_sibling(&cursor));
            ts_tree_cursor_goto_parent(&cursor);
        }
    }
}

/// Helper: Convert C string to D string
private string fromStringz(const(char)* s) @system nothrow {
    if (!s)
        return "";
    try {
        import core.stdc.string : strlen;
        auto len = strlen(s);
        return cast(string)s[0..len].idup;
    } catch (Exception) {
        return "";
    }
}

