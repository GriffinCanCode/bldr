module infrastructure.parsing.treesitter.grammars.elm;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Elm grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_elm() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_elm();
        if (!grammar) {
            structuredLog.debug_("elm_grammar_not_available_will_use_filel").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("elm");
        if (!config) {
            structuredLog.warning("elm_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "elm",
            &ts_load_elm,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_elm_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("elm_grammar_not_loaded_").field("detail", "Elm grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Elm grammar is available
bool isElmGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
