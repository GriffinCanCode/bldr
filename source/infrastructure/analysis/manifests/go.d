module infrastructure.analysis.manifests.go;

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

/// Parser for go.mod
final class GoManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!ManifestInfo.err(
                manifestNotFoundError(filePath, "go"));
        
        try
        {
            string content = readText(filePath);
            ManifestInfo info;
            info.language = TargetLanguage.Go;
            
            // Extract module name
            auto nameMatch = matchFirst(content, regex(`module\s+([^\s]+)`));
            info.name = nameMatch.empty ? "app" : baseName(nameMatch[1]);
            
            // Extract Go version
            auto versionMatch = matchFirst(content, regex(`go\s+(\d+\.\d+)`));
            info.version_ = versionMatch.empty ? "1.21" : versionMatch[1];
            info.metadata["go_version"] = info.version_;
            
            // Entry points - Go typically uses package main
            string dir = dirName(filePath);
            info.entryPoints = detectGoEntryPoints(dir);
            info.sources = ["*.go", "**/*.go", "!**/*_test.go"];
            info.tests = ["**/*_test.go"];
            
            // Parse dependencies
            info.dependencies = parseGoDependencies(content);
            
            // Detect framework
            string framework = detectGoFramework(info.dependencies);
            if (!framework.empty)
                info.metadata["framework"] = framework;
            
            // Go programs are typically executables
            info.suggestedType = hasMainPackage(dir) ? TargetType.Executable : TargetType.Library;
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "go", e.msg));
        }
    }
    
    override bool canParse(string filePath) const @safe
    {
        return baseName(filePath) == "go.mod";
    }
    
    override string name() const pure nothrow @safe
    {
        return "go";
    }
    
    private string[] detectGoEntryPoints(string dir) const
    {
        // Check for main.go in various locations
        string[] candidates = [
            buildPath(dir, "main.go"),
            buildPath(dir, "cmd/main.go"),
            buildPath(dir, "cmd", baseName(dir), "main.go")
        ];
        
        string[] found;
        foreach (candidate; candidates)
            if (exists(candidate))
                found ~= candidate;
        
        return found.empty ? ["main.go"] : found;
    }
    
    private bool hasMainPackage(string dir) const
    {
        // Check if any .go file contains "package main"
        import std.file : dirEntries, SpanMode;
        try
        {
            foreach (string name; dirEntries(dir, "*.go", SpanMode.shallow))
            {
                string content = readText(name);
                if (content.canFind("package main"))
                    return true;
            }
        }
        catch (Exception e) {}
        
        return false;
    }
    
    private Dependency[] parseGoDependencies(string content) const
    {
        Dependency[] deps;
        
        // Find require block
        auto requireStart = content.indexOf("require (");
        if (requireStart < 0)
        {
            // Single-line require
            auto singleMatch = matchFirst(content, regex(`require\s+([^\s]+)\s+([^\s]+)`));
            if (!singleMatch.empty)
            {
                Dependency dep;
                dep.name = singleMatch[1];
                dep.version_ = singleMatch[2];
                dep.type = DependencyType.Runtime;
                deps ~= dep;
            }
            return deps;
        }
        
        // Multi-line require block
        auto requireEnd = content.indexOf(")", requireStart);
        if (requireEnd < 0)
            return deps;
        
        string requireBlock = content[requireStart + 9 .. requireEnd];
        auto re = regex(`^\s*([^\s]+)\s+([^\s/]+)(?:\s*//\s*indirect)?`, "m");
        
        foreach (match; matchAll(requireBlock, re))
        {
            Dependency dep;
            dep.name = match[1];
            dep.version_ = match[2];
            dep.type = DependencyType.Runtime;
            deps ~= dep;
        }
        
        return deps;
    }
    
    private string detectGoFramework(in Dependency[] deps) const
    {
        foreach (dep; deps)
        {
            if (dep.name.canFind("gin-gonic/gin")) return "gin";
            if (dep.name.canFind("labstack/echo")) return "echo";
            if (dep.name.canFind("gofiber/fiber")) return "fiber";
            if (dep.name.canFind("gorilla/mux")) return "gorilla";
        }
        return "";
    }
}

