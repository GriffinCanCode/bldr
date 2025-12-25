module languages.compiled.cpp.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import engine.compilation.incremental.analyzer;
import languages.compiled.cpp.analysis.analysis;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// C++ incremental dependency analyzer
/// Extracts header dependencies and resolves them to absolute paths
final class CppDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string[] includeDirs;
    
    this(string[] includeDirs = []) @system
    {
        this.includeDirs = includeDirs;
        
        // Common system include paths
        version(Posix)
        {
            this.systemPaths = [
                "/usr/include",
                "/usr/local/include",
                "/opt/homebrew/include",
                "/usr/include/c++",
                "/usr/lib/gcc"
            ];
        }
        version(Windows)
        {
            this.systemPaths = [
                "C:\\Program Files",
                "C:\\Windows\\System32"
            ];
        }
    }
    
    /// Analyze dependencies for a C++ source file
    /// Returns resolved absolute paths of all header dependencies
    override BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] additionalIncludePaths = []
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
            // Get all include directives
            auto includes = HeaderAnalyzer.analyzeIncludes(sourceFile);
            
            string[] resolvedDeps;
            string sourceDir = dirName(sourceFile);
            auto allIncludePaths = includeDirs ~ additionalIncludePaths;
            
            foreach (include; includes)
            {
                // Skip external/system dependencies
                if (isExternalDependency(include))
                {
                    Logger.debugLog("  [External] " ~ include);
                    continue;
                }
                
                // Resolve to absolute path
                string resolved = HeaderAnalyzer.resolveHeader(
                    include,
                    allIncludePaths,
                    sourceDir
                );
                
                if (!resolved.empty && exists(resolved))
                {
                    resolvedDeps ~= buildNormalizedPath(resolved);
                    Logger.debugLog("  [Resolved] " ~ include ~ " -> " ~ resolved);
                }
                else
                {
                    Logger.debugLog("  [Not Found] " ~ include);
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze dependencies for " ~ 
                             sourceFile ~ ": " ~ e.msg,
                             ErrorCode.AnalysisFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if header is external (standard library or system header)
    override bool isExternalDependency(string header) @system
    {
        // Standard C++ headers (no extension)
        static immutable string[] stdHeaders = [
            "iostream", "vector", "string", "map", "set", "algorithm",
            "memory", "thread", "mutex", "atomic", "chrono", "functional",
            "tuple", "array", "deque", "list", "queue", "stack",
            "unordered_map", "unordered_set", "utility", "iterator",
            "numeric", "random", "regex", "complex", "valarray",
            "exception", "stdexcept", "system_error", "new", "typeinfo",
            "type_traits", "limits", "cstddef", "cstdlib", "cstdint",
            "cstring", "cmath", "ctime", "cassert", "cerrno"
        ];
        
        // Standard C headers
        static immutable string[] cHeaders = [
            "stdio.h", "stdlib.h", "string.h", "math.h", "time.h",
            "assert.h", "errno.h", "stdint.h", "stddef.h", "stdbool.h",
            "limits.h", "float.h", "ctype.h", "locale.h", "signal.h"
        ];
        
        // Check if it's a standard header
        string baseName = header.baseName;
        if (stdHeaders.canFind(baseName) || cHeaders.canFind(baseName))
            return true;
        
        // Check system paths
        return super.isExternalDependency(header);
    }
    
    /// Get transitive header dependencies
    string[] getTransitiveDependencies(string sourceFile) @system
    {
        return TransitiveAnalyzer.getTransitiveDependencies(
            sourceFile,
            this,
            includeDirs
        );
    }
}

/// Helper to determine affected sources when headers change
struct CppIncrementalHelper
{
    /// Find all source files that include a given header (directly or transitively)
    static string[] findAffectedSources(
        string changedHeader,
        string[] allSources,
        CppDependencyAnalyzer analyzer
    ) @system
    {
        string[] affected;
        string normalizedHeader = buildNormalizedPath(changedHeader);
        
        foreach (source; allSources)
        {
            auto depsResult = analyzer.analyzeDependencies(source);
            if (depsResult.isErr)
                continue;
            
            auto deps = depsResult.unwrap();
            
            // Check if this source depends on the changed header
            if (deps.canFind(normalizedHeader))
            {
                affected ~= source;
                Logger.debugLog("  " ~ source ~ " affected by " ~ changedHeader);
            }
        }
        
        return affected;
    }
    
    /// Build complete dependency graph for C++ project
    static string[][string] buildDependencyGraph(
        string[] sources,
        CppDependencyAnalyzer analyzer
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

