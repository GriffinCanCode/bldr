module infrastructure.parsing.treesitter.grammars.fsharp;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Fsharp grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_fsharp() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_fsharp();
        if (!grammar) {
            structuredLog.debug_("fsharp_grammar_not_available_will_use_fi").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("fsharp");
        if (!config) {
            structuredLog.warning("fsharp_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "fsharp",
            &ts_load_fsharp,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_fsharp_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("fsharp_grammar_not_loaded_").field("detail", "Fsharp grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Fsharp grammar is available
bool isFsharpGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
