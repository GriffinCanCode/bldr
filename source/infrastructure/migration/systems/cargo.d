module infrastructure.migration.systems.cargo;

import std.json;
import std.string;
import std.array;
import std.algorithm;
import std.file : readText;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.analysis.manifests : DependencyType;

/// Migrator for Rust Cargo.toml files
final class CargoMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "cargo"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["Cargo.toml"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "Cargo.toml";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Rust Cargo.toml to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Binary targets [[bin]]",
            "Library targets [lib]",
            "Test targets",
            "Dependencies",
            "Dev dependencies",
            "Build dependencies"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Cargo features require manual configuration",
            "Build scripts (build.rs) need manual review",
            "Workspace members need separate migration"
        ];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system
    {
        // Use the new manifest parser
        import infrastructure.analysis.manifests : CargoManifestParser;
        
        auto parser = new CargoManifestParser();
        auto parseResult = parser.parse(inputPath);
        
        if (parseResult.isErr)
            return BuildResult!MigrationResult.err(parseResult.unwrapErr());
        
        auto manifest = parseResult.unwrap();
        MigrationTarget[] targets;
        MigrationWarning[] warnings;
        
        // Create main target from manifest
        MigrationTarget target;
        target.name = manifest.name;
        target.type = manifest.suggestedType;
        target.language = manifest.language;
        target.sources = manifest.entryPoints.length > 0 ? manifest.entryPoints : manifest.sources;
        
        targets ~= target;
        
        // Add info about dev-dependencies
        auto devDeps = manifest.dependencies.filter!(d => d.type == DependencyType.Development).array;
        if (!devDeps.empty)
        {
            warnings ~= MigrationWarning(WarningLevel.Info,
                "Dev dependencies found: " ~ devDeps.map!(d => d.name).join(", "),
                "Add these to test target dependencies if needed");
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private string extractPackageName(string content)
    {
        import std.regex;
        auto pattern = regex(`name\s*=\s*"([^"]+)"`);
        auto match = matchFirst(content, pattern);
        return match.empty ? "app" : match[1];
    }
    
    private string[] parseCargoDependencies(string content)
    {
        return parseCargoSection(content, "[dependencies]");
    }
    
    private string[] parseCargoSection(string content, string section)
    {
        auto idx = content.indexOf(section);
        if (idx < 0)
            return [];
        
        // Find next section or end
        auto remaining = content[idx + section.length .. $];
        auto nextSection = remaining.indexOf("\n[");
        if (nextSection >= 0)
            remaining = remaining[0 .. nextSection];
        
        // Extract dependency names (simple line-by-line parsing)
        import std.regex;
        auto pattern = regex(`^(\w+)\s*=`, "m");
        string[] deps;
        
        foreach (match; matchAll(remaining, pattern))
        {
            deps ~= match[1];
        }
        
        return deps;
    }
}

