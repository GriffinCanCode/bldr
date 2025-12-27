module infrastructure.parsing.treesitter.grammars.ocaml;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Ocaml grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_ocaml() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_ocaml();
        if (!grammar) {
            structuredLog.debug_("ocaml_grammar_not_available_will_use_fil").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("ocaml");
        if (!config) {
            structuredLog.warning("ocaml_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "ocaml",
            &ts_load_ocaml,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_ocaml_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("ocaml_grammar_not_loaded_").field("detail", "Ocaml grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Ocaml grammar is available
bool isOcamlGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
