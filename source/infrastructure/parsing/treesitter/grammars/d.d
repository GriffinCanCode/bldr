module infrastructure.parsing.treesitter.grammars.d;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// D grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_d() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_d();
        if (!grammar) {
            structuredLog.debug_("d_grammar_not_available_will_use_filelev").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("d");
        if (!config) {
            structuredLog.warning("d_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "d",
            &ts_load_d,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_d_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("d_grammar_not_loaded_").field("detail", "D grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if D grammar is available
bool isDGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
