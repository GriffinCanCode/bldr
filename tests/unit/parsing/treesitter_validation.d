module tests.unit.parsing.treesitter_validation;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio;
import std.json;
import std.regex;
import std.uuid;
import infrastructure.parsing.treesitter;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.loader;
import infrastructure.parsing.treesitter.registry;
import infrastructure.parsing.treesitter.parser;
import infrastructure.analysis.ast.parser;
import engine.caching.incremental.ast_dependency;
import infrastructure.utils.logging.logger;
import infrastructure.errors;
import tests.harness;

/// Comprehensive tree-sitter integration validation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Tree-sitter Integration Validation");
    
    testConfigLoading();
    testConfigValidation();
    testAllLanguageConfigs();
    testVisibilityPatterns();
    testParserRegistry();
    testSymbolTypeMapping();
    testConfigurationCompleteness();
    testStubLoading();
    
    writeln("\x1b[32m  ✓ All tree-sitter validation tests passed\x1b[0m");
}

/// Test stub loading directly (implementation detail check)
void testStubLoading()
{
    writeln("  Testing stub loader logic...");

    // These functions are declared in the C stub and bound via extern(C)
    // We can't easily call them directly here without redeclaring them or importing internal modules
    // However, registerTreeSitterParsers() calls them indirectly.
    // We'll just verify that invoking the registry doesn't crash.
    
    try {
        // Check C grammar availability (should be false with stub unless installed)
        import infrastructure.parsing.treesitter.grammars.c;
        bool available = isCGrammarAvailable();
        
        if (available) {
            writeln("    ✓ C grammar is available (system installed)");
        } else {
            writeln("    ✓ C grammar correctly reported as unavailable (using stub)");
        }
        
        // Attempt to create a parser for C
        auto result = TreeSitterRegistry.instance().createParser("c");
        
        if (result.isOk) {
            writeln("    ✓ Parser created successfully");
        } else {
            // If grammar is missing, it should return error
            Assert.equal(result.unwrapErr().code, ErrorCode.UnsupportedLanguage, 
                "Should return UnsupportedLanguage when grammar is missing");
            writeln("    ✓ Parser creation correctly failed (grammar missing)");
        }

    } catch (Exception e) {
        Assert.fail("Stub loading caused crash: " ~ e.msg);
    }
    
    writeln("    ✓ Stub loader logic validated");
}

/// Test JSON config loading mechanism
void testConfigLoading()
{
    writeln("  Testing JSON config loading...");
    
    // Find config directory
    string configDir = "source/infrastructure/parsing/configs";
    Assert.isTrue(exists(configDir), "Config directory should exist");
    Assert.isTrue(isDir(configDir), "Config path should be a directory");
    
    // Load all configs
    auto loader = new ConfigLoader(configDir);
    auto configs = loader.loadAll();
    
    Assert.isTrue(configs.length > 0, "Should load at least one config");
    Assert.isTrue(configs.length >= 20, "Should have 20+ language configs");
    
    writeln("    Loaded " ~ configs.length.to!string ~ " language configs");
    
    // Verify each config has required fields
    foreach (config; configs) {
        Assert.isFalse(config.languageId.empty, "Config should have language ID");
        Assert.isFalse(config.displayName.empty, "Config should have display name");
        Assert.isTrue(config.extensions.length > 0, "Config should have extensions");
        Assert.isTrue(config.nodeTypeMap.length > 0, "Config should have node type mappings");
    }
    
    writeln("    ✓ Config loading works correctly");
}

/// Test individual config validation
void testConfigValidation()
{
    writeln("  Testing config validation...");
    
    auto loader = new ConfigLoader();
    
    // Test Python config
    string pythonPath = "source/infrastructure/parsing/configs/python.json";
    if (exists(pythonPath)) {
        auto config = loader.loadFromJSON(pythonPath);
        
        Assert.equal(config.languageId, "python");
        Assert.equal(config.displayName, "Python");
        Assert.isTrue(config.extensions.canFind(".py"));
        Assert.isTrue(config.extensions.canFind(".pyi"));
        
        // Verify node type mappings
        Assert.isTrue(("class_definition" in config.nodeTypeMap) !is null);
        Assert.equal(config.nodeTypeMap["class_definition"], SymbolType.Class);
        Assert.isTrue(("function_definition" in config.nodeTypeMap) !is null);
        Assert.equal(config.nodeTypeMap["function_definition"], SymbolType.Function);
        
        // Verify imports
        Assert.isTrue(config.importNodeTypes.canFind("import_statement"));
        Assert.isTrue(config.importNodeTypes.canFind("import_from_statement"));
        
        // Verify visibility
        Assert.isTrue(config.visibility.defaultPublic);
        Assert.isFalse(config.visibility.privateNamePattern.empty);
        
        writeln("    ✓ Python config validated");
    }
    
    // Test Java config
    string javaPath = "source/infrastructure/parsing/configs/java.json";
    if (exists(javaPath)) {
        auto config = loader.loadFromJSON(javaPath);
        
        Assert.equal(config.languageId, "java");
        Assert.isTrue(("class_declaration" in config.nodeTypeMap) !is null);
        Assert.isTrue(("interface_declaration" in config.nodeTypeMap) !is null);
        Assert.isTrue(("enum_declaration" in config.nodeTypeMap) !is null);
        Assert.equal(config.nodeTypeMap["enum_declaration"], SymbolType.Enum);
        
        // Java has explicit modifiers
        Assert.isTrue(config.visibility.publicModifiers.canFind("public"));
        Assert.isTrue(config.visibility.privateModifiers.canFind("private"));
        
        writeln("    ✓ Java config validated");
    }
    
    // Test C++ config
    string cppPath = "source/infrastructure/parsing/configs/cpp.json";
    if (exists(cppPath)) {
        auto config = loader.loadFromJSON(cppPath);
        
        Assert.equal(config.languageId, "cpp");
        Assert.isTrue(config.extensions.length >= 8); // Many C++ extensions
        Assert.isTrue(("class_specifier" in config.nodeTypeMap) !is null);
        Assert.isTrue(("struct_specifier" in config.nodeTypeMap) !is null);
        Assert.isTrue(("template_declaration" in config.nodeTypeMap) !is null);
        Assert.equal(config.nodeTypeMap["template_declaration"], SymbolType.Template);
        
        writeln("    ✓ C++ config validated");
    }
    
    writeln("    ✓ Config validation passed");
}

/// Test all available language configs
void testAllLanguageConfigs()
{
    writeln("  Testing all language configs...");
    
    string configDir = "source/infrastructure/parsing/configs";
    auto loader = new ConfigLoader(configDir);
    auto configs = loader.loadAll();
    
    string[] expectedLanguages = [
        "c", "cpp", "csharp", "css", "d", "elixir", "elm", "fsharp",
        "go", "haskell", "java", "javascript", "kotlin", "lua", "nim",
        "ocaml", "perl", "php", "protobuf", "python", "r", "ruby",
        "rust", "scala", "swift", "typescript", "zig"
    ];
    
    auto loadedLanguages = configs.map!(c => c.languageId).array;
    writeln("    Loaded languages: ", loadedLanguages.sort.array);
    
    foreach (expected; expectedLanguages) {
        Assert.isTrue(loadedLanguages.canFind(expected),
            "Should have config for " ~ expected);
    }
    
    writeln("    ✓ All " ~ configs.length.to!string ~ " language configs present");
}

/// Test visibility pattern compilation
void testVisibilityPatterns()
{
    writeln("  Testing visibility patterns...");
    
    auto loader = new ConfigLoader();
    auto configs = loader.loadAll();
    
    foreach (config; configs) {
        // Test that regex patterns compile
        if (!config.visibility.publicNamePattern.empty) {
            try {
                auto r = regex(config.visibility.publicNamePattern);
                // Test pattern with sample
                if (config.languageId == "python") {
                    Assert.isFalse("_private".matchFirst(r).empty == false);
                    Assert.isFalse("public_var".matchFirst(r).empty);
                }
            } catch (Exception e) {
                Assert.fail("Invalid public pattern for " ~ config.languageId ~ ": " ~ e.msg);
            }
        }
        
        if (!config.visibility.privateNamePattern.empty) {
            try {
                auto r = regex(config.visibility.privateNamePattern);
                // Test pattern with sample
                if (config.languageId == "python") {
                    Assert.isFalse("_private".matchFirst(r).empty);
                    Assert.isTrue("public_var".matchFirst(r).empty);
                }
            } catch (Exception e) {
                Assert.fail("Invalid private pattern for " ~ config.languageId ~ ": " ~ e.msg);
            }
        }
    }
    
    writeln("    ✓ Visibility patterns compile correctly");
}

/// Test parser registry integration
void testParserRegistry()
{
    writeln("  Testing parser registry integration...");
    
    // Initialize configs
    LanguageConfigs.initialize();
    
    // Check available configs
    auto available = LanguageConfigs.available();
    Assert.isTrue(available.length > 0, "Should have available configs");
    
    writeln("    Available configs: " ~ available.length.to!string);
    
    // Test retrieval
    auto pythonConfig = LanguageConfigs.get("python");
    Assert.isTrue(pythonConfig !is null, "Should retrieve Python config");
    Assert.equal(pythonConfig.languageId, "python");
    
    auto javaConfig = LanguageConfigs.get("java");
    Assert.isTrue(javaConfig !is null, "Should retrieve Java config");
    
    auto nonexistent = LanguageConfigs.get("nonexistent");
    Assert.isTrue(nonexistent is null, "Should return null for nonexistent");
    
    writeln("    ✓ Parser registry integration works");
}

/// Test symbol type mapping completeness
void testSymbolTypeMapping()
{
    writeln("  Testing symbol type mappings...");
    
    auto loader = new ConfigLoader();
    auto configs = loader.loadAll();
    
    // Track what symbol types are used
    bool[SymbolType] usedTypes;
    
    foreach (config; configs) {
        foreach (nodeType, symbolType; config.nodeTypeMap) {
            usedTypes[symbolType] = true;
        }
    }
    
    // Verify we use diverse symbol types
    Assert.isTrue((SymbolType.Class in usedTypes) !is null, "Should use Class");
    Assert.isTrue((SymbolType.Function in usedTypes) !is null, "Should use Function");
    Assert.isTrue((SymbolType.Method in usedTypes) !is null, "Should use Method");
    
    writeln("    Used symbol types: " ~ usedTypes.keys.length.to!string);
    writeln("    ✓ Symbol type mappings are diverse");
}

/// Test configuration completeness
void testConfigurationCompleteness()
{
    writeln("  Testing configuration completeness...");
    
    auto loader = new ConfigLoader();
    auto configs = loader.loadAll();
    
    struct ConfigMetrics {
        int totalConfigs;
        int withImports;
        int withVisibility;
        int withDependencies;
        int withSkipNodes;
        size_t totalNodeTypes;
        size_t totalExtensions;
    }
    
    ConfigMetrics metrics;
    metrics.totalConfigs = cast(int)configs.length;
    
    foreach (config; configs) {
        if (config.importNodeTypes.length > 0) metrics.withImports++;
        if (!config.visibility.publicNamePattern.empty || 
            config.visibility.publicModifiers.length > 0 ||
            config.visibility.privateModifiers.length > 0) {
            metrics.withVisibility++;
        }
        if (config.dependencies.typeUsageNodeTypes.length > 0) {
            metrics.withDependencies++;
        }
        if (config.skipNodeTypes.length > 0) metrics.withSkipNodes++;
        
        metrics.totalNodeTypes += config.nodeTypeMap.length;
        metrics.totalExtensions += config.extensions.length;
    }
    
    writeln("    Configuration Metrics:");
    writeln("      Total configs: ", metrics.totalConfigs);
    writeln("      With imports: ", metrics.withImports);
    writeln("      With visibility rules: ", metrics.withVisibility);
    writeln("      With dependencies: ", metrics.withDependencies);
    writeln("      With skip nodes: ", metrics.withSkipNodes);
    writeln("      Total node type mappings: ", metrics.totalNodeTypes);
    writeln("      Total file extensions: ", metrics.totalExtensions);
    
    // Validate reasonable coverage
    Assert.isTrue(metrics.withImports >= 15, "Most languages should define imports");
    Assert.isTrue(metrics.totalNodeTypes >= 100, "Should have substantial node type coverage");
    
    writeln("    ✓ Configuration completeness validated");
}

/// Test specific language edge cases
void testLanguageEdgeCases()
{
    writeln("  Testing language-specific edge cases...");
    
    auto loader = new ConfigLoader();
    
    // Go: uppercase = public
    auto goConfig = LanguageConfigs.get("go");
    if (goConfig) {
        Assert.isFalse(goConfig.visibility.defaultPublic);
        Assert.isFalse(goConfig.visibility.publicNamePattern.empty);
        writeln("    ✓ Go visibility rules present");
    }
    
    // Python: underscore = private
    auto pyConfig = LanguageConfigs.get("python");
    if (pyConfig) {
        Assert.isTrue(pyConfig.visibility.defaultPublic);
        Assert.isFalse(pyConfig.visibility.privateNamePattern.empty);
        writeln("    ✓ Python visibility rules present");
    }
    
    // Rust: pub modifier
    auto rustConfig = LanguageConfigs.get("rust");
    if (rustConfig) {
        Assert.isTrue(rustConfig.visibility.publicModifiers.canFind("pub"));
        Assert.isFalse(rustConfig.visibility.defaultPublic);
        writeln("    ✓ Rust visibility rules present");
    }
    
    writeln("    ✓ Language edge cases validated");
}

/// Test JSON format validation
void testJSONFormat()
{
    writeln("  Testing JSON format validation...");
    
    string configDir = "source/infrastructure/parsing/configs";
    
    foreach (entry; dirEntries(configDir, "*.json", SpanMode.shallow)) {
        if (!entry.isFile) continue;
        
        try {
            auto content = readText(entry.name);
            auto json = parseJSON(content);
            
            // Verify required top-level keys
            Assert.isTrue(("language" in json) !is null, entry.name ~ " missing 'language' key");
            Assert.isTrue(("node_types" in json) !is null, entry.name ~ " missing 'node_types' key");
            
            // Verify language sub-keys
            auto lang = json["language"];
            Assert.isTrue(("id" in lang) !is null, entry.name ~ " missing 'language.id'");
            Assert.isTrue(("display" in lang) !is null, entry.name ~ " missing 'language.display'");
            Assert.isTrue(("extensions" in lang) !is null, entry.name ~ " missing 'language.extensions'");
            
        } catch (Exception e) {
            Assert.fail("JSON parse error in " ~ entry.name ~ ": " ~ e.msg);
        }
    }
    
    writeln("    ✓ All JSON files are valid");
}

/// Test config loader error handling
void testConfigLoaderErrorHandling()
{
    writeln("  Testing config loader error handling...");
    
    // Test with nonexistent directory
    auto loader1 = new ConfigLoader("/nonexistent/path");
    auto configs1 = loader1.loadAll();
    Assert.equal(configs1.length, 0, "Should handle missing directory gracefully");
    
    // Test with invalid path
    auto tempDir = buildPath(tempDir(), "treesitter-test-" ~ randomUUID().toString());
    mkdirRecurse(tempDir);
    scope(exit) if (exists(tempDir)) rmdirRecurse(tempDir);
    
    // Create invalid JSON file
    auto invalidFile = buildPath(tempDir, "invalid.json");
    import std.file : write;
    write(invalidFile, "{ invalid json }");
    
    auto loader2 = new ConfigLoader(tempDir);
    auto configs2 = loader2.loadAll();
    Assert.equal(configs2.length, 0, "Should handle invalid JSON gracefully");
    
    writeln("    ✓ Error handling validated");
}

/// Integration test with AST parser registry
void testASTParserRegistryIntegration()
{
    writeln("  Testing AST parser registry integration...");
    
    // Initialize tree-sitter
    try {
        registerTreeSitterParsers();
        
        // Note: Without actual grammar binaries, parsers won't be fully registered
        // But the config system should still initialize
        auto available = LanguageConfigs.available();
        Assert.isTrue(available.length > 0, "Should have configs available");
        
        writeln("    ✓ Registry integration successful");
    } catch (Exception e) {
        writeln("    ⚠ Registry integration: " ~ e.msg);
        writeln("    (This is expected if tree-sitter grammars not installed)");
    }
}

