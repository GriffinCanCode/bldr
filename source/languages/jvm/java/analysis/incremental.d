module languages.jvm.java.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import engine.compilation.incremental.analyzer;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Java incremental dependency analyzer
/// Tracks class dependencies via imports and inner class usage
final class JavaDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string projectRoot;
    private string[] sourcePaths;
    private string packageBase;
    
    this(string projectRoot, string[] sourcePaths = []) @system
    {
        this.projectRoot = projectRoot;
        this.sourcePaths = sourcePaths.empty ? ["src/main/java", "src"] : sourcePaths;
        
        // JDK standard library
        this.systemPaths = [
            "java.", "javax.", "sun.", "com.sun."
        ];
    }
    
    /// Analyze Java import dependencies
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
            auto imports = parseJavaImports(sourceFile);
            
            string[] resolvedDeps;
            auto allSearchPaths = sourcePaths ~ additionalSearchPaths;
            
            foreach (importClass; imports)
            {
                if (isExternalDependency(importClass))
                {
                    Logger.debugLog("  [External] " ~ importClass);
                    continue;
                }
                
                string resolved = resolveJavaClass(importClass, allSearchPaths);
                
                if (!resolved.empty && exists(resolved))
                {
                    resolvedDeps ~= buildNormalizedPath(resolved);
                    Logger.debugLog("  [Resolved] " ~ importClass ~ " -> " ~ resolved);
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze Java dependencies for " ~ 
                             sourceFile ~ ": " ~ e.msg,
                             ErrorCode.AnalysisFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if import is external (JDK or third-party library)
    override bool isExternalDependency(string className) @system
    {
        // Check JDK packages
        foreach (prefix; systemPaths)
        {
            if (className.startsWith(prefix))
                return true;
        }
        
        // Common third-party packages
        static immutable string[] externalPrefixes = [
            "org.", "com.", "io.", "net."
        ];
        
        foreach (prefix; externalPrefixes)
        {
            if (className.startsWith(prefix))
            {
                // Could be project code too, but usually external
                // More sophisticated check would consult classpath
                return true;
            }
        }
        
        return false;
    }
    
    private string[] parseJavaImports(string sourceFile) @system
    {
        string[] imports;
        
        auto content = readText(sourceFile);
        
        // Match import statements
        auto importRegex = regex(r"import\s+(?:static\s+)?([\w.]+)(?:\.\*)?;", "gm");
        foreach (match; matchAll(content, importRegex))
        {
            if (match.length > 1)
            {
                auto importPath = match[1];
                // Remove wildcard imports (we'd need to scan the package)
                if (!importPath.endsWith(".*"))
                    imports ~= importPath;
            }
        }
        
        return imports;
    }
    
    private string resolveJavaClass(string className, string[] searchPaths) @system
    {
        // Convert class name to file path
        // com.example.MyClass -> com/example/MyClass.java
        string relativePath = className.replace(".", dirSeparator) ~ ".java";
        
        foreach (searchPath; searchPaths)
        {
            string fullPath = buildPath(projectRoot, searchPath, relativePath);
            if (exists(fullPath))
                return fullPath;
            
            // Also try without searchPath prefix
            fullPath = buildPath(projectRoot, relativePath);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Extract package name from Java source file
    string getPackageName(string sourceFile) @system
    {
        try
        {
            auto content = readText(sourceFile);
            auto packageRegex = regex(r"package\s+([\w.]+);", "m");
            auto match = matchFirst(content, packageRegex);
            
            if (!match.empty && match.length > 1)
                return match[1];
        }
        catch (Exception) {}
        
        return "";
    }
}

/// Java incremental compilation helper
struct JavaIncrementalHelper
{
    /// Find affected sources when a class changes
    static string[] findAffectedSources(
        string changedFile,
        string[] allSources,
        JavaDependencyAnalyzer analyzer
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
                Logger.debugLog("  " ~ source ~ " affected by " ~ changedFile);
            }
        }
        
        return affected;
    }
    
    /// Build complete dependency graph for Java project
    static string[][string] buildDependencyGraph(
        string[] sources,
        JavaDependencyAnalyzer analyzer
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

