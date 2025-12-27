module infrastructure.parsing.treesitter.grammars.go;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Go grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_go() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_go();
        if (!grammar) {
            structuredLog.debug_("go_grammar_not_available_will_use_filele").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("go");
        if (!config) {
            structuredLog.warning("go_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "go",
            &ts_load_go,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_go_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("go_grammar_not_loaded_").field("detail", "Go grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Go grammar is available
bool isGoGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
