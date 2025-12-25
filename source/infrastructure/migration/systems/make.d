module infrastructure.migration.systems.make;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Makefile
final class MakeMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "make"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["Makefile", "makefile", "GNUmakefile"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        import std.uni : toLower;
        auto name = baseName(filePath).toLower();
        return name == "makefile" || name == "gnumakefile";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Makefile to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Simple compile targets",
            "Source file variables",
            "Compiler flags",
            "Target dependencies"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex Make functions require manual review",
            "Pattern rules need manual conversion",
            "Conditional logic needs adaptation",
            "Recursive Make requires restructuring"
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
        
        // Parse variable assignments
        string[string] variables = parseVariables(content);
        
        // Parse targets (target: dependencies)
        auto targetPattern = regex(r"^([a-zA-Z_][\w-]*)\s*:\s*([^\n]*)", "gm");
        
        foreach (match; matchAll(content, targetPattern))
        {
            string targetName = match[1];
            string depsLine = match[2];
            
            // Skip special targets
            if (targetName == "all" || targetName == "clean" || 
                targetName == ".PHONY" || targetName.startsWith("."))
                continue;
            
            MigrationTarget target;
            target.name = targetName;
            
            // Infer type from name patterns
            if (targetName.endsWith(".a") || targetName.endsWith(".so") ||
                targetName.indexOf("lib") >= 0)
                target.type = TargetType.Library;
            else if (targetName == "test" || targetName.indexOf("test") >= 0)
                target.type = TargetType.Test;
            else
                target.type = TargetType.Executable;
            
            // Infer language from compiler variables
            if ("CXX" in variables || "CXXFLAGS" in variables)
                target.language = TargetLanguage.Cpp;
            else if ("CC" in variables || "CFLAGS" in variables)
                target.language = TargetLanguage.C;
            else
                target.language = TargetLanguage.Generic;
            
            // Parse sources from common variable patterns
            if ("SOURCES" in variables)
                target.sources = variables["SOURCES"].split();
            else if ("SRCS" in variables)
                target.sources = variables["SRCS"].split();
            else if ("SRC" in variables)
                target.sources = variables["SRC"].split();
            
            // Parse flags
            if ("CXXFLAGS" in variables)
                target.flags = variables["CXXFLAGS"].split();
            else if ("CFLAGS" in variables)
                target.flags = variables["CFLAGS"].split();
            
            // Parse dependencies (other targets)
            auto deps = depsLine.split().filter!(d => !d.endsWith(".o") && 
                                                       !d.endsWith(".c") && 
                                                       !d.endsWith(".cpp")).array;
            target.dependencies = deps;
            
            target.output = targetName;
            
            if (target.sources.length > 0)
                targets ~= target;
        }
        
        if (targets.length == 0)
        {
            warnings ~= MigrationWarning(WarningLevel.Warning,
                "No standard targets found in Makefile",
                "Manual review required - Makefile may use complex patterns");
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = targets.length > 0;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private string[string] parseVariables(string content)
    {
        string[string] vars;
        auto varPattern = regex(r"^([A-Z_]+)\s*[:=]\s*([^\n]+)", "gm");
        
        foreach (match; matchAll(content, varPattern))
        {
            vars[match[1]] = match[2].strip();
        }
        
        return vars;
    }
}

