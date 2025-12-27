module infrastructure.parsing.treesitter.grammars.nim;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Nim grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_nim() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_nim();
        if (!grammar) {
            structuredLog.debug_("nim_grammar_not_available_will_use_filel").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("nim");
        if (!config) {
            structuredLog.warning("nim_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "nim",
            &ts_load_nim,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_nim_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("nim_grammar_not_loaded_").field("detail", "Nim grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Nim grammar is available
bool isNimGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
