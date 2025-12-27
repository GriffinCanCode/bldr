module infrastructure.parsing.treesitter.grammars.c;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// C grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_c() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_c();
        if (!grammar) {
            structuredLog.debug_("c_grammar_not_available_will_use_filelev").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("c");
        if (!config) {
            structuredLog.warning("c_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "c",
            &ts_load_c,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_c_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("c_grammar_not_loaded_").field("detail", "C grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if C grammar is available
bool isCGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
