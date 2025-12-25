module infrastructure.analysis.manifests.composer;

import std.json;
import std.path : baseName;
import std.file : readText, isFile, exists;
import infrastructure.analysis.manifests.types;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Parser for composer.json (PHP)
final class ComposerManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!ManifestInfo.err(
                manifestNotFoundError(filePath, "composer"));
        
        try
        {
            string content = readText(filePath);
            JSONValue composer = parseJSON(content);
            
            ManifestInfo info;
            info.language = TargetLanguage.PHP;
            info.name = "name" in composer ? composer["name"].str : "app";
            info.version_ = "version" in composer ? composer["version"].str : "1.0.0";
            info.suggestedType = TargetType.Executable;
            info.sources = ["src/**/*.php", "*.php"];
            info.tests = ["tests/**/*.php"];
            
            // Parse dependencies
            if ("require" in composer)
            {
                foreach (name, ver; composer["require"].object)
                {
                    if (name != "php") // Skip PHP version
                    {
                        Dependency dep;
                        dep.name = name;
                        dep.version_ = ver.str;
                        dep.type = DependencyType.Runtime;
                        info.dependencies ~= dep;
                    }
                }
            }
            
            // Dev dependencies
            if ("require-dev" in composer)
            {
                foreach (name, ver; composer["require-dev"].object)
                {
                    Dependency dep;
                    dep.name = name;
                    dep.version_ = ver.str;
                    dep.type = DependencyType.Development;
                    info.dependencies ~= dep;
                }
            }
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "composer", e.msg));
        }
    }
    
    override bool canParse(string filePath) const @safe
    {
        return baseName(filePath) == "composer.json";
    }
    
    override string name() const pure nothrow @safe
    {
        return "composer";
    }
}

