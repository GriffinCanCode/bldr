module infrastructure.parsing.treesitter.grammars.java;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Java grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_java() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_java();
        if (!grammar) {
            structuredLog.debug_("java_grammar_not_available_will_use_file").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("java");
        if (!config) {
            structuredLog.warning("java_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "java",
            &ts_load_java,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_java_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("java_grammar_not_loaded_").field("detail", "Java grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Java grammar is available
bool isJavaGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
