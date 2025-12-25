module infrastructure.migration.systems.dub;

import std.json;
import std.string;
import std.array;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for D dub.json/dub.sdl files
final class DubMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "dub"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["dub.json", "dub.sdl"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        auto name = baseName(filePath);
        return name == "dub.json" || name == "dub.sdl";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates D dub.json/dub.sdl to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Package name and type",
            "Source paths",
            "Dependencies",
            "Build configurations"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "SDL format requires manual conversion to JSON first",
            "Sub-packages need separate migration",
            "Build types need manual configuration"
        ];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system
    {
        import std.path : extension;
        
        auto contentResult = readInputFile(inputPath);
        if (contentResult.isErr)
            return BuildResult!MigrationResult.err(contentResult.unwrapErr());
        
        auto content = contentResult.unwrap();
        
        // Only support JSON for now
        if (extension(inputPath) == ".sdl")
        {
            return BuildResult!MigrationResult.err(
                migrationError("SDL format not yet supported - convert to dub.json first", inputPath));
        }
        
        MigrationTarget[] targets;
        MigrationWarning[] warnings;
        
        try
        {
            JSONValue dub = parseJSON(content);
            
            string name = "name" in dub ? dub["name"].str : "app";
            string targetType = "targetType" in dub ? dub["targetType"].str : "executable";
            
            MigrationTarget target;
            target.name = name;
            target.language = TargetLanguage.D;
            
            if (targetType == "executable" || targetType == "autodetect")
                target.type = TargetType.Executable;
            else if (targetType == "library" || targetType == "staticLibrary" || 
                     targetType == "dynamicLibrary")
                target.type = TargetType.Library;
            else
                target.type = TargetType.Custom;
            
            // Parse source paths
            if ("sourcePaths" in dub)
            {
                foreach (path; dub["sourcePaths"].array)
                {
                    target.sources ~= path.str ~ "/**/*.d";
                }
            }
            else
            {
                target.sources = ["source/**/*.d"];
            }
            
            // Parse dependencies
            if ("dependencies" in dub)
            {
                auto deps = dub["dependencies"].object;
                foreach (depName, depVer; deps)
                {
                    warnings ~= MigrationWarning(WarningLevel.Info,
                        "DUB dependency: " ~ depName,
                        "Ensure dependency is available");
                }
            }
            
            targets ~= target;
        }
        catch (JSONException e)
        {
            return BuildResult!MigrationResult.err(
                migrationError("Invalid JSON in dub.json: " ~ e.msg, inputPath));
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
}

