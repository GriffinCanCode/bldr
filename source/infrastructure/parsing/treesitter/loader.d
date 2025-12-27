module infrastructure.parsing.treesitter.loader;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.json;
import std.path;
import engine.caching.incremental.ast_dependency;
import infrastructure.parsing.treesitter.config;
import infrastructure.utils.logging;
import infrastructure.errors;

/// JSON-based language configuration loader
/// Loads language configs from JSON files in configs directory
final class ConfigLoader {
    private string configDir;
    
    this(string configDir = "") @safe {
        if (configDir.empty) {
            // Default to source/infrastructure/parsing/configs
            import std.process : environment;
            auto builderRoot = environment.get("BUILDER_ROOT", "");
            if (!builderRoot.empty)
                this.configDir = buildPath(builderRoot, "source/infrastructure/parsing/configs");
            else
                this.configDir = "source/infrastructure/parsing/configs";
        } else {
            this.configDir = configDir;
        }
    }
    
    /// Load all available language configurations from JSON files
    LanguageConfig[] loadAll() @system {
        LanguageConfig[] configs;
        
        if (!exists(configDir) || !isDir(configDir)) {
            structuredLog.warning("config_directory_not_found_").field("detail", "Config directory not found: " ~ configDir).emit();
            return configs;
        }
        
        try {
            foreach (entry; dirEntries(configDir, "*.json", SpanMode.shallow)) {
                if (!entry.isFile)
                    continue;
                
                try {
                    auto config = loadFromJSON(entry.name);
                    if (!config.languageId.empty)
                        configs ~= config;
                } catch (Exception e) {
                    structuredLog.warning("failed_to_load_config_").field("detail", "Failed to load config " ~ entry.name ~ ": " ~ e.msg).emit();
                }
            }
        } catch (Exception e) {
            structuredLog.warning("failed_to_scan_config_directory_").field("detail", "Failed to scan config directory: " ~ e.msg).emit();
        }
        
        structuredLog.info("loaded_").field("detail", "Loaded " ~ configs.length.to!string ~ " tree-sitter language configs").emit();
        return configs;
    }
    
    /// Load a single language configuration from JSON
    LanguageConfig loadFromJSON(string jsonPath) @system {
        auto content = readText(jsonPath);
        auto json = parseJSON(content);
        
        LanguageConfig config;
        
        // Parse language metadata
        if ("language" in json) {
            auto lang = json["language"];
            config.languageId = lang["id"].str;
            config.displayName = lang["display"].str;
            
            if ("extensions" in lang) {
                foreach (ext; lang["extensions"].array)
                    config.extensions ~= ext.str;
            }
        }
        
        // Parse node type mappings
        if ("node_types" in json) {
            foreach (nodeType, symbolType; json["node_types"].object) {
                config.nodeTypeMap[nodeType] = parseSymbolType(symbolType.str);
            }
        }
        
        // Parse imports
        if ("imports" in json) {
            auto imports = json["imports"];
            if ("node_types" in imports) {
                foreach (nt; imports["node_types"].array)
                    config.importNodeTypes ~= nt.str;
            }
            if ("patterns" in imports) {
                foreach (nodeType, fieldName; imports["patterns"].object)
                    config.dependencies.importPatterns[nodeType] = fieldName.str;
            }
        }
        
        // Parse skip nodes
        if ("skip_nodes" in json) {
            foreach (skip; json["skip_nodes"].array)
                config.skipNodeTypes ~= skip.str;
        }
        
        // Parse visibility rules
        if ("visibility" in json) {
            auto vis = json["visibility"];
            if ("default" in vis) {
                auto defaultVis = vis["default"].str;
                config.visibility.defaultPublic = (defaultVis == "public");
            }
            if ("modifiers" in vis) {
                auto mods = vis["modifiers"];
                if ("public" in mods) {
                    foreach (mod; mods["public"].array)
                        config.visibility.publicModifiers ~= mod.str;
                }
                if ("private" in mods) {
                    foreach (mod; mods["private"].array)
                        config.visibility.privateModifiers ~= mod.str;
                }
            }
            if ("patterns" in vis) {
                auto patterns = vis["patterns"];
                if ("public" in patterns)
                    config.visibility.publicNamePattern = patterns["public"].str;
                if ("private" in patterns)
                    config.visibility.privateNamePattern = patterns["private"].str;
            }
            if ("modifier_nodes" in vis) {
                foreach (node; vis["modifier_nodes"].array)
                    config.visibility.modifierNodeTypes ~= node.str;
            }
        }
        
        // Parse dependency patterns
        if ("dependencies" in json) {
            auto deps = json["dependencies"];
            if ("type_nodes" in deps) {
                foreach (tn; deps["type_nodes"].array)
                    config.dependencies.typeUsageNodeTypes ~= tn.str;
            }
            if ("member_nodes" in deps) {
                foreach (mn; deps["member_nodes"].array)
                    config.dependencies.memberAccessNodeTypes ~= mn.str;
            }
        }
        
        return config;
    }
    
    private SymbolType parseSymbolType(string typeName) @safe {
        switch (typeName) {
            case "Class": return SymbolType.Class;
            case "Struct": return SymbolType.Struct;
            case "Function": return SymbolType.Function;
            case "Method": return SymbolType.Method;
            case "Field": return SymbolType.Field;
            case "Enum": return SymbolType.Enum;
            case "Typedef": return SymbolType.Typedef;
            case "Namespace": return SymbolType.Namespace;
            case "Template": return SymbolType.Template;
            case "Variable": return SymbolType.Variable;
            default: return SymbolType.Function;  // Fallback
        }
    }
}

