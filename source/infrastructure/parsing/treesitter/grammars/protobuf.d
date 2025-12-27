module infrastructure.parsing.treesitter.grammars.protobuf;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Protobuf grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_protobuf() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_protobuf();
        if (!grammar) {
            structuredLog.debug_("protobuf_grammar_not_available_will_use_").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("protobuf");
        if (!config) {
            structuredLog.warning("protobuf_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "protobuf",
            &ts_load_protobuf,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_protobuf_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("protobuf_grammar_not_loaded_").field("detail", "Protobuf grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Protobuf grammar is available
bool isProtobufGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
