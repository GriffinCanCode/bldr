module infrastructure.parsing.treesitter.grammars.kotlin;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Kotlin grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_kotlin() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_kotlin();
        if (!grammar) {
            structuredLog.debug_("kotlin_grammar_not_available_will_use_fi").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("kotlin");
        if (!config) {
            structuredLog.warning("kotlin_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "kotlin",
            &ts_load_kotlin,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_kotlin_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("kotlin_grammar_not_loaded_").field("detail", "Kotlin grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Kotlin grammar is available
bool isKotlinGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
