module infrastructure.migration.systems.bazel;

import std.regex;
import std.string;
import std.array;
import std.algorithm;
import std.conv;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Bazel BUILD files
final class BazelMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "bazel"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["BUILD", "BUILD.bazel"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        auto name = baseName(filePath);
        return name == "BUILD" || name == "BUILD.bazel";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Bazel BUILD files to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "cc_binary, cc_library (C/C++)",
            "py_binary, py_library (Python)",
            "go_binary, go_library (Go)",
            "java_binary, java_library (Java)",
            "rust_binary, rust_library (Rust)",
            "ts_project (TypeScript)",
            "Basic dependencies and sources",
            "Compiler flags (copts)",
            "Linker flags (linkopts)"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex Starlark macros require manual review",
            "Custom rules need manual conversion",
            "Aspect-based features not supported",
            "Transition functions require manual handling"
        ];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system
    {
        auto contentResult = readInputFile(inputPath);
        if (contentResult.isErr)
            return BuildResult!MigrationResult.err(contentResult.unwrapErr());
        
        auto content = contentResult.unwrap();
        MigrationTarget[] targets;
        MigrationWarning[] warnings;
        
        // Parse all rule calls (cc_binary, py_library, etc.)
        auto rulePattern = regex(`(\w+_(?:binary|library|test))\s*\(\s*name\s*=\s*"([^"]+)"([^)]*)\)`, "g");
        
        foreach (match; matchAll(content, rulePattern))
        {
            string ruleType = match[1];
            string name = match[2];
            string body = match[3];
            
            auto target = parseRule(ruleType, name, body, inputPath);
            
            if (target.name.length > 0)
                targets ~= target;
            else
                warnings ~= MigrationWarning(WarningLevel.Warning, 
                    "Could not parse rule: " ~ ruleType ~ " (" ~ name ~ ")", 
                    inputPath);
        }
        
        if (targets.length == 0)
        {
            return BuildResult!MigrationResult.err(
                migrationError("No valid Bazel rules found in BUILD file", inputPath));
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = !result.hasErrors();
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private MigrationTarget parseRule(string ruleType, string name, string body, string filePath)
    {
        MigrationTarget target;
        target.name = name;
        
        // Determine target type and language from rule type
        if (ruleType.endsWith("_binary"))
            target.type = TargetType.Executable;
        else if (ruleType.endsWith("_library"))
            target.type = TargetType.Library;
        else if (ruleType.endsWith("_test"))
            target.type = TargetType.Test;
        else
            target.type = TargetType.Custom;
        
        // Determine language
        if (ruleType.startsWith("cc_"))
            target.language = TargetLanguage.Cpp;
        else if (ruleType.startsWith("py_"))
            target.language = TargetLanguage.Python;
        else if (ruleType.startsWith("go_"))
            target.language = TargetLanguage.Go;
        else if (ruleType.startsWith("java_"))
            target.language = TargetLanguage.Java;
        else if (ruleType.startsWith("rust_"))
            target.language = TargetLanguage.Rust;
        else if (ruleType.startsWith("ts_"))
            target.language = TargetLanguage.TypeScript;
        else
            target.language = TargetLanguage.Generic;
        
        // Parse sources
        target.sources = parseStringArray(body, "srcs");
        
        // Parse dependencies
        target.dependencies = parseStringArray(body, "deps");
        
        // Parse compiler flags
        target.flags = parseStringArray(body, "copts");
        
        // Parse linker flags (add to metadata for manual review)
        auto linkopts = parseStringArray(body, "linkopts");
        if (linkopts.length > 0)
            target.metadata["linkopts"] = linkopts.join(" ");
        
        // Parse includes
        target.includes = parseStringArray(body, "includes");
        
        return target;
    }
    
    private string[] parseStringArray(string body, string attrName)
    {
        // Match: attrName = ["item1", "item2", ...]
        auto pattern = regex(attrName ~ `\s*=\s*\[([^\]]*)\]`);
        auto match = matchFirst(body, pattern);
        
        if (match.empty)
            return [];
        
        string items = match[1];
        auto itemPattern = regex(`"([^"]+)"`);
        string[] result;
        
        foreach (itemMatch; matchAll(items, itemPattern))
        {
            string item = itemMatch[1];
            // Convert Bazel target references to Builder format
            if (item.startsWith("//") || item.startsWith(":"))
                item = item.replace("//", "");  // Simplified conversion
            result ~= item;
        }
        
        return result;
    }
}

