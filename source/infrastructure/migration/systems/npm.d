module infrastructure.migration.systems.npm;

import std.json;
import std.string;
import std.array;
import std.algorithm;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.analysis.manifests : DependencyType;

/// Migrator for npm package.json files
final class NpmMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "npm"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["package.json"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "package.json";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates npm package.json to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Main entry point",
            "Scripts (build, test, etc.)",
            "Dependencies",
            "TypeScript projects",
            "JavaScript projects"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex webpack/rollup configs need manual review",
            "Monorepo workspaces require separate migration",
            "NPM scripts are converted to Builder targets"
        ];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system
    {
        // Use the new manifest parser
        import infrastructure.analysis.manifests : NpmManifestParser;
        
        auto parser = new NpmManifestParser();
        auto parseResult = parser.parse(inputPath);
        
        if (parseResult.isErr)
            return BuildResult!MigrationResult.err(parseResult.unwrapErr());
        
        auto manifest = parseResult.unwrap();
        MigrationTarget[] targets;
        MigrationWarning[] warnings;
        
        // Create main build target from manifest
        MigrationTarget buildTarget;
        buildTarget.name = manifest.name;
        buildTarget.type = manifest.suggestedType;
        buildTarget.language = manifest.language;
        buildTarget.sources = manifest.entryPoints.length > 0 ? manifest.entryPoints : manifest.sources;
        buildTarget.output = "dist/" ~ manifest.name;
        
        targets ~= buildTarget;
        
        // Create test target if test scripts exist
        if ("test" in manifest.scripts)
        {
            MigrationTarget testTarget;
            testTarget.name = manifest.name ~ "-test";
            testTarget.type = TargetType.Test;
            testTarget.language = manifest.language;
            testTarget.sources = manifest.tests;
            testTarget.dependencies = [buildTarget.name];
            targets ~= testTarget;
        }
        
        // Add warnings about scripts
        foreach (scriptName, script; manifest.scripts)
        {
            if (scriptName != "build" && scriptName != "test" && scriptName != "start")
            {
                warnings ~= MigrationWarning(WarningLevel.Info,
                    "Script '" ~ scriptName ~ "' found: " ~ script.command,
                    "Consider creating a custom target if needed");
            }
        }
        
        // Note dependencies
        auto runtimeDeps = manifest.dependencies.filter!(d => d.type == DependencyType.Runtime).array;
        if (!runtimeDeps.empty)
        {
            warnings ~= MigrationWarning(WarningLevel.Info,
                "NPM dependencies: " ~ runtimeDeps.map!(d => d.name).join(", "),
                "Run 'npm install' before building");
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
}

