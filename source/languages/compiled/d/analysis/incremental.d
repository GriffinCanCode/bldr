module languages.compiled.d.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import engine.compilation.incremental.analyzer;
import languages.compiled.d.analysis.modules;
import infrastructure.utils.logging;
import infrastructure.errors;

/// D module incremental dependency analyzer
/// Extracts import dependencies and resolves them to source files
final class DDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string[] importPaths;
    private string projectRoot;
    
    this(string projectRoot, string[] importPaths = []) @system
    {
        this.projectRoot = projectRoot;
        this.importPaths = importPaths;
        
        // D standard library paths
        version(Posix)
        {
            this.systemPaths = [
                "/usr/include/dmd",
                "/usr/include/dlang",
                "/usr/local/include/dmd",
                "/opt/dmd/src"
            ];
        }
        version(Windows)
        {
            this.systemPaths = [
                "C:\\D\\dmd2\\src",
                "C:\\Program Files\\dmd\\src"
            ];
        }
    }
    
    /// Analyze D module dependencies
    override BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] additionalImportPaths = []
    ) @system
    {
        if (!exists(sourceFile) || !isFile(sourceFile))
        {
            return BuildResult!(string[]).err(
                Errors.generic("Source file not found: " ~ sourceFile, IO.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        try
        {
            // Parse import statements
            auto imports = parseImports(sourceFile);
            
            string[] resolvedDeps;
            auto allImportPaths = importPaths ~ additionalImportPaths ~ [projectRoot];
            
            foreach (importStmt; imports)
            {
                // Skip external/standard library dependencies
                if (isExternalDependency(importStmt))
                {
                    structuredLog.debug_("__external_").field("detail", "  [External] " ~ importStmt).emit();
                    continue;
                }
                
                // Resolve module name to file path
                string resolved = resolveModuleToFile(
                    importStmt,
                    allImportPaths
                );
                
                if (!resolved.empty && exists(resolved))
                {
                    resolvedDeps ~= buildNormalizedPath(resolved);
                    structuredLog.debug_("__resolved_").field("detail", "  [Resolved] " ~ importStmt ~ " -> " ~ resolved).emit();
                }
                else
                {
                    structuredLog.debug_("__not_found_").field("detail", "  [Not Found] " ~ importStmt).emit();
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze D dependencies for " ~ sourceFile ~ ": " ~ e.msg, Analysis.Failed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if module is external (Phobos, Druntime, third-party)
    override bool isExternalDependency(string moduleName) @system
    {
        // Standard D modules
        static immutable string[] stdModules = [
            "std", "core", "etc", "object"
        ];
        
        // Check if it starts with standard prefix
        foreach (prefix; stdModules)
        {
            if (moduleName.startsWith(prefix ~ "."))
                return true;
        }
        
        return super.isExternalDependency(moduleName);
    }
    
    /// Parse import statements from D source file
    private string[] parseImports(string sourceFile) @system
    {
        string[] imports;
        
        if (!exists(sourceFile))
            return imports;
        
        auto content = readText(sourceFile);
        
        // Regex for import statements
        // Matches: import module; import module : symbol; import module, module2;
        auto importRegex = regex(r"import\s+([\w\.]+(?:\s*,\s*[\w\.]+)*)\s*(?::\s*[^;]+)?;", "gm");
        
        foreach (match; matchAll(content, importRegex))
        {
            if (match.length > 1)
            {
                // Handle multiple imports in one statement
                auto moduleList = match[1].split(",");
                foreach (mod; moduleList)
                {
                    auto trimmed = mod.strip;
                    if (!trimmed.empty)
                        imports ~= trimmed;
                }
            }
        }
        
        return imports;
    }
    
    /// Resolve D module name to file path
    /// e.g., "mypackage.mymodule" -> "/path/to/mypackage/mymodule.d"
    private string resolveModuleToFile(string moduleName, string[] searchPaths) @system
    {
        // Convert module path to file path
        // mypackage.mymodule -> mypackage/mymodule.d
        string relativePath = moduleName.replace(".", dirSeparator) ~ ".d";
        
        foreach (searchPath; searchPaths)
        {
            string fullPath = buildPath(searchPath, relativePath);
            if (exists(fullPath))
                return fullPath;
            
            // Also try package.d
            string packagePath = buildPath(searchPath, moduleName.replace(".", dirSeparator), "package.d");
            if (exists(packagePath))
                return packagePath;
        }
        
        return "";
    }
}

/// Helper for D incremental compilation
struct DIncrementalHelper
{
    /// Find all D source files that import a given module
    static string[] findAffectedSources(
        string changedFile,
        string[] allSources,
        DDependencyAnalyzer analyzer
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
    
    /// Build dependency graph for D project
    static string[][string] buildDependencyGraph(
        string[] sources,
        DDependencyAnalyzer analyzer
    ) @system
    {
        string[][string] graph;
        
        foreach (source; sources)
        {
            auto depsResult = analyzer.analyzeDependencies(source);
            if (depsResult.isOk)
            {
                graph[source] = depsResult.unwrap();
            }
        }
        
        return graph;
    }
}

