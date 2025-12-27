module infrastructure.analysis.ast.parser;

import std.algorithm;
import std.array;
import engine.caching.incremental.ast_dependency;
import infrastructure.errors;

/// Language-agnostic AST parser interface
/// Implementations parse source code and extract symbol-level information
interface IASTParser
{
    /// Parse a source file and extract its AST representation
    /// Returns FileAST with all symbols and their metadata
    BuildResult!FileAST parseFile(string filePath) @system;
    
    /// Parse source code content (without file IO)
    BuildResult!FileAST parseContent(string content, string filePath) @system;
    
    /// Get the file extensions this parser handles
    string[] supportedExtensions() @safe const;
    
    /// Get parser name for logging
    string name() @safe const;
    
    /// Quick check if this parser can handle a file
    final bool canParse(string filePath) @safe const
    {
        import std.path : extension;
        auto ext = extension(filePath);
        return supportedExtensions().canFind(ext);
    }
}

/// Base AST parser with common functionality
abstract class BaseASTParser : IASTParser
{
    protected string[] extensions;
    protected string parserName;
    
    this(string name, string[] extensions) @safe
    {
        this.parserName = name;
        this.extensions = extensions;
    }
    
    override string[] supportedExtensions() @safe const
    {
        return extensions.dup;
    }
    
    override string name() @safe const
    {
        return parserName;
    }
    
    /// Helper: Create symbol from basic info
    protected ASTSymbol makeSymbol(
        string name,
        SymbolType type,
        size_t startLine,
        size_t endLine,
        string signature = ""
    ) @safe
    {
        ASTSymbol symbol;
        symbol.name = name;
        symbol.type = type;
        symbol.startLine = startLine;
        symbol.endLine = endLine;
        symbol.signature = signature;
        symbol.isPublic = true; // Default to public
        return symbol;
    }
    
    /// Helper: Hash symbol content from source lines
    protected string hashSymbolContent(string[] lines, size_t startLine, size_t endLine) @system
    {
        import infrastructure.utils.files.hash : FastHash;
        
        if (startLine > lines.length || endLine > lines.length || startLine > endLine)
            return "";
        
        auto content = lines[startLine-1..endLine].join("\n");
        return FastHash.hashString(content);
    }
}

/// AST parser registry
/// Manages available parsers and selects appropriate one for files
final class ASTParserRegistry
{
    private static ASTParserRegistry instance_;
    private IASTParser[string] parsersByExt;  // Extension -> Parser
    private IASTParser[] allParsers;
    
    private this() @safe
    {
        // Singleton
    }
    
    static ASTParserRegistry instance() @trusted
    {
        if (instance_ is null)
            instance_ = new ASTParserRegistry();
        return instance_;
    }
    
    /// Register a parser
    void registerParser(IASTParser parser) @safe
    {
        allParsers ~= parser;
        
        foreach (ext; parser.supportedExtensions())
            parsersByExt[ext] = parser;
    }
    
    /// Get parser for a file
    BuildResult!IASTParser getParser(string filePath) @system
    {
        import std.path : extension;
        
        auto ext = extension(filePath);
        auto parser = ext in parsersByExt;
        
        if (parser is null)
        {
            return BuildResult!IASTParser.err(
                Errors.generic("No AST parser registered for: " ~ ext, Language.UnsupportedLanguage)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
        
        return BuildResult!IASTParser.ok(*parser);
    }
    
    /// Check if we can parse a file
    bool canParse(string filePath) @safe
    {
        import std.path : extension;
        auto ext = extension(filePath);
        return (ext in parsersByExt) !is null;
    }
    
    /// Get all registered parsers
    IASTParser[] getParsers() @safe
    {
        return allParsers.dup;
    }
}

/// Initialize all AST parsers
/// Call this at startup to register language-specific parsers
void initializeASTParsers() @system
{
    auto registry = ASTParserRegistry.instance();
    
    // Register tree-sitter parsers for all supported languages
    // Note: Requires tree-sitter grammar libraries to be available
    // Configs are loaded from JSON files in source/infrastructure/parsing/configs/
    try {
        import infrastructure.parsing.treesitter : registerTreeSitterParsers;
        registerTreeSitterParsers();
    } catch (Exception e) {
        import infrastructure.utils.logging;
        structuredLog.warning("treesitter_parsers_not_fully_available_").field("detail", "Tree-sitter parsers not fully available: " ~ e.msg).emit();
        structuredLog.info("falling_back_to_filelevel_incremental_co").emit();
        // Not fatal - AST-level optimization is optional
        // File-level incremental compilation still works
    }
}

