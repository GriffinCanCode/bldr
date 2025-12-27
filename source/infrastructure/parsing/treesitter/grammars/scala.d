module infrastructure.parsing.treesitter.grammars.scala;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Scala grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_scala() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_scala();
        if (!grammar) {
            structuredLog.debug_("scala_grammar_not_available_will_use_fil").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("scala");
        if (!config) {
            structuredLog.warning("scala_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "scala",
            &ts_load_scala,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_scala_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("scala_grammar_not_loaded_").field("detail", "Scala grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Scala grammar is available
bool isScalaGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
