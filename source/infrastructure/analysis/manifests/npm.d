module infrastructure.analysis.manifests.npm;

import std.json;
import std.string;
import std.array;
import std.algorithm;
import std.path : baseName, dirName, buildPath;
import std.file : readText, isFile, exists;
import infrastructure.analysis.manifests.types;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Parser for package.json (npm/yarn/pnpm)
final class NpmManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!ManifestInfo.err(
                manifestNotFoundError(filePath, "npm"));
        
        try
        {
            string content = readText(filePath);
            JSONValue pkg = parseJSON(content);
            
            ManifestInfo info;
            info.name = "name" in pkg ? pkg["name"].str : "app";
            info.version_ = "version" in pkg ? pkg["version"].str : "0.0.0";
            
            // Detect language (TypeScript vs JavaScript)
            bool isTypeScript = detectTypeScript(pkg);
            info.language = isTypeScript ? TargetLanguage.TypeScript : TargetLanguage.JavaScript;
            
            // Extract entry points
            info.entryPoints = extractEntryPoints(pkg, isTypeScript);
            
            // Extract source patterns
            info.sources = extractSourcePatterns(pkg, isTypeScript);
            
            // Extract test patterns
            info.tests = extractTestPatterns(pkg, isTypeScript);
            
            // Parse dependencies
            info.dependencies = extractDependencies(pkg);
            
            // Parse scripts
            info.scripts = extractScripts(pkg);
            
            // Suggest target type
            info.suggestedType = inferTargetType(pkg, info.dependencies);
            
            // Store additional metadata
            info.metadata = extractMetadata(pkg);
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (JSONException e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "npm", "Invalid JSON: " ~ e.msg));
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "npm", e.msg));
        }
    }
    
    override bool canParse(string filePath) const @safe
    {
        return baseName(filePath) == "package.json";
    }
    
    override string name() const pure nothrow @safe
    {
        return "npm";
    }
    
    private bool detectTypeScript(in JSONValue pkg) const
    {
        // Check dev dependencies
        if ("devDependencies" in pkg)
        {
            auto devDeps = pkg["devDependencies"].object;
            if ("typescript" in devDeps || "@types/node" in devDeps)
                return true;
        }
        
        // Check dependencies
        if ("dependencies" in pkg)
        {
            auto deps = pkg["dependencies"].object;
            if ("typescript" in deps)
                return true;
        }
        
        // Check for tsconfig.json
        string dir = dirName(filePath);
        if (exists(buildPath(dir, "tsconfig.json")))
            return true;
        
        return false;
    }
    
    private string[] extractEntryPoints(in JSONValue pkg, bool isTypeScript) const
    {
        string[] entries;
        string ext = isTypeScript ? ".ts" : ".js";
        
        if ("main" in pkg)
            entries ~= pkg["main"].str;
        
        if ("module" in pkg)
            entries ~= pkg["module"].str;
        
        if ("browser" in pkg && pkg["browser"].type == JSONType.string)
            entries ~= pkg["browser"].str;
        
        // Fallback defaults
        if (entries.empty)
        {
            string[] defaults = [
                "src/index" ~ ext,
                "index" ~ ext,
                "src/main" ~ ext,
                "main" ~ ext
            ];
            entries = defaults;
        }
        
        return entries;
    }
    
    private string[] extractSourcePatterns(in JSONValue pkg, bool isTypeScript) const
    {
        string ext = isTypeScript ? "ts" : "js";
        
        // Check for explicit source directories
        if ("directories" in pkg && "lib" in pkg["directories"].object)
        {
            string libDir = pkg["directories"]["lib"].str;
            return [libDir ~ "/**/*." ~ ext];
        }
        
        // Default patterns
        return [
            "src/**/*." ~ ext,
            "lib/**/*." ~ ext,
            "*." ~ ext
        ];
    }
    
    private string[] extractTestPatterns(in JSONValue pkg, bool isTypeScript) const
    {
        string ext = isTypeScript ? "ts" : "js";
        
        // Check for explicit test directory
        if ("directories" in pkg && "test" in pkg["directories"].object)
        {
            string testDir = pkg["directories"]["test"].str;
            return [testDir ~ "/**/*." ~ ext];
        }
        
        // Common test patterns
        return [
            "test/**/*." ~ ext,
            "tests/**/*." ~ ext,
            "**/*.test." ~ ext,
            "**/*.spec." ~ ext,
            "__tests__/**/*." ~ ext
        ];
    }
    
    private Dependency[] extractDependencies(in JSONValue pkg) const
    {
        Dependency[] deps;
        
        // Runtime dependencies
        if ("dependencies" in pkg)
        {
            foreach (name, ver; pkg["dependencies"].object)
            {
                Dependency dep;
                dep.name = name;
                dep.version_ = ver.str;
                dep.type = DependencyType.Runtime;
                deps ~= dep;
            }
        }
        
        // Dev dependencies
        if ("devDependencies" in pkg)
        {
            foreach (name, ver; pkg["devDependencies"].object)
            {
                Dependency dep;
                dep.name = name;
                dep.version_ = ver.str;
                dep.type = DependencyType.Development;
                deps ~= dep;
            }
        }
        
        // Peer dependencies
        if ("peerDependencies" in pkg)
        {
            foreach (name, ver; pkg["peerDependencies"].object)
            {
                Dependency dep;
                dep.name = name;
                dep.version_ = ver.str;
                dep.type = DependencyType.Peer;
                deps ~= dep;
            }
        }
        
        // Optional dependencies
        if ("optionalDependencies" in pkg)
        {
            foreach (name, ver; pkg["optionalDependencies"].object)
            {
                Dependency dep;
                dep.name = name;
                dep.version_ = ver.str;
                dep.type = DependencyType.Optional;
                dep.optional = true;
                deps ~= dep;
            }
        }
        
        return deps;
    }
    
    private Script[string] extractScripts(in JSONValue pkg) const
    {
        Script[string] scripts;
        
        if ("scripts" !in pkg)
            return scripts;
        
        foreach (name, cmd; pkg["scripts"].object)
        {
            Script script;
            script.name = name;
            script.command = cmd.str;
            script.suggestedType = inferScriptType(name, cmd.str);
            scripts[name] = script;
        }
        
        return scripts;
    }
    
    private TargetType inferScriptType(string name, string command) const
    {
        if (name == "test" || name.startsWith("test:"))
            return TargetType.Test;
        else if (name == "build" || name == "compile")
            return TargetType.Executable;
        else if (name == "lint" || name == "format" || name == "check")
            return TargetType.Custom;
        else
            return TargetType.Custom;
    }
    
    private TargetType inferTargetType(in JSONValue pkg, in Dependency[] deps) const
    {
        // Check for framework dependencies
        bool hasReact = deps.any!(d => d.name == "react" || d.name == "react-dom");
        bool hasVue = deps.any!(d => d.name == "vue");
        bool hasAngular = deps.any!(d => d.name.startsWith("@angular"));
        bool hasExpress = deps.any!(d => d.name == "express");
        bool hasNext = deps.any!(d => d.name == "next");
        
        if (hasReact || hasVue || hasAngular || hasNext)
            return TargetType.Executable; // Frontend apps
        
        if (hasExpress)
            return TargetType.Executable; // Backend server
        
        // Check type field
        if ("type" in pkg && pkg["type"].str == "module")
            return TargetType.Library;
        
        // Check for library indicators
        if ("module" in pkg || "exports" in pkg)
            return TargetType.Library;
        
        // Default to executable
        return TargetType.Executable;
    }
    
    private string[string] extractMetadata(in JSONValue pkg) const
    {
        string[string] meta;
        
        if ("description" in pkg)
            meta["description"] = pkg["description"].str;
        
        if ("author" in pkg)
        {
            if (pkg["author"].type == JSONType.string)
                meta["author"] = pkg["author"].str;
            else if ("name" in pkg["author"].object)
                meta["author"] = pkg["author"]["name"].str;
        }
        
        if ("license" in pkg)
            meta["license"] = pkg["license"].str;
        
        if ("repository" in pkg)
        {
            if (pkg["repository"].type == JSONType.string)
                meta["repository"] = pkg["repository"].str;
            else if ("url" in pkg["repository"].object)
                meta["repository"] = pkg["repository"]["url"].str;
        }
        
        if ("type" in pkg)
            meta["type"] = pkg["type"].str;
        
        // Detect frameworks
        string framework = detectFramework(pkg);
        if (!framework.empty)
            meta["framework"] = framework;
        
        return meta;
    }
    
    private string detectFramework(in JSONValue pkg) const
    {
        if ("dependencies" !in pkg)
            return "";
        
        auto deps = pkg["dependencies"].object;
        
        if ("next" in deps) return "nextjs";
        if ("react" in deps || "react-dom" in deps) return "react";
        if ("vue" in deps) return "vue";
        if ("@angular/core" in deps) return "angular";
        if ("svelte" in deps) return "svelte";
        if ("express" in deps) return "express";
        
        if ("devDependencies" in pkg)
        {
            auto devDeps = pkg["devDependencies"].object;
            if ("vite" in devDeps)
            {
                if ("react" in deps) return "vite-react";
                if ("vue" in deps) return "vite-vue";
                return "vite";
            }
        }
        
        return "";
    }
    
    private string filePath; // Store for directory operations
}

