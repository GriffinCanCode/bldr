module languages.scripting.lua.analysis.dependencies;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.regex;
import std.string;
import infrastructure.utils.logging;

/// Dependency information
struct LuaDependency
{
    string moduleName;
    string sourcePath;
    bool isRelative;
    bool isOptional;
    int lineNumber;
}

/// Analyze Lua dependencies from source files
class LuaDependencyAnalyzer
{
    /// Analyze dependencies in a Lua source file
    static LuaDependency[] analyze(string sourceFile)
    {
        LuaDependency[] deps;
        
        if (!exists(sourceFile) || !isFile(sourceFile))
            return deps;
        
        try
        {
            auto content = readText(sourceFile);
            deps = parseRequires(content, sourceFile);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_analyze_dependencies_in_").field("detail", "Failed to analyze dependencies in " ~ sourceFile ~ ": " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Parse require() statements from Lua code
    private static LuaDependency[] parseRequires(string content, string sourcePath)
    {
        LuaDependency[] deps;
        
        // Split into lines for line number tracking
        auto lines = content.split("\n");
        
        foreach (lineNum, line; lines)
        {
            // Match various forms of require:
            // require("module")
            // require('module')
            // require [[module]]
            // local x = require("module")
            // local x = require 'module'
            
            // Standard require with quotes
            auto matches = matchAll(line, regex(`require\s*[\(\s]+["']([^"']+)["']`));
            foreach (match; matches)
            {
                LuaDependency dep;
                dep.moduleName = match[1];
                dep.sourcePath = sourcePath;
                dep.lineNumber = cast(int)(lineNum + 1);
                dep.isRelative = isRelativeModule(dep.moduleName);
                dep.isOptional = false;
                deps ~= dep;
            }
            
            // Long string format: require [[module]]
            auto longMatches = matchAll(line, regex(`require\s*\[\[([^\]]+)\]\]`));
            foreach (match; longMatches)
            {
                LuaDependency dep;
                dep.moduleName = match[1];
                dep.sourcePath = sourcePath;
                dep.lineNumber = cast(int)(lineNum + 1);
                dep.isRelative = isRelativeModule(dep.moduleName);
                dep.isOptional = false;
                deps ~= dep;
            }
            
            // Optional require (pcall)
            auto pcallMatches = matchAll(line, regex(`pcall\s*\(\s*require\s*,\s*["']([^"']+)["']`));
            foreach (match; pcallMatches)
            {
                LuaDependency dep;
                dep.moduleName = match[1];
                dep.sourcePath = sourcePath;
                dep.lineNumber = cast(int)(lineNum + 1);
                dep.isRelative = isRelativeModule(dep.moduleName);
                dep.isOptional = true;
                deps ~= dep;
            }
        }
        
        return deps;
    }
    
    /// Check if module name is relative (starts with . or ..)
    private static bool isRelativeModule(string moduleName)
    {
        return moduleName.startsWith(".") || moduleName.startsWith("..");
    }
    
    /// Resolve module name to file path
    static string resolveModule(string moduleName, string currentFile, string[] packagePaths = [])
    {
        // Convert module name to file path
        // e.g., "mylib.utils" -> "mylib/utils.lua"
        string modulePath = moduleName.replace(".", dirSeparator);
        
        // Try with .lua extension
        string[] searchPaths = [
            modulePath ~ ".lua",
            modulePath ~ dirSeparator ~ "init.lua",
        ];
        
        // If relative, search from current file directory
        if (isRelativeModule(moduleName))
        {
            auto currentDir = dirName(currentFile);
            
            foreach (searchPath; searchPaths)
            {
                auto fullPath = buildPath(currentDir, searchPath);
                if (exists(fullPath))
                {
                    return fullPath;
                }
            }
        }
        else
        {
            // Search in package paths
            string[] paths = packagePaths.dup;
            
            // Add default Lua package paths
            paths ~= ".";
            paths ~= "lua";
            paths ~= "lib";
            
            // Also check from current file directory
            auto currentDir = dirName(currentFile);
            paths ~= currentDir;
            
            foreach (basePath; paths)
            {
                foreach (searchPath; searchPaths)
                {
                    auto fullPath = buildPath(basePath, searchPath);
                    if (exists(fullPath))
                    {
                        return fullPath;
                    }
                }
            }
        }
        
        // Module not found locally (might be a LuaRocks module)
        return "";
    }
    
    /// Build full dependency tree
    static LuaDependency[] buildDependencyTree(string entryPoint, string[] packagePaths = [])
    {
        LuaDependency[] allDeps;
        bool[string] visited;
        
        void analyzeRecursive(string file)
        {
            if (file in visited)
                return;
            
            visited[file] = true;
            
            auto deps = analyze(file);
            allDeps ~= deps;
            
            // Recursively analyze dependencies
            foreach (dep; deps)
            {
                auto depPath = resolveModule(dep.moduleName, file, packagePaths);
                if (!depPath.empty && depPath !in visited)
                {
                    analyzeRecursive(depPath);
                }
            }
        }
        
        analyzeRecursive(entryPoint);
        
        return allDeps;
    }
    
    /// Get external (non-local) dependencies
    static string[] getExternalDependencies(LuaDependency[] deps, string projectRoot)
    {
        string[] external;
        
        foreach (dep; deps)
        {
            // Check if dependency is external (not in project)
            auto resolved = resolveModule(dep.moduleName, dep.sourcePath);
            
            if (resolved.empty || !resolved.startsWith(projectRoot))
            {
                // External dependency
                if (!external.canFind(dep.moduleName))
                {
                    external ~= dep.moduleName;
                }
            }
        }
        
        return external;
    }
}

