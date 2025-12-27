module infrastructure.parsing.treesitter.grammars.swift;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Swift grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_swift() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_swift();
        if (!grammar) {
            structuredLog.debug_("swift_grammar_not_available_will_use_fil").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("swift");
        if (!config) {
            structuredLog.warning("swift_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "swift",
            &ts_load_swift,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_swift_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("swift_grammar_not_loaded_").field("detail", "Swift grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Swift grammar is available
bool isSwiftGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
