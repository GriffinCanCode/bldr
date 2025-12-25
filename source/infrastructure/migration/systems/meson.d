module infrastructure.migration.systems.meson;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Meson build files
final class MesonMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "meson"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["meson.build"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "meson.build";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Meson meson.build to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "executable() targets",
            "library() targets",
            "Source files",
            "Dependencies",
            "Include directories"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex Meson functions require manual review",
            "Custom targets need manual conversion",
            "Subprojects need separate migration"
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
        
        // Parse executable() calls
        auto execPattern = regex(r"executable\s*\(\s*'([^']+)'\s*,\s*([^)]+)\)", "g");
        foreach (match; matchAll(content, execPattern))
        {
            auto target = parseTarget(match[1], TargetType.Executable, match[2]);
            targets ~= target;
        }
        
        // Parse library() calls
        auto libPattern = regex(r"(?:static_|shared_)?library\s*\(\s*'([^']+)'\s*,\s*([^)]+)\)", "g");
        foreach (match; matchAll(content, libPattern))
        {
            auto target = parseTarget(match[1], TargetType.Library, match[2]);
            targets ~= target;
        }
        
        if (targets.length == 0)
        {
            return BuildResult!MigrationResult.err(
                migrationError("No valid Meson targets found", inputPath));
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private MigrationTarget parseTarget(string name, TargetType type, string args)
    {
        MigrationTarget target;
        target.name = name;
        target.type = type;
        target.language = TargetLanguage.C;  // Default, could be C++
        
        // Extract source files (simple pattern matching)
        auto sourcePattern = regex(r"'([^']+\.(c|cpp|cc|cxx))'", "g");
        foreach (match; matchAll(args, sourcePattern))
        {
            string source = match[1];
            target.sources ~= source;
            
            if (source.endsWith(".cpp") || source.endsWith(".cc") || source.endsWith(".cxx"))
                target.language = TargetLanguage.Cpp;
        }
        
        return target;
    }
}

