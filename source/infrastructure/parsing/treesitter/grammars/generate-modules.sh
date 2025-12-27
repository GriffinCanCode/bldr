#!/usr/bin/env bash
# Generate D modules for all tree-sitter grammars

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Language list (matches configs)
LANGUAGES=(
    "c" "cpp" "python" "java" "javascript" "typescript"
    "go" "rust" "csharp" "ruby" "php" "swift" "kotlin"
    "scala" "elixir" "lua" "perl" "r" "haskell" "ocaml"
    "nim" "zig" "d" "elm" "fsharp" "css" "protobuf"
)

# Function to generate a D module for a language
generate_module() {
    local lang="$1"
    local lang_upper="${lang^^}"
    local lang_cap="${lang^}"
    local func_name="tree_sitter_${lang}"
    
    # Handle special cases
    case "$lang" in
        "cpp") func_name="tree_sitter_cpp" ;;
        "csharp") func_name="tree_sitter_c_sharp" ;;
        "fsharp") func_name="tree_sitter_f_sharp" ;;
        "typescript") func_name="tree_sitter_typescript" ;;
    esac
    
    local file="$SCRIPT_DIR/${lang}.d"
    
    cat > "$file" <<EOF
module infrastructure.parsing.treesitter.grammars.${lang};

import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.logging;

/// ${lang_cap} grammar loader for tree-sitter
/// Dynamically loads grammar from system libraries if available

// Dynamic loader from C
extern(C) const(TSLanguage)* ts_load_${lang}() @system nothrow @nogc;

private bool grammarLoaded = false;

shared static this() @system {
    try {
        // Try to load grammar dynamically
        auto grammar = ts_load_${lang}();
        if (!grammar) {
            Logger.debugLog("${lang_cap} grammar not available (will use file-level tracking)");
            return;
        }
        
        auto config = LanguageConfigs.get("${lang}");
        if (!config) {
            Logger.warning("${lang_cap} config not found");
            return;
        }
        
        // Register with tree-sitter registry
        TreeSitterRegistry.instance().registerGrammar(
            "${lang}",
            &ts_load_${lang},
            *config
        );
        
        // Create and register parser
        auto parser = new TreeSitterParser(grammar, *config);
        ASTParserRegistry.instance().registerParser(parser);
        
        grammarLoaded = true;
        Logger.info("✓ ${lang_cap} tree-sitter grammar loaded");
    } catch (Exception e) {
        Logger.debugLog("${lang_cap} grammar not loaded: " ~ e.msg);
    }
}

/// Check if ${lang_cap} grammar is available
bool is${lang_cap}GrammarAvailable() @safe nothrow {
    return grammarLoaded;
}
EOF
    
    echo "  ✓ Generated $lang.d"
}

echo "Generating D modules for all grammars..."
echo ""

for lang in "${LANGUAGES[@]}"; do
    generate_module "$lang"
done

echo ""
echo "✓ Generated ${#LANGUAGES[@]} modules"
echo ""
echo "Next: Update package.d to import these modules"

