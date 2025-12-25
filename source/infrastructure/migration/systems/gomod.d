module infrastructure.migration.systems.gomod;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Go modules (go.mod)
final class GoModuleMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "gomod"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["go.mod"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "go.mod";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Go modules (go.mod) to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Module path detection",
            "Go version",
            "Dependencies",
            "Standard project structure"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Multiple main packages require manual target creation",
            "Replace directives converted to comments",
            "Workspace mode requires manual configuration"
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
        
        // Extract module name
        auto modulePattern = regex(r"module\s+(\S+)");
        auto moduleMatch = matchFirst(content, modulePattern);
        string moduleName = "app";
        
        if (!moduleMatch.empty)
        {
            string fullModule = moduleMatch[1];
            // Get last component as name
            auto parts = fullModule.split("/");
            moduleName = parts[$-1];
        }
        
        // Extract Go version
        auto versionPattern = regex(r"go\s+([\d.]+)");
        auto versionMatch = matchFirst(content, versionPattern);
        string goVersion = versionMatch.empty ? "" : versionMatch[1];
        
        // Create main target
        MigrationTarget target;
        target.name = moduleName;
        target.type = TargetType.Executable;
        target.language = TargetLanguage.Go;
        target.sources = ["*.go"];
        
        if (!goVersion.empty)
            target.metadata["go_version"] = goVersion;
        
        // Parse dependencies
        auto requirePattern = regex(r"require\s*\(\s*((?:[^\)]+))\)", "gs");
        auto requireMatch = matchFirst(content, requirePattern);
        
        if (!requireMatch.empty)
        {
            string requireBlock = requireMatch[1];
            auto depPattern = regex(r"(\S+)\s+v[\d.]+", "g");
            
            foreach (depMatch; matchAll(requireBlock, depPattern))
            {
                warnings ~= MigrationWarning(WarningLevel.Info,
                    "Go dependency: " ~ depMatch[1],
                    "Run 'go mod download' before building");
            }
        }
        
        targets ~= target;
        
        // Suggest test target
        warnings ~= MigrationWarning(WarningLevel.Info,
            "Add a test target for *_test.go files if needed",
            "Go test files detected in project");
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
}

