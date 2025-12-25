module engine.compilation.incremental.analyzer;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import infrastructure.errors;

/// Language-agnostic dependency analyzer interface
/// Each language implements this to extract file-level dependencies
interface DependencyAnalyzer
{
    /// Analyze dependencies for a source file
    /// Returns list of files this source depends on
    BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] includePaths = []
    ) @system;
    
    /// Resolve a dependency path to absolute path
    /// Returns empty string if not found
    string resolveDependency(
        string dependency,
        string sourceDir,
        string[] searchPaths = []
    ) @system;
    
    /// Check if a dependency is external (system library, standard library, etc.)
    /// External dependencies don't trigger rebuilds
    bool isExternalDependency(string dependency) @system;
}

/// Base dependency analyzer with common functionality
abstract class BaseDependencyAnalyzer : DependencyAnalyzer
{
    protected string[] standardPaths;
    protected string[] systemPaths;
    
    this() @safe
    {
        // Subclasses initialize these
    }
    
    /// Default resolve implementation
    string resolveDependency(
        string dependency,
        string sourceDir,
        string[] searchPaths = []
    ) @system
    {
        // Try relative to source
        auto localPath = buildPath(sourceDir, dependency);
        if (exists(localPath)) return buildNormalizedPath(localPath);
        
        // Try search paths
        foreach (searchPath; searchPaths)
        {
            auto fullPath = buildPath(searchPath, dependency);
            if (exists(fullPath)) return buildNormalizedPath(fullPath);
        }
        
        return ""; // Not found
    }
    
    /// Default external check - checks if in system paths
    bool isExternalDependency(string dependency) @system
    {
        return systemPaths.any!(path => dependency.startsWith(path));
    }
}

/// Helper to extract transitive dependencies
struct TransitiveAnalyzer
{
    /// Get all transitive dependencies for a file
    static string[] getTransitiveDependencies(
        string sourceFile,
        DependencyAnalyzer analyzer,
        string[] includePaths = []
    ) @system
    {
        string[] allDeps;
        bool[string] visited;
        string[] toVisit = [sourceFile];
        
        while (!toVisit.empty)
        {
            auto current = toVisit[0];
            toVisit = toVisit[1 .. $];
            
            if (current in visited) continue;
            visited[current] = true;
            
            auto result = analyzer.analyzeDependencies(current, includePaths);
            if (result.isErr) continue;
            
            foreach (dep; result.unwrap().filter!(d => d !in visited && !analyzer.isExternalDependency(d)))
            {
                allDeps ~= dep;
                toVisit ~= dep;
            }
        }
        
        return allDeps;
    }
}

