module infrastructure.parsing.treesitter.grammars.haskell;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Haskell grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_haskell() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_haskell();
        if (!grammar) {
            structuredLog.debug_("haskell_grammar_not_available_will_use_f").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("haskell");
        if (!config) {
            structuredLog.warning("haskell_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "haskell",
            &ts_load_haskell,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_haskell_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("haskell_grammar_not_loaded_").field("detail", "Haskell grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Haskell grammar is available
bool isHaskellGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
