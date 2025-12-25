module infrastructure.parsing.treesitter.registry;

import std.algorithm;
import std.array;
import std.conv;
import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Registry for tree-sitter language grammars
/// Manages loading and instantiation of language parsers
final class TreeSitterRegistry {
    private static TreeSitterRegistry instance_;
    private GrammarEntry[string] grammars;
    
    private struct GrammarEntry {
        const(TSLanguage)* grammar;
        LanguageConfig config;
        bool loaded;
    }
    
    private this() @safe {
        // Singleton
    }
    
    static TreeSitterRegistry instance() @trusted {
        if (!instance_)
            instance_ = new TreeSitterRegistry();
        return instance_;
    }
    
    /// Register a language grammar
    /// Grammar loading functions should be extern(C) and return const(TSLanguage)*
    void registerGrammar(T)(
        string languageId,
        T grammarLoader,
        LanguageConfig config
    ) @system if (is(typeof(grammarLoader()) == const(TSLanguage)*)) {
        GrammarEntry entry;
        entry.config = config;
        entry.loaded = false;
        entry.grammar = grammarLoader();
        
        // Lazy load - only load grammar when first parser is created
        grammars[languageId] = entry;
        
        Logger.debugLog("Registered tree-sitter grammar: " ~ languageId);
    }
    
    /// Create a parser for a language
    BuildResult!TreeSitterParser createParser(string languageId) @system {
        auto entry = languageId in grammars;
        if (!entry)
            return BuildResult!TreeSitterParser.err(
                new GenericError("No grammar registered for: " ~ languageId,
                               ErrorCode.UnsupportedLanguage));
        
        // Load grammar if not already loaded
        if (!entry.loaded) {
            // Grammar loading would happen here
            // For now, we assume grammar is available
            entry.loaded = true;
        }
        
        if (!entry.grammar)
            return BuildResult!TreeSitterParser.err(
                new GenericError("Failed to load grammar for: " ~ languageId,
                               ErrorCode.InternalError));
        
        auto parser = new TreeSitterParser(entry.grammar, entry.config);
        return BuildResult!TreeSitterParser.ok(parser);
    }
    
    /// Check if a language is supported
    bool hasGrammar(string languageId) const @safe {
        return (languageId in grammars) !is null;
    }
    
    /// Get all supported languages
    string[] supportedLanguages() @system {
        return grammars.keys;
    }
    
    /// Get language config
    LanguageConfig* getConfig(string languageId) @system {
        auto entry = languageId in grammars;
        return entry ? &entry.config : null;
    }
}

/// Initialize tree-sitter parsers and register them
/// Call this after initializeASTParsers() to add tree-sitter support
void registerTreeSitterParsers() @system {
    auto tsRegistry = TreeSitterRegistry.instance();
    auto astRegistry = ASTParserRegistry.instance();
    
    // Check tree-sitter installation
    import infrastructure.parsing.treesitter.deps;
    if (!TreeSitterDeps.isInstalled()) {
        Logger.warning("Tree-sitter library not found - falling back to file-level tracking");
        Logger.debugLog("Run: source/infrastructure/parsing/treesitter/setup.sh to install");
    } else {
        Logger.debugLog("Tree-sitter library found");
    }
    
    // Initialize language configs
    LanguageConfigs.initialize();
    
    // Grammar modules register themselves via shared static this()
    // No need to explicitly import/initialize them here
    
    // Log available configs (even if grammars aren't loaded yet)
    auto available = LanguageConfigs.available();
    Logger.info("Tree-sitter configs available for " ~ 
               available.length.to!string ~ " languages");
    
    // Check which grammars are actually loaded
    auto supportedLangs = tsRegistry.supportedLanguages();
    if (supportedLangs.length > 0) {
        Logger.info("Tree-sitter grammars loaded for: " ~ 
                   supportedLangs.join(", "));
    } else {
        Logger.info("No tree-sitter grammars loaded (using stub implementation)");
        Logger.info("To enable AST parsing, see: source/infrastructure/parsing/treesitter/README.md");
    }
}

/// Grammar loader function type
/// Each language module should provide this
alias GrammarLoader = extern(C) const(TSLanguage)* function() @system nothrow @nogc;

/// Alternative: Non-extern(C) wrapper for grammar loaders
alias GrammarLoaderWrapper = const(TSLanguage)* function() @system nothrow @nogc;

/// Macro for declaring grammar loaders
/// Usage: mixin(DefineGrammarLoader!("python", "tree_sitter_python"));
template DefineGrammarLoader(string langId, string grammarSymbol) {
    enum DefineGrammarLoader = 
        "extern(C) const(TSLanguage)* " ~ grammarSymbol ~ "() @system nothrow @nogc;\n" ~
        "static this() {\n" ~
        "    auto config = LanguageConfigs.get(\"" ~ langId ~ "\");\n" ~
        "    if (config) {\n" ~
        "        TreeSitterRegistry.instance().registerGrammar(\n" ~
        "            \"" ~ langId ~ "\",\n" ~
        "            &" ~ grammarSymbol ~ ",\n" ~
        "            *config\n" ~
        "        );\n" ~
        "    }\n" ~
        "}\n";
}

