module infrastructure.parsing.treesitter.config;

import engine.caching.incremental.ast_dependency;
import infrastructure.parsing.treesitter.bindings;

/// Language-specific configuration for tree-sitter parsing
/// Maps tree-sitter node types to our AST symbol types
struct LanguageConfig {
    /// Language identifier (e.g., "python", "java")
    string languageId;
    
    /// Display name (e.g., "Python", "Java")
    string displayName;
    
    /// File extensions (e.g., [".py", ".pyi"])
    string[] extensions;
    
    /// Node type → Symbol type mapping
    /// Key: tree-sitter node type (e.g., "class_definition")
    /// Value: our SymbolType
    SymbolType[string] nodeTypeMap;
    
    /// Import/dependency node types
    /// Nodes that represent imports (e.g., "import_statement")
    string[] importNodeTypes;
    
    /// Node types to skip (comments, docstrings, etc.)
    string[] skipNodeTypes;
    
    /// Field names for extracting symbol names
    /// Different languages use different field names
    NameFieldConfig nameFields;
    
    /// Visibility detection
    VisibilityConfig visibility;
    
    /// Dependency extraction
    DependencyConfig dependencies;
}

/// Configuration for extracting symbol names
struct NameFieldConfig {
    /// Field name for class names (e.g., "name")
    string className = "name";
    
    /// Field name for function names
    string functionName = "name";
    
    /// Field name for method names
    string methodName = "name";
    
    /// Field name for variable names
    string variableName = "name";
    
    /// Field name for field names
    string fieldName = "name";
}

/// Configuration for determining symbol visibility
struct VisibilityConfig {
    /// Public modifier keywords (e.g., ["public", "export"])
    string[] publicModifiers;
    
    /// Private modifier keywords
    string[] privateModifiers;
    
    /// Default visibility if no modifier present
    bool defaultPublic = true;
    
    /// Node types that indicate visibility
    string[] modifierNodeTypes;
    
    /// Regex patterns for name-based visibility (e.g., Python: "^_.*" = private)
    string publicNamePattern;
    string privateNamePattern;
}

/// Configuration for extracting dependencies
struct DependencyConfig {
    /// Import statement patterns
    /// Key: node type (e.g., "import_statement")
    /// Value: field name for module name
    string[string] importPatterns;
    
    /// Type usage patterns
    /// Node types that represent type usage
    string[] typeUsageNodeTypes;
    
    /// Member access patterns
    string[] memberAccessNodeTypes;
}

/// Built-in language configurations
/// Note: Configs are now loaded from JSON files via ConfigLoader
final class LanguageConfigs {
    private static LanguageConfig[string] configs;
    private static bool initialized;
    
    /// Initialize configs from JSON files
    static void initialize() @system {
        if (initialized)
            return;
        
        // Load from JSON configs
        import infrastructure.parsing.treesitter.loader;
        auto loader = new ConfigLoader();
        auto loadedConfigs = loader.loadAll();
        
        foreach (config; loadedConfigs) {
            configs[config.languageId] = config;
        }
        
        initialized = true;
    }
    
    static LanguageConfig* get(string langId) @system {
        if (!initialized)
            initialize();
        return langId in configs;
    }
    
    static void register(LanguageConfig config) @safe {
        configs[config.languageId] = config;
    }
    
    static string[] available() @system {
        if (!initialized)
            initialize();
        return configs.keys;
    }
    
    static LanguageConfig[] getByExtension(string extension) @system {
        if (!initialized)
            initialize();
            
        import std.algorithm : canFind;
        LanguageConfig[] matching;
        foreach (config; configs) {
            if (config.extensions.canFind(extension)) {
                matching ~= config;
            }
        }
        return matching;
    }
    
    // Legacy: Built-in configs (replaced by JSON configs)
    // Kept for backward compatibility if JSON files not available
    
    private static LanguageConfig createPythonConfig() @safe {
        LanguageConfig config;
        config.languageId = "python";
        config.displayName = "Python";
        config.extensions = [".py", ".pyi"];
        
        // Map tree-sitter node types to our symbol types
        config.nodeTypeMap = [
            "class_definition": SymbolType.Class,
            "function_definition": SymbolType.Function,
            "decorated_definition": SymbolType.Function,  // @decorator
            "module": SymbolType.Namespace,
            "assignment": SymbolType.Variable,
        ];
        
        config.importNodeTypes = [
            "import_statement",
            "import_from_statement"
        ];
        
        config.skipNodeTypes = [
            "comment",
            "string",  // docstrings
        ];
        
        config.nameFields.className = "name";
        config.nameFields.functionName = "name";
        
        // Python visibility by naming convention
        config.visibility.defaultPublic = true;
        config.visibility.privateNamePattern = "^_[^_].*";  // _private
        config.visibility.publicNamePattern = "^[^_].*";    // public
        
        config.dependencies.importPatterns = [
            "import_statement": "name",
            "import_from_statement": "module_name"
        ];
        
        config.dependencies.typeUsageNodeTypes = [
            "type",
            "generic_type"
        ];
        
        config.dependencies.memberAccessNodeTypes = [
            "attribute",
            "call"
        ];
        
        return config;
    }
    
    private static LanguageConfig createJavaConfig() @safe {
        LanguageConfig config;
        config.languageId = "java";
        config.displayName = "Java";
        config.extensions = [".java"];
        
        config.nodeTypeMap = [
            "class_declaration": SymbolType.Class,
            "interface_declaration": SymbolType.Class,
            "enum_declaration": SymbolType.Enum,
            "method_declaration": SymbolType.Method,
            "constructor_declaration": SymbolType.Method,
            "field_declaration": SymbolType.Field,
            "package_declaration": SymbolType.Namespace,
        ];
        
        config.importNodeTypes = [
            "import_declaration"
        ];
        
        config.skipNodeTypes = [
            "line_comment",
            "block_comment"
        ];
        
        config.visibility.publicModifiers = ["public"];
        config.visibility.privateModifiers = ["private", "protected"];
        config.visibility.defaultPublic = false;
        config.visibility.modifierNodeTypes = ["modifiers"];
        
        config.dependencies.importPatterns = [
            "import_declaration": "name"
        ];
        
        config.dependencies.typeUsageNodeTypes = [
            "type_identifier",
            "generic_type"
        ];
        
        return config;
    }
    
    private static LanguageConfig createTypeScriptConfig() @safe {
        LanguageConfig config;
        config.languageId = "typescript";
        config.displayName = "TypeScript";
        config.extensions = [".ts", ".tsx"];
        
        config.nodeTypeMap = [
            "class_declaration": SymbolType.Class,
            "interface_declaration": SymbolType.Class,
            "function_declaration": SymbolType.Function,
            "method_definition": SymbolType.Method,
            "enum_declaration": SymbolType.Enum,
            "type_alias_declaration": SymbolType.Typedef,
            "namespace_declaration": SymbolType.Namespace,
        ];
        
        config.importNodeTypes = [
            "import_statement",
            "import_clause"
        ];
        
        config.skipNodeTypes = [
            "comment"
        ];
        
        config.visibility.publicModifiers = ["public", "export"];
        config.visibility.privateModifiers = ["private", "protected"];
        config.visibility.defaultPublic = true;
        
        config.dependencies.importPatterns = [
            "import_statement": "source"
        ];
        
        config.dependencies.typeUsageNodeTypes = [
            "type_identifier",
            "generic_type"
        ];
        
        return config;
    }
    
    private static LanguageConfig createJavaScriptConfig() @safe {
        LanguageConfig config;
        config.languageId = "javascript";
        config.displayName = "JavaScript";
        config.extensions = [".js", ".jsx", ".mjs", ".cjs"];
        
        config.nodeTypeMap = [
            "class_declaration": SymbolType.Class,
            "function_declaration": SymbolType.Function,
            "method_definition": SymbolType.Method,
            "arrow_function": SymbolType.Function,
            "variable_declaration": SymbolType.Variable,
        ];
        
        config.importNodeTypes = [
            "import_statement",
            "import_clause"
        ];
        
        config.visibility.defaultPublic = true;
        config.visibility.publicModifiers = ["export"];
        
        config.dependencies.importPatterns = [
            "import_statement": "source"
        ];
        
        return config;
    }
    
    private static LanguageConfig createGoConfig() @safe {
        LanguageConfig config;
        config.languageId = "go";
        config.displayName = "Go";
        config.extensions = [".go"];
        
        config.nodeTypeMap = [
            "type_declaration": SymbolType.Struct,
            "struct_type": SymbolType.Struct,
            "interface_type": SymbolType.Class,
            "function_declaration": SymbolType.Function,
            "method_declaration": SymbolType.Method,
            "const_declaration": SymbolType.Variable,
            "var_declaration": SymbolType.Variable,
        ];
        
        config.importNodeTypes = [
            "import_declaration",
            "import_spec"
        ];
        
        // Go visibility: uppercase = public
        config.visibility.defaultPublic = false;
        config.visibility.publicNamePattern = "^[A-Z].*";
        config.visibility.privateNamePattern = "^[a-z].*";
        
        config.dependencies.importPatterns = [
            "import_spec": "path"
        ];
        
        return config;
    }
    
    private static LanguageConfig createRustConfig() @safe {
        LanguageConfig config;
        config.languageId = "rust";
        config.displayName = "Rust";
        config.extensions = [".rs"];
        
        config.nodeTypeMap = [
            "struct_item": SymbolType.Struct,
            "enum_item": SymbolType.Enum,
            "function_item": SymbolType.Function,
            "impl_item": SymbolType.Class,
            "trait_item": SymbolType.Class,
            "mod_item": SymbolType.Namespace,
            "const_item": SymbolType.Variable,
            "static_item": SymbolType.Variable,
        ];
        
        config.importNodeTypes = [
            "use_declaration"
        ];
        
        config.visibility.publicModifiers = ["pub"];
        config.visibility.privateModifiers = [];
        config.visibility.defaultPublic = false;
        config.visibility.modifierNodeTypes = ["visibility_modifier"];
        
        config.dependencies.importPatterns = [
            "use_declaration": "argument"
        ];
        
        return config;
    }
}

