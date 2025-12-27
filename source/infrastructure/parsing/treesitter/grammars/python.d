module infrastructure.parsing.treesitter.grammars.python;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Python grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_python() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_python();
        if (!grammar) {
            structuredLog.debug_("python_grammar_not_available_will_use_fi").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("python");
        if (!config) {
            structuredLog.warning("python_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "python",
            &ts_load_python,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_python_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("python_grammar_not_loaded_").field("detail", "Python grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Python grammar is available
bool isPythonGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
