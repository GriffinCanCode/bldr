module infrastructure.analysis.manifests.cargo;

import std.string;
import std.array;
import std.algorithm;
import std.path : baseName, dirName, buildPath;
import std.file : readText, isFile, exists;
import std.regex;
import infrastructure.analysis.manifests.types;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Parser for Cargo.toml (Rust)
final class CargoManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!ManifestInfo.err(
                manifestNotFoundError(filePath, "cargo"));
        
        try
        {
            string content = readText(filePath);
            
            ManifestInfo info;
            info.language = TargetLanguage.Rust;
            info.name = extractValue(content, `name\s*=\s*"([^"]+)"`, "app");
            info.version_ = extractValue(content, `version\s*=\s*"([^"]+)"`, "0.1.0");
            
            // Determine target type based on presence of lib/bin
            bool hasLib = content.indexOf("[lib]") >= 0;
            bool hasBin = content.indexOf("[[bin]]") >= 0 || exists(buildPath(dirName(filePath), "src/main.rs"));
            
            if (hasLib && !hasBin)
            {
                info.suggestedType = TargetType.Library;
                info.entryPoints = ["src/lib.rs"];
                info.sources = ["src/lib.rs", "src/**/*.rs"];
            }
            else
            {
                info.suggestedType = TargetType.Executable;
                info.entryPoints = ["src/main.rs"];
                info.sources = ["src/main.rs", "src/**/*.rs"];
            }
            
            // Extract dependencies
            info.dependencies = extractCargoDependencies(content);
            
            // Extract metadata
            info.metadata["edition"] = extractValue(content, `edition\s*=\s*"([^"]+)"`, "2021");
            
            string description = extractValue(content, `description\s*=\s*"([^"]+)"`, "");
            if (!description.empty)
                info.metadata["description"] = description;
            
            string license = extractValue(content, `license\s*=\s*"([^"]+)"`, "");
            if (!license.empty)
                info.metadata["license"] = license;
            
            // Detect framework
            string framework = detectCargoFramework(info.dependencies);
            if (!framework.empty)
                info.metadata["framework"] = framework;
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "cargo", e.msg));
        }
    }
    
    override bool canParse(string filePath) const @safe
    {
        return baseName(filePath) == "Cargo.toml";
    }
    
    override string name() const pure nothrow @safe
    {
        return "cargo";
    }
    
    private string extractValue(string content, string pattern, string defaultValue) const
    {
        auto re = regex(pattern);
        auto match = matchFirst(content, re);
        return match.empty ? defaultValue : match[1];
    }
    
    private Dependency[] extractCargoDependencies(string content) const
    {
        Dependency[] deps;
        
        // Runtime dependencies
        deps ~= extractSection(content, "[dependencies]", DependencyType.Runtime);
        
        // Dev dependencies
        deps ~= extractSection(content, "[dev-dependencies]", DependencyType.Development);
        
        // Build dependencies
        deps ~= extractSection(content, "[build-dependencies]", DependencyType.Build);
        
        return deps;
    }
    
    private Dependency[] extractSection(string content, string section, DependencyType type) const
    {
        Dependency[] deps;
        
        auto idx = content.indexOf(section);
        if (idx < 0)
            return deps;
        
        // Extract section content until next section
        auto remaining = content[idx + section.length .. $];
        auto nextSection = remaining.indexOf("\n[");
        if (nextSection >= 0)
            remaining = remaining[0 .. nextSection];
        
        // Parse dependencies
        auto re = regex(`^(\w[\w\-]*)\s*=\s*(.+)$`, "m");
        foreach (match; matchAll(remaining, re))
        {
            Dependency dep;
            dep.name = match[1];
            dep.type = type;
            
            // Extract version
            string versionSpec = match[2].strip;
            if (versionSpec.startsWith("\""))
            {
                // Simple version: dep = "1.0"
                auto versionMatch = matchFirst(versionSpec, regex(`"([^"]+)"`));
                dep.version_ = versionMatch.empty ? "" : versionMatch[1];
            }
            else if (versionSpec.startsWith("{"))
            {
                // Complex spec: dep = { version = "1.0", features = [...] }
                auto versionMatch = matchFirst(versionSpec, regex(`version\s*=\s*"([^"]+)"`));
                dep.version_ = versionMatch.empty ? "" : versionMatch[1];
                
                // Check if optional
                dep.optional = versionSpec.indexOf("optional = true") >= 0;
            }
            
            deps ~= dep;
        }
        
        return deps;
    }
    
    private string detectCargoFramework(in Dependency[] deps) const
    {
        foreach (dep; deps)
        {
            switch (dep.name)
            {
                case "actix-web": return "actix";
                case "rocket": return "rocket";
                case "axum": return "axum";
                case "warp": return "warp";
                case "tokio": return "tokio-async";
                default: break;
            }
        }
        return "";
    }
}

