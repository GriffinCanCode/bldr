module tests.unit.parsing.config_validation;

import std.algorithm;
import std.conv;
import std.file;
import std.json;
import std.path;
import std.stdio;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.loader;

/// Validate all JSON configuration files
unittest {
    writeln("\n=== Validating All Language Configurations ===");
    
    immutable configDir = "source/infrastructure/parsing/configs";
    assert(exists(configDir), "Config directory not found: " ~ configDir);
    
    int totalConfigs = 0;
    int validConfigs = 0;
    int errors = 0;
    
    foreach (entry; dirEntries(configDir, "*.json", SpanMode.shallow)) {
        totalConfigs++;
        auto configPath = entry.name;
        auto langName = baseName(configPath, ".json");
        
        try {
            // Read and parse JSON
            auto content = readText(configPath);
            auto json = parseJSON(content);
            
            // Validate required fields
            assert("language" in json, "Missing 'language' section");
            assert("id" in json["language"], "Missing language.id");
            assert("display" in json["language"], "Missing language.display");
            assert("extensions" in json["language"], "Missing language.extensions");
            
            auto langId = json["language"]["id"].str;
            auto display = json["language"]["display"].str;
            auto extensions = json["language"]["extensions"].array;
            
            assert(langId.length > 0, "Empty language ID");
            assert(display.length > 0, "Empty display name");
            assert(extensions.length > 0, "No file extensions");
            
            // Validate node types
            assert("node_types" in json, "Missing 'node_types' section");
            auto nodeTypes = json["node_types"].object;
            assert(nodeTypes.length > 0, "Empty node_types mapping");
            
            // Validate optional sections
            if ("visibility_patterns" in json) {
                auto visibility = json["visibility_patterns"].object;
                writeln("  • ", display, " has ", visibility.length, " visibility patterns");
            }
            
            if ("import_types" in json) {
                auto imports = json["import_types"].array;
                writeln("  • ", display, " has ", imports.length, " import types");
            }
            
            writeln("  ✓ ", display, " (", langId, "): ", extensions.length, 
                    " extensions, ", nodeTypes.length, " node types");
            validConfigs++;
            
        } catch (Exception e) {
            writeln("  ✗ ", langName, " - ERROR: ", e.msg);
            errors++;
        }
    }
    
    writeln("\nValidation Summary:");
    writeln("  Total configs: ", totalConfigs);
    writeln("  Valid: ", validConfigs);
    writeln("  Errors: ", errors);
    
    assert(errors == 0, "Configuration validation failed");
    assert(validConfigs == 27, "Expected 27 configs, found " ~ validConfigs.to!string);
    
    writeln("✅ All configurations validated successfully");
}

/// Test configuration loader
unittest {
    writeln("\n=== Testing Configuration Loader ===");
    
    LanguageConfigs.initialize();
    
    immutable string[] testLangs = [
        "python", "java", "javascript", "typescript", "cpp", 
        "go", "rust", "c", "csharp", "ruby"
    ];
    
    foreach (lang; testLangs) {
        auto config = LanguageConfigs.get(lang);
        assert(config !is null, "Failed to load " ~ lang ~ " config");
        assert(config.languageId == lang, "Mismatched language ID");
        assert(config.extensions.length > 0, "No extensions for " ~ lang);
        assert(config.nodeTypeMap.length > 0, "No node types for " ~ lang);
        writeln("  ✓ ", config.displayName, " loaded and validated");
    }
    
    writeln("✅ Configuration loader test passed");
}

/// Test extension mapping
unittest {
    writeln("\n=== Testing Extension Mapping ===");
    
    LanguageConfigs.initialize();
    
    immutable string[][string] extensionTests = [
        ".py": ["python"],
        ".java": ["java"],
        ".js": ["javascript"],
        ".ts": ["typescript"],
        ".tsx": ["typescript"],
        ".cpp": ["cpp"],
        ".go": ["go"],
        ".rs": ["rust"],
        ".c": ["c"],
        ".cs": ["csharp"]
    ];
    
    foreach (ext, expectedLangs; extensionTests) {
        auto configs = LanguageConfigs.getByExtension(ext);
        assert(configs.length > 0, "No config found for " ~ ext);
        
        foreach (config; configs) {
            assert(expectedLangs.canFind(config.languageId), 
                   "Unexpected language " ~ config.languageId ~ " for " ~ ext);
            writeln("  ✓ ", ext, " → ", config.displayName);
        }
    }
    
    writeln("✅ Extension mapping test passed");
}

/// Test symbol type mappings
unittest {
    writeln("\n=== Testing Symbol Type Mappings ===");
    
    LanguageConfigs.initialize();
    
    // Test Python
    auto pythonConfig = LanguageConfigs.get("python");
    assert("function_definition" in pythonConfig.nodeTypeMap);
    assert("class_definition" in pythonConfig.nodeTypeMap);
    writeln("  ✓ Python symbol types validated");
    
    // Test Java
    auto javaConfig = LanguageConfigs.get("java");
    assert("method_declaration" in javaConfig.nodeTypeMap);
    assert("class_declaration" in javaConfig.nodeTypeMap);
    writeln("  ✓ Java symbol types validated");
    
    // Test JavaScript
    auto jsConfig = LanguageConfigs.get("javascript");
    assert("function_declaration" in jsConfig.nodeTypeMap);
    assert("class_declaration" in jsConfig.nodeTypeMap);
    writeln("  ✓ JavaScript symbol types validated");
    
    writeln("✅ Symbol type mapping test passed");
}

/// Test configuration completeness
unittest {
    writeln("\n=== Testing Configuration Completeness ===");
    
    LanguageConfigs.initialize();
    
    immutable string[] requiredLangs = [
        "c", "cpp", "python", "java", "javascript", "typescript",
        "go", "rust", "csharp", "ruby", "php", "swift", "kotlin",
        "scala", "elixir", "lua", "perl", "r", "haskell", "ocaml",
        "nim", "zig", "d", "elm", "fsharp", "css", "protobuf"
    ];
    
    int complete = 0;
    int incomplete = 0;
    
    foreach (lang; requiredLangs) {
        auto config = LanguageConfigs.get(lang);
        
        if (config is null) {
            writeln("  ✗ Missing: ", lang);
            incomplete++;
            continue;
        }
        
        // Check completeness
        bool hasExtensions = config.extensions.length > 0;
        bool hasNodeTypes = config.nodeTypeMap.length > 0;
        bool hasDisplayName = config.displayName.length > 0;
        
        if (hasExtensions && hasNodeTypes && hasDisplayName) {
            complete++;
        } else {
            writeln("  ⚠️  Incomplete: ", lang);
            incomplete++;
        }
    }
    
    writeln("\nCompleteness Summary:");
    writeln("  Complete: ", complete, "/", requiredLangs.length);
    writeln("  Incomplete: ", incomplete);
    
    assert(complete == requiredLangs.length, "Some configurations are incomplete");
    writeln("✅ All configurations are complete");
}

/// Performance test - configuration loading
unittest {
    writeln("\n=== Performance Test: Configuration Loading ===");
    
    import std.datetime.stopwatch;
    
    auto sw = StopWatch(AutoStart.yes);
    LanguageConfigs.initialize();
    sw.stop();
    
    auto duration = sw.peek();
    writeln("  Configuration loading time: ", duration);
    
    // Should be very fast (< 100ms even for all 28 languages)
    assert(duration.total!"msecs" < 100, "Configuration loading too slow");
    
    writeln("✅ Performance test passed");
}

