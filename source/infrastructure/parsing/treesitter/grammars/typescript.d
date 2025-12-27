module infrastructure.parsing.treesitter.grammars.typescript;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Typescript grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_typescript() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_typescript();
        if (!grammar) {
            structuredLog.debug_("typescript_grammar_not_available_will_us").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("typescript");
        if (!config) {
            structuredLog.warning("typescript_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "typescript",
            &ts_load_typescript,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_typescript_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("typescript_grammar_not_loaded_").field("detail", "Typescript grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Typescript grammar is available
bool isTypescriptGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
