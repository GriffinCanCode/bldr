module infrastructure.parsing.treesitter.grammars.r;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// R grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_r() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_r();
        if (!grammar) {
            structuredLog.debug_("r_grammar_not_available_will_use_filelev").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("r");
        if (!config) {
            structuredLog.warning("r_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "r",
            &ts_load_r,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_r_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("r_grammar_not_loaded_").field("detail", "R grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if R grammar is available
bool isRGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
