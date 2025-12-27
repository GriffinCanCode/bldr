module infrastructure.migration.systems.cmake;

import std.regex;
import std.string;
import std.array;
import std.algorithm;
import std.uni : toLower;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Migrator for CMake CMakeLists.txt files
final class CMakeMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "cmake"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["CMakeLists.txt"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath).toLower() == "cmakelists.txt";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates CMake CMakeLists.txt files to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "add_executable",
            "add_library (STATIC, SHARED, MODULE)",
            "target_sources",
            "target_link_libraries",
            "target_include_directories",
            "target_compile_options",
            "set_target_properties"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex CMake scripting requires manual review",
            "Generator expressions not fully supported",
            "Custom commands need manual conversion",
            "External project integration requires adaptation"
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
        string[string] targetData;  // Store target info for multi-line commands
        
        // Parse add_executable
        auto execPattern = regex(`add_executable\s*\(\s*(\w+)\s+([^)]+)\)`, "gi");
        foreach (match; matchAll(content, execPattern))
        {
            auto target = createTarget(match[1], TargetType.Executable, 
                parseSources(match[2]));
            targets ~= target;
            targetData[target.name] = "executable";
        }
        
        // Parse add_library
        auto libPattern = regex(`add_library\s*\(\s*(\w+)\s+(?:STATIC|SHARED|MODULE)?\s*([^)]+)\)`, "gi");
        foreach (match; matchAll(content, libPattern))
        {
            auto target = createTarget(match[1], TargetType.Library, 
                parseSources(match[2]));
            targets ~= target;
            targetData[target.name] = "library";
        }
        
        // Parse target_link_libraries for dependencies
        auto linkPattern = regex(`target_link_libraries\s*\(\s*(\w+)\s+([^)]+)\)`, "gi");
        foreach (match; matchAll(content, linkPattern))
        {
            string targetName = match[1];
            auto deps = parseDependencies(match[2]);
            
            foreach (ref target; targets)
            {
                if (target.name == targetName)
                {
                    target.dependencies ~= deps;
                    break;
                }
            }
        }
        
        // Parse target_include_directories
        auto includePattern = regex(`target_include_directories\s*\(\s*(\w+)\s+(?:PUBLIC|PRIVATE|INTERFACE)?\s*([^)]+)\)`, "gi");
        foreach (match; matchAll(content, includePattern))
        {
            string targetName = match[1];
            auto includes = parseIncludes(match[2]);
            
            foreach (ref target; targets)
            {
                if (target.name == targetName)
                {
                    target.includes ~= includes;
                    break;
                }
            }
        }
        
        // Parse target_compile_options
        auto optionsPattern = regex(`target_compile_options\s*\(\s*(\w+)\s+(?:PUBLIC|PRIVATE|INTERFACE)?\s*([^)]+)\)`, "gi");
        foreach (match; matchAll(content, optionsPattern))
        {
            string targetName = match[1];
            auto flags = parseFlags(match[2]);
            
            foreach (ref target; targets)
            {
                if (target.name == targetName)
                {
                    target.flags ~= flags;
                    break;
                }
            }
        }
        
        if (targets.length == 0)
        {
            return BuildResult!MigrationResult.err(
                migrationError("No valid CMake targets found", inputPath));
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private MigrationTarget createTarget(string name, TargetType type, string[] sources)
    {
        MigrationTarget target;
        target.name = name;
        target.type = type;
        target.language = inferLanguageFromSources(sources);
        target.sources = sources;
        return target;
    }
    
    private string[] parseSources(string sourcesStr)
    {
        return sourcesStr.split().filter!(s => s.length > 0 && !SIMDStrings.startsWith(s, "$")).array;
    }
    
    private string[] parseDependencies(string depsStr)
    {
        return depsStr.split()
            .filter!(s => s.length > 0 && !SIMDStrings.startsWith(s, "$") && 
                     s != "PUBLIC" && s != "PRIVATE" && s != "INTERFACE")
            .array;
    }
    
    private string[] parseIncludes(string includesStr)
    {
        return includesStr.split()
            .filter!(s => s.length > 0 && !SIMDStrings.startsWith(s, "$") && 
                     s != "PUBLIC" && s != "PRIVATE" && s != "INTERFACE")
            .array;
    }
    
    private string[] parseFlags(string flagsStr)
    {
        // Remove quotes and split
        return flagsStr.replace("\"", "").split()
            .filter!(s => s.length > 0 && !SIMDStrings.startsWith(s, "$"))
            .array;
    }
    
    private TargetLanguage inferLanguageFromSources(string[] sources)
    {
        foreach (source; sources)
        {
            if (SIMDStrings.endsWith(source, ".cpp") || SIMDStrings.endsWith(source, ".cc") || SIMDStrings.endsWith(source, ".cxx"))
                return TargetLanguage.Cpp;
            if (SIMDStrings.endsWith(source, ".c"))
                return TargetLanguage.C;
        }
        return TargetLanguage.Cpp;  // Default for CMake
    }
}

