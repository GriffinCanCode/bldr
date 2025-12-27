module infrastructure.parsing.treesitter.grammars.lua;

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// Lua grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_lua() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_lua();
        if (!grammar) {
            structuredLog.debug_("lua_grammar_not_available_will_use_filel").emit();
            return;
        }
        
        auto config = LanguageConfigs.get("lua");
        if (!config) {
            structuredLog.warning("lua_config_not_found").emit();
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "lua",
            &ts_load_lua,
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        structuredLog.info("_lua_treesitter_grammar_loaded").emit();
    } catch (Exception e) {
        structuredLog.debug_("lua_grammar_not_loaded_").field("detail", "Lua grammar not loaded: " ~ e.msg).emit();
    }
}

/// Check if Lua grammar is available
bool isLuaGrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
