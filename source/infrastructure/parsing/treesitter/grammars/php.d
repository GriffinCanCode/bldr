module infrastructure.parsing.treesitter.grammars.php;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Php grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_php() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_php();
        if (!grammar) {
            structuredLog.debug_("php_grammar_not_available_will_use_filel").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("php");
        if (!config) {
            structuredLog.warning("php_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "php",
            &ts_load_php,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_php_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("php_grammar_not_loaded_").field("detail", "Php grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Php grammar is available
bool isPhpGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
