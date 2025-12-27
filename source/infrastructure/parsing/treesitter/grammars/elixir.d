module infrastructure.parsing.treesitter.grammars.elixir;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Elixir grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_elixir() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_elixir();
        if (!grammar) {
            structuredLog.debug_("elixir_grammar_not_available_will_use_fi").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("elixir");
        if (!config) {
            structuredLog.warning("elixir_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "elixir",
            &ts_load_elixir,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_elixir_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("elixir_grammar_not_loaded_").field("detail", "Elixir grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Elixir grammar is available
bool isElixirGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
