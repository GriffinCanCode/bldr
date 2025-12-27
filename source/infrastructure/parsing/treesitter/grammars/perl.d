module infrastructure.parsing.treesitter.grammars.perl;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Perl grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_perl() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_perl();
        if (!grammar) {
            structuredLog.debug_("perl_grammar_not_available_will_use_file").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("perl");
        if (!config) {
            structuredLog.warning("perl_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "perl",
            &ts_load_perl,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_perl_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("perl_grammar_not_loaded_").field("detail", "Perl grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Perl grammar is available
bool isPerlGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
