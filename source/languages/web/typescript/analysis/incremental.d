module languages.web.typescript.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import std.json;
import engine.compilation.incremental.analyzer;
import infrastructure.utils.logging;
import infrastructure.errors;

/// TypeScript incremental dependency analyzer
/// Uses TypeScript's import/export system for dependency tracking
final class TypeScriptDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string projectRoot;
    private JSONValue tsConfig;
    private bool tsConfigLoaded;
    private string[] baseUrls;
    
    this(string projectRoot) @system
    {
        this.projectRoot = projectRoot;
        this.tsConfigLoaded = false;
        
        // Node modules are external
        this.systemPaths = [
            "node_modules"
        ];
        
        loadTsConfig();
    }
    
    /// Analyze TypeScript import dependencies
    override BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] additionalSearchPaths = []
    ) @system
    {
        if (!exists(sourceFile) || !isFile(sourceFile))
        {
            return BuildResult!(string[]).err(
                Errors.generic("Source file not found: " ~ sourceFile, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        try
        {
            auto imports = parseTsImports(sourceFile);
            
            string[] resolvedDeps;
            string sourceDir = dirName(sourceFile);
            
            foreach (importPath; imports)
            {
                if (isExternalDependency(importPath))
                {
                    structuredLog.debug_("__external_").field("detail", "  [External] " ~ importPath).emit();
                    continue;
                }
                
                string resolved = resolveTsImport(importPath, sourceDir);
                
                if (!resolved.empty && exists(resolved))
                {
                    resolvedDeps ~= buildNormalizedPath(resolved);
                    structuredLog.debug_("__resolved_").field("detail", "  [Resolved] " ~ importPath ~ " -> " ~ resolved).emit();
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze TypeScript dependencies for " ~ 
                             sourceFile ~ ": " ~ e.msg,
                             ErrorCode.AnalysisFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if import is external (node_modules, built-in modules)
    override bool isExternalDependency(string importPath) @system
    {
        // Relative imports are local
        if (importPath.startsWith("./") || importPath.startsWith("../"))
            return false;
        
        // Absolute imports from node_modules
        if (!importPath.startsWith("/"))
            return true;
        
        // Check system paths
        return super.isExternalDependency(importPath);
    }
    
    private void loadTsConfig() @system
    {
        try
        {
            string tsConfigPath = buildPath(projectRoot, "tsconfig.json");
            if (!exists(tsConfigPath))
                return;
            
            auto content = readText(tsConfigPath);
            tsConfig = parseJSON(content);
            tsConfigLoaded = true;
            
            // Extract baseUrl if present
            if ("compilerOptions" in tsConfig)
            {
                auto options = tsConfig["compilerOptions"];
                if ("baseUrl" in options)
                {
                    baseUrls ~= buildPath(projectRoot, options["baseUrl"].str);
                }
                
                // Also check paths configuration
                if ("paths" in options)
                {
                    // Paths are more complex, would need full resolution logic
                    structuredLog.debug_("typescript_paths_configuration_detected").emit();
                }
            }
            
            structuredLog.debug_("loaded_typescript_configuration").emit();
        }
        catch (Exception e)
        {
            structuredLog.debug_("failed_to_load_tsconfigjson_").field("detail", "Failed to load tsconfig.json: " ~ e.msg).emit();
        }
    }
    
    private string[] parseTsImports(string sourceFile) @system
    {
        string[] imports;
        
        auto content = readText(sourceFile);
        
        // import ... from "path"
        auto importRegex = regex(`import\s+(?:[\w{},\s*]+\s+from\s+)?['"]([^'"]+)['"]`, "gm");
        foreach (match; matchAll(content, importRegex))
        {
            if (match.length > 1)
                imports ~= match[1];
        }
        
        // require("path")
        auto requireRegex = regex(`require\s*\(\s*['"]([^'"]+)['"]\s*\)`, "gm");
        foreach (match; matchAll(content, requireRegex))
        {
            if (match.length > 1)
                imports ~= match[1];
        }
        
        // export ... from "path"
        auto exportRegex = regex(`export\s+(?:[\w{},\s*]+\s+from\s+)?['"]([^'"]+)['"]`, "gm");
        foreach (match; matchAll(content, exportRegex))
        {
            if (match.length > 1)
                imports ~= match[1];
        }
        
        // Dynamic imports: import("path")
        auto dynamicRegex = regex(`import\s*\(\s*['"]([^'"]+)['"]\s*\)`, "gm");
        foreach (match; matchAll(content, dynamicRegex))
        {
            if (match.length > 1)
                imports ~= match[1];
        }
        
        return imports.sort().uniq().array;
    }
    
    private string resolveTsImport(string importPath, string sourceDir) @system
    {
        // Relative import
        if (importPath.startsWith("./") || importPath.startsWith("../"))
        {
            return resolveTsFile(buildPath(sourceDir, importPath));
        }
        
        // Absolute or baseUrl import
        foreach (baseUrl; baseUrls)
        {
            string resolved = resolveTsFile(buildPath(baseUrl, importPath));
            if (!resolved.empty)
                return resolved;
        }
        
        // Try project root
        return resolveTsFile(buildPath(projectRoot, importPath));
    }
    
    private string resolveTsFile(string basePath) @system
    {
        // Try extensions in order
        static immutable string[] extensions = [".ts", ".tsx", ".d.ts", ".js", ".jsx"];
        
        foreach (ext; extensions)
        {
            string withExt = basePath ~ ext;
            if (exists(withExt))
                return withExt;
        }
        
        // Try index files
        foreach (ext; extensions)
        {
            string indexFile = buildPath(basePath, "index" ~ ext);
            if (exists(indexFile))
                return indexFile;
        }
        
        // Try exact path
        if (exists(basePath))
            return basePath;
        
        return "";
    }
}

/// TypeScript incremental compilation helper
struct TypeScriptIncrementalHelper
{
    /// Find affected sources when a module changes
    static string[] findAffectedSources(
        string changedFile,
        string[] allSources,
        TypeScriptDependencyAnalyzer analyzer
    ) @system
    {
        string[] affected;
        string normalizedChanged = buildNormalizedPath(changedFile);
        
        foreach (source; allSources)
        {
            auto depsResult = analyzer.analyzeDependencies(source);
            if (depsResult.isErr)
                continue;
            
            auto deps = depsResult.unwrap();
            
            if (deps.canFind(normalizedChanged))
            {
                affected ~= source;
                structuredLog.debug_("__").field("detail", "  " ~ source ~ " affected by " ~ changedFile).emit();
            }
        }
        
        return affected;
    }
}

