module languages.scripting.go.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import std.process;
import engine.compilation.incremental.analyzer;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Go module incremental dependency analyzer
/// Uses Go's import system for dependency tracking
final class GoDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string moduleRoot;
    private string modulePath;  // e.g., github.com/user/project
    
    this(string moduleRoot) @system
    {
        this.moduleRoot = moduleRoot;
        this.modulePath = detectModulePath();
        
        // Go standard library
        this.systemPaths = [
            "GOROOT"  // Placeholder, actual path varies
        ];
    }
    
    /// Analyze Go import dependencies
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
            auto imports = parseGoImports(sourceFile);
            
            string[] resolvedDeps;
            
            foreach (importPath; imports)
            {
                if (isExternalDependency(importPath))
                {
                    structuredLog.debug_("__external_").field("detail", "  [External] " ~ importPath).emit();
                    continue;
                }
                
                // Resolve import to source files
                auto resolved = resolveGoImport(importPath);
                
                foreach (file; resolved)
                {
                    if (exists(file))
                    {
                        resolvedDeps ~= buildNormalizedPath(file);
                        structuredLog.debug_("__resolved_").field("detail", "  [Resolved] " ~ importPath ~ " -> " ~ file).emit();
                    }
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze Go dependencies for " ~ 
                             sourceFile ~ ": " ~ e.msg,
                             ErrorCode.AnalysisFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if import is external (standard library or third-party)
    override bool isExternalDependency(string importPath) @system
    {
        // Standard library imports don't have dots or slashes before first component
        if (!importPath.canFind(".") && !importPath.startsWith("./") && 
            !importPath.startsWith("../"))
        {
            // Likely standard library
            return true;
        }
        
        // External if not part of our module
        if (!modulePath.empty && !importPath.startsWith(modulePath))
        {
            return true;
        }
        
        return false;
    }
    
    private string detectModulePath() @system
    {
        try
        {
            string goMod = buildPath(moduleRoot, "go.mod");
            if (!exists(goMod))
                return "";
            
            auto content = readText(goMod);
            auto moduleRegex = regex(r"module\s+([\w\./\-]+)", "m");
            auto match = matchFirst(content, moduleRegex);
            
            if (!match.empty && match.length > 1)
            {
                return match[1];
            }
        }
        catch (Exception e)
        {
            structuredLog.debug_("failed_to_detect_go_module_path_").field("detail", "Failed to detect Go module path: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    private string[] parseGoImports(string sourceFile) @system
    {
        string[] imports;
        
        auto content = readText(sourceFile);
        
        // Single import: import "path"
        auto singleImportRegex = regex(`import\s+"([^"]+)"`, "gm");
        foreach (match; matchAll(content, singleImportRegex))
        {
            if (match.length > 1)
                imports ~= match[1];
        }
        
        // Multi-import block: import ( "path1" "path2" )
        auto blockRegex = regex(`import\s+\(([^)]+)\)`, "s");
        foreach (match; matchAll(content, blockRegex))
        {
            if (match.length > 1)
            {
                auto block = match[1];
                auto pathRegex = regex(`"([^"]+)"`, "g");
                foreach (pathMatch; matchAll(block, pathRegex))
                {
                    if (pathMatch.length > 1)
                        imports ~= pathMatch[1];
                }
            }
        }
        
        return imports;
    }
    
    private string[] resolveGoImport(string importPath) @system
    {
        string[] files;
        
        // Convert import path to directory path
        string relativePath = importPath;
        
        // Handle module-relative imports
        if (!modulePath.empty && importPath.startsWith(modulePath))
        {
            relativePath = importPath[modulePath.length .. $];
            if (relativePath.startsWith("/"))
                relativePath = relativePath[1 .. $];
        }
        
        string packageDir = buildPath(moduleRoot, relativePath);
        
        if (exists(packageDir) && isDir(packageDir))
        {
            // Find all .go files in package (except _test.go)
            foreach (entry; dirEntries(packageDir, "*.go", SpanMode.shallow))
            {
                if (!entry.name.endsWith("_test.go"))
                    files ~= entry.name;
            }
        }
        
        return files;
    }
}

/// Go incremental compilation helper
struct GoIncrementalHelper
{
    /// Find affected sources when a package file changes
    static string[] findAffectedSources(
        string changedFile,
        string[] allSources,
        GoDependencyAnalyzer analyzer
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

