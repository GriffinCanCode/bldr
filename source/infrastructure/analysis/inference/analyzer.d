module infrastructure.analysis.inference.analyzer;

import std.stdio;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.string;
import std.datetime.stopwatch;
import engine.graph;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.analysis.metadata.metagen;
import infrastructure.analysis.scanning.scanner;
import infrastructure.analysis.resolution.resolver;
import infrastructure.utils.logging.logger;
import languages.registry;
import infrastructure.utils.files.hash;
import infrastructure.utils.concurrency.parallel;
import infrastructure.analysis.incremental.interface_;
import infrastructure.errors;

/// Modern dependency analyzer using compile-time metaprogramming
/// Now uses dependency injection for incremental analysis
class DependencyAnalyzer
{
    private WorkspaceConfig config;
    private FileScanner scanner;
    private DependencyResolver resolver;
    private GraphCache graphCache;
    private IIncrementalAnalyzer incrementalAnalyzer;
    
    // Inject compile-time generated analyzer functions
    mixin LanguageAnalyzer;
    
    private string _cacheDir;
    
    /// Constructor with dependency injection (incremental analyzer optional)
    /// Parameters:
    ///   config = Workspace configuration
    ///   incrementalAnalyzer = Optional incremental analyzer (null to disable)
    ///   cacheDir = Cache directory path
    this(WorkspaceConfig config, IIncrementalAnalyzer incrementalAnalyzer, string cacheDir = ".builder-cache")
    {
        this.config = config;
        this._cacheDir = cacheDir;
        this.scanner = new FileScanner();
        this.resolver = new DependencyResolver(config);
        this.graphCache = new GraphCache(cacheDir);
        this.incrementalAnalyzer = incrementalAnalyzer;
    }
    
    /// Initialize incremental analysis (if analyzer is available)
    /// Call this after construction to initialize file tracking
    VoidBuildResult enableIncremental() @system
    {
        if (incrementalAnalyzer is null)
        {
            auto error = Errors.config("Incremental analyzer not injected - must be provided via constructor", ErrorCode.InvalidConfiguration)
                .withLocation(__FILE__, __LINE__)
                .build();
            return VoidBuildResult.err(error);
        }
        return incrementalAnalyzer.initialize(config);
    }
    
    /// Check if incremental analysis is available
    bool hasIncremental() const pure nothrow @nogc
    {
        return incrementalAnalyzer !is null;
    }
    
    /// Get incremental analyzer instance (for watch mode integration)
    @property IIncrementalAnalyzer getIncrementalAnalyzer() pure nothrow @nogc
    {
        return incrementalAnalyzer;
    }
    
    /// Analyze dependencies and build graph
    /// Note: Uses target.id for type-safe identification where possible
    /// Returns: Ok with BuildGraph on success, Err with BuildError on validation failure
    BuildResult!BuildGraph analyze(in string targetFilter = "") @trusted
    {
        Logger.debugLog("Analyzing dependencies...");
        auto sw = StopWatch(AutoStart.yes);
        
        // Collect all configuration files for cache validation
        auto configFiles = collectConfigFiles();
        
        // Try to load from cache first
        auto cachedGraph = graphCache.get(configFiles);
        if (cachedGraph !is null)
        {
            sw.stop();
            Logger.success("Loaded dependency graph from cache (" ~ 
                         sw.peek().total!"msecs".to!string ~ "ms)");
            
            // Apply target filter if specified
            if (!targetFilter.empty)
            {
                auto filteredGraph = filterGraph(cachedGraph, targetFilter);
                return BuildResult!BuildGraph.ok(filteredGraph);
            }
            
            return BuildResult!BuildGraph.ok(cachedGraph);
        }
        
        Logger.debugLog("Graph cache miss - analyzing dependencies...");
        
        // Use deferred validation for O(V+E) performance instead of O(V²)
        // Arena allocation reduces GC pressure 10-100x during graph construction
        auto graph = new BuildGraph(ValidationMode.Deferred, config.targets.length);
        
        // Add all targets to graph
        // Uses TargetId for filtering when available
        foreach (ref target; config.targets)
        {
            // Use TargetId.matches() for more flexible filtering
            bool shouldInclude = targetFilter.empty || 
                                matchesFilter(target.name, targetFilter) ||
                                target.id.matches(targetFilter);
            
            if (shouldInclude)
            {
                auto addResult = graph.addTarget(target);
                if (addResult.isErr)
                {
                    Logger.error("Failed to add target");
                    Logger.error(format(addResult.unwrapErr()));
                }
            }
        }
        
        // Analyze each target and resolve dependencies
        // Filter targets that are in the graph
        auto targetsToAnalyze = config.targets.filter!(t => t.name in graph.nodes).array;
        
        if (targetsToAnalyze.length > 1)
        {
            // Parallel analysis for multiple targets
            auto analyses = ParallelExecutor.mapWorkStealing(
                targetsToAnalyze,
                (Target target) @trusted {
                    return analyzeTarget(target);
                }
            );
            
            // Process results and add dependencies to graph
            foreach (i, analysisResult; analyses)
            {
                auto target = targetsToAnalyze[i];
                
                if (analysisResult.isErr)
                {
                    auto error = analysisResult.unwrapErr();
                    Logger.warning("Analysis failed for " ~ target.name);
                    Logger.error(format(error));
                    continue;
                }
                
                auto analysis = analysisResult.unwrap();
                
                if (!analysis.isValid)
                {
                    Logger.warning("Analysis errors in " ~ target.name);
                    continue;
                }
                
                // Add resolved dependencies to graph (no cycle check yet)
                foreach (dep; analysis.dependencies)
                {
                    if (dep.targetName in graph.nodes)
                    {
                        auto addResult = graph.addDependency(target.name, dep.targetName);
                        if (addResult.isErr)
                        {
                            auto error = addResult.unwrapErr();
                            Logger.error("Failed to add dependency: " ~ format(error));
                            // Continue processing other dependencies
                        }
                    }
                }
                
                Logger.debugLog("  " ~ target.name ~ ": " ~ 
                             analysis.dependencies.length.to!string ~ " dependencies");
            }
        }
        else if (targetsToAnalyze.length == 1)
        {
            // Single target - no need for parallelization overhead
            auto target = targetsToAnalyze[0];
            auto analysisResult = analyzeTarget(target);
            
            if (analysisResult.isErr)
            {
                auto error = analysisResult.unwrapErr();
                Logger.warning("Analysis failed for " ~ target.name);
                Logger.error(format(error));
            }
            else
            {
                auto analysis = analysisResult.unwrap();
                
                if (!analysis.isValid)
                {
                    Logger.warning("Analysis errors in " ~ target.name);
                }
                else
                {
                    // Add resolved dependencies to graph
                    foreach (dep; analysis.dependencies)
                    {
                        if (dep.targetName in graph.nodes)
                        {
                            auto addResult = graph.addDependency(target.name, dep.targetName);
                            if (addResult.isErr)
                            {
                                auto error = addResult.unwrapErr();
                                Logger.error("Failed to add dependency: " ~ format(error));
                            }
                        }
                    }
                    
                    Logger.debugLog("  " ~ target.name ~ ": " ~ 
                                 analysis.dependencies.length.to!string ~ " dependencies");
                }
            }
        }
        
        // Validate graph for cycles once at the end (O(V+E) total)
        auto validateResult = graph.validate();
        if (validateResult.isErr)
        {
            auto error = validateResult.unwrapErr();
            Logger.error("Graph validation failed: " ~ format(error));
            return BuildResult!BuildGraph.err(error);
        }
        
        // Cache the validated graph
        try
        {
            graphCache.put(graph, configFiles);
            Logger.debugLog("Cached dependency graph for future builds");
        }
        catch (Exception e)
        {
            Logger.warning("Failed to cache dependency graph: " ~ e.msg);
            // Non-fatal - continue with analysis result
        }
        
        sw.stop();
        Logger.success("Analysis complete (" ~ sw.peek().total!"msecs".to!string ~ "ms)");
        
        return BuildResult!BuildGraph.ok(graph);
    }
    
    /// Collect all Builderfile and Builderspace paths for cache validation
    private string[] collectConfigFiles() const @trusted
    {
        import std.file : dirEntries, SpanMode, exists, isFile;
        
        string[] files;
        
        try
        {
            // Find all Builderfiles recursively
            foreach (entry; dirEntries(config.root, "Builderfile", SpanMode.depth))
            {
                if (entry.isFile)
                    files ~= entry.name;
            }
            
            // Add Builderspace if exists
            auto builderspace = buildPath(config.root, "Builderspace");
            if (exists(builderspace) && isFile(builderspace))
                files ~= builderspace;
        }
        catch (Exception e)
        {
            Logger.warning("Failed to collect config files: " ~ e.msg);
        }
        
        return files;
    }
    
    /// Filter graph to only include matching targets
    private BuildGraph filterGraph(BuildGraph graph, string targetFilter) @trusted
    {
        // Arena-allocate with upper bound of original graph size
        auto filteredGraph = new BuildGraph(graph.validationMode, graph.nodes.length);
        
        // Add matching targets
        foreach (key, node; graph.nodes)
        {
            bool shouldInclude = matchesFilter(node.target.name, targetFilter) ||
                               node.target.id.matches(targetFilter);
            
            if (shouldInclude)
            {
                auto result = filteredGraph.addTarget(node.target);
                if (result.isErr)
                {
                    Logger.error("Failed to add target to filtered graph: " ~ 
                               format(result.unwrapErr()));
                }
            }
        }
        
        // Add dependencies between filtered targets
        foreach (key, node; filteredGraph.nodes)
        {
            auto origNode = graph.nodes.get(key, null);
            if (origNode !is null)
            {
                foreach (depId; origNode.dependencyIds)
                {
                    auto depKey = depId.toString();
                    if (depKey in filteredGraph.nodes)
                    {
                        auto result = filteredGraph.addDependency(key, depKey);
                        if (result.isErr)
                        {
                            Logger.error("Failed to add dependency: " ~ 
                                       format(result.unwrapErr()));
                        }
                    }
                }
            }
        }
        
        // Validate filtered graph
        auto validateResult = filteredGraph.validate();
        if (validateResult.isErr)
        {
            Logger.warning("Filtered graph validation failed: " ~ 
                         format(validateResult.unwrapErr()));
        }
        
        return filteredGraph;
    }
    
    
    /// Analyze a single target with error aggregation
    /// Returns Result with TargetAnalysis, collecting all file analysis errors
    /// Uses incremental analysis if available for improved performance
    BuildResult!TargetAnalysis analyzeTarget(
        ref Target target,
        AggregationPolicy policy = AggregationPolicy.CollectAll)
    {
        // Use incremental analyzer if available
        if (incrementalAnalyzer !is null)
        {
            try
            {
                return incrementalAnalyzer.analyzeTarget(target);
            }
            catch (Exception e)
            {
                Logger.warning("Incremental analysis failed, falling back to full analysis: " ~ e.msg);
                // Fall through to full analysis
            }
        }
        
        // Full analysis (original implementation)
        auto sw = StopWatch(AutoStart.yes);
        
        TargetAnalysis result;
        result.targetName = target.name;
        
        // Aggregate file analysis results
        auto aggregated = aggregateMap(
            target.sources,
            (string source) {
                // Check file exists
                if (!exists(source) || !isFile(source))
                {
                    // Use smart constructor for file not found errors
                    auto error = fileNotFoundError(source, "analyzing target: " ~ target.name);
                    error.addContext(ErrorContext("analyzing target", target.name));
                    error.addSuggestion(ErrorSuggestion.fileCheck("Ensure glob patterns are matching the intended files"));
                    return Err!(FileAnalysis, BuildError)(error);
                }
                
                try
                {
                    auto content = readText(source);
                    auto hash = FastHash.hashString(content);
                    
                    // Use compile-time generated analyzer
                    auto fileAnalysis = analyzeFile(target.language, source, content);
                    fileAnalysis.contentHash = hash;
                    
                    return Ok!(FileAnalysis, BuildError)(fileAnalysis);
                }
                catch (Exception e)
                {
                    // Use builder pattern with typed suggestions
                    import infrastructure.errors.types.context : ErrorSuggestion;
                    
                    auto error = ErrorBuilder!AnalysisError.create(target.name, "Failed to analyze dependencies: " ~ e.msg, ErrorCode.AnalysisFailed)
                        .withContext("analyzing file", source)
                        .withFileCheck("Check if the source file has valid syntax")
                        .withFileCheck("Ensure the file encoding is correct (UTF-8)")
                        .withFileCheck("Verify the language handler supports this file type")
                        .withSuggestion("Try compiling the file directly to check for errors")
                        .build();
                    return Err!(FileAnalysis, BuildError)(error);
                }
            },
            policy
        );
        
        // Log analysis results
        if (aggregated.hasErrors)
        {
            Logger.warning(
                "Failed to analyze " ~ aggregated.errors.length.to!string ~
                " source file(s) in " ~ target.name
            );
            
            foreach (error; aggregated.errors)
            {
                Logger.error(format(error));
            }
        }
        
        // Store successfully analyzed files
        result.files = aggregated.successes;
        
        // If all files failed to analyze, return error
        if (aggregated.isFailed)
        {
            return Err!(TargetAnalysis, BuildError)(aggregated.errors[0]);
        }
        
        // Collect all imports
        auto allImports = result.allImports();
        
        // Resolve imports to dependencies
        result.dependencies = resolveImports(allImports, target.language, config);
        
        // Add explicit dependencies
        foreach (dep; target.deps)
        {
            auto resolved = resolver.resolve(dep, target.name);
            if (!resolved.empty && !result.dependencies.canFind!(d => d.targetName == resolved))
            {
                result.dependencies ~= Dependency.direct(resolved, dep);
            }
        }
        
        // Compute metrics
        result.metrics = AnalysisMetrics(
            result.files.length,
            allImports.length,
            result.dependencies.length,
            sw.peek().total!"msecs",
            0
        );
        
        return Ok!(TargetAnalysis, BuildError)(result);
    }
    
    /// Resolve imports to dependencies (uses compile-time generated code)
    mixin(generateImportResolver());
    
    /// Check if target matches filter pattern
    private bool matchesFilter(string name, string pattern) const pure
    {
        import std.string : indexOf, startsWith, endsWith;
        
        if (pattern.empty)
            return true;
        
        // Handle :target pattern (matches any //path:target)
        if (pattern.startsWith(":"))
        {
            return name.endsWith(pattern);
        }
        
        // Simple pattern matching with wildcards
        if (pattern.endsWith("..."))
        {
            auto prefix = pattern[0 .. $ - 3];
            return name.indexOf(prefix) == 0;
        }
        
        return name == pattern;
    }
}

/// Compile-time verification
static assert(is(typeof(DependencyAnalyzer.init.analyzeFile(TargetLanguage.Python, "", ""))),
              "Generated analyzeFile function is invalid");

/// Import for string conversion
import std.conv : to;

/// Build inference result
struct InferenceResult
{
    string buildType;
    double confidence;
}

/// Simple build inference analyzer for zero-config builds
class BuildInferenceAnalyzer
{
    this() {}
    
    /// Infer build type (executable, library, test)
    string inferBuildType(string basePath, TargetLanguage language)
    {
        // Check for test patterns first (tests can have main functions)
        if (hasTestPatterns(basePath, language))
            return "test";
        
        // Check for main function indicating executable
        if (hasMainFunction(basePath, language))
            return "executable";
        
        // Check for library patterns
        if (hasLibraryPatterns(basePath, language))
            return "library";
        
        // Default to library if no main found
        return "library";
    }
    
    /// Infer dependencies from imports/requires
    string[] inferDependencies(string basePath, TargetLanguage language)
    {
        string[] dependencies;
        
        try
        {
            // For JavaScript/TypeScript, also check package.json
            if (language == TargetLanguage.JavaScript || language == TargetLanguage.TypeScript)
            {
                auto packageJsonPath = buildPath(basePath, "package.json");
                if (exists(packageJsonPath) && isFile(packageJsonPath))
                {
                    auto packageJson = readText(packageJsonPath);
                    auto packageDeps = extractPackageJsonDependencies(packageJson);
                    
                    foreach (dep; packageDeps)
                    {
                        if (!dependencies.canFind(dep))
                            dependencies ~= dep;
                    }
                }
            }
            
            auto files = getSourceFiles(basePath, language);
            
            foreach (file; files)
            {
                if (!exists(file) || !isFile(file))
                    continue;
                
                auto content = readText(file);
                auto fileDeps = extractDependencies(content, language);
                
                foreach (dep; fileDeps)
                {
                    if (!dependencies.canFind(dep))
                        dependencies ~= dep;
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to infer dependencies from " ~ basePath ~ ": " ~ e.msg);
        }
        
        return dependencies;
    }
    
    /// Infer compiler flags from source code
    string[] inferCompilerFlags(string basePath, TargetLanguage language)
    {
        string[] flags;
        
        try
        {
            auto files = getSourceFiles(basePath, language);
            
            foreach (file; files)
            {
                if (!exists(file) || !isFile(file))
                    continue;
                
                auto content = readText(file);
                
                // Check for C++17/20 features
                if (language == TargetLanguage.Cpp)
                {
                    if (content.canFind("<optional>") || 
                        content.canFind("std::optional") ||
                        content.canFind("<variant>") ||
                        content.canFind("<filesystem>"))
                    {
                        if (!flags.canFind("-std=c++17"))
                            flags ~= "-std=c++17";
                    }
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to infer compiler flags from " ~ basePath ~ ": " ~ e.msg);
        }
        
        return flags;
    }
    
    /// Infer output name from directory or project files
    string inferOutputName(string basePath)
    {
        import std.path : baseName;
        return baseName(basePath);
    }
    
    /// Infer source files for a language
    string[] inferSourceFiles(string basePath, TargetLanguage language)
    {
        return getSourceFiles(basePath, language);
    }
    
    /// Infer include directories from project structure
    string[] inferIncludeDirectories(string basePath)
    {
        import std.path : buildPath;
        import std.file : dirEntries, SpanMode, isDir;
        
        string[] includes;
        
        try
        {
            // Common include directory names
            immutable dirs = ["include", "inc", "headers"];
            
            foreach (dir; dirs)
            {
                auto path = buildPath(basePath, dir);
                if (exists(path) && isDir(path))
                    includes ~= path;
            }
            
            // Also check subdirectories
            foreach (entry; dirEntries(basePath, SpanMode.shallow))
            {
                if (entry.isDir && entry.name.baseName == "include")
                    includes ~= entry.name;
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to infer include directories from " ~ basePath ~ ": " ~ e.msg);
        }
        
        return includes;
    }
    
    /// Analyze with confidence scoring
    InferenceResult analyzeWithConfidence(string basePath, TargetLanguage language)
    {
        InferenceResult result;
        result.buildType = inferBuildType(basePath, language);
        
        // Calculate confidence based on evidence
        double confidence = 0.5;  // Base confidence
        
        // Increase confidence for clear indicators
        if (hasMainFunction(basePath, language))
            confidence += 0.3;
        
        // Check for manifest files (increases confidence)
        if (hasManifestFile(basePath, language))
            confidence += 0.2;
        
        result.confidence = confidence > 1.0 ? 1.0 : confidence;
        return result;
    }
    
    // Helper methods
    
    private bool hasMainFunction(string basePath, TargetLanguage language)
    {
        try
        {
            auto files = getSourceFiles(basePath, language);
            
            foreach (file; files)
            {
                if (!exists(file) || !isFile(file))
                    continue;
                
                auto content = readText(file);
                
                // Check for main function patterns
                if (content.canFind("int main(") || 
                    content.canFind("fn main()") ||
                    content.canFind("func main()") ||
                    content.canFind("def main(") ||
                    content.canFind("public static void main"))
                {
                    return true;
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to check for main function in " ~ basePath ~ ": " ~ e.msg);
        }
        
        return false;
    }
    
    private bool hasTestPatterns(string basePath, TargetLanguage language)
    {
        import std.path : baseName;
        
        try
        {
            auto files = getSourceFiles(basePath, language);
            
            foreach (file; files)
            {
                auto name = baseName(file);
                
                if (name.startsWith("test_") || name.startsWith("Test"))
                    return true;
                
                if (!exists(file) || !isFile(file))
                    continue;
                
                auto content = readText(file);
                
                // Check for test framework imports
                if (content.canFind("gtest") || 
                    content.canFind("unittest") ||
                    content.canFind("pytest") ||
                    content.canFind("@Test"))
                {
                    return true;
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to check for test patterns in " ~ basePath ~ ": " ~ e.msg);
        }
        
        return false;
    }
    
    private bool hasLibraryPatterns(string basePath, TargetLanguage language)
    {
        try
        {
            // Check for package/library manifest files
            if (language == TargetLanguage.Python)
            {
                if (exists(buildPath(basePath, "setup.py")) ||
                    exists(buildPath(basePath, "__init__.py")))
                    return true;
            }
            else if (language == TargetLanguage.JavaScript || language == TargetLanguage.TypeScript)
            {
                if (exists(buildPath(basePath, "package.json")))
                    return true;
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to check for library patterns in " ~ basePath ~ ": " ~ e.msg);
        }
        
        return false;
    }
    
    private bool hasManifestFile(string basePath, TargetLanguage language)
    {
        try
        {
            immutable manifests = [
                "package.json", "Cargo.toml", "go.mod", "setup.py", 
                "pom.xml", "build.gradle", "Makefile"
            ];
            
            foreach (manifest; manifests)
            {
                if (exists(buildPath(basePath, manifest)))
                    return true;
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to check for manifest files in " ~ basePath ~ ": " ~ e.msg);
        }
        
        return false;
    }
    
    private string[] getSourceFiles(string basePath, TargetLanguage language)
    {
        import std.file : dirEntries, SpanMode;
        import std.path : extension;
        
        string[] files;
        
        try
        {
            auto extensions = languageExtensions(language);
            
            foreach (entry; dirEntries(basePath, SpanMode.depth))
            {
                if (!entry.isFile)
                    continue;
                
                auto ext = entry.name.extension;
                if (extensions.canFind(ext))
                    files ~= entry.name;
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to get source files from " ~ basePath ~ ": " ~ e.msg);
        }
        
        return files;
    }
    
    private string[] extractDependencies(string content, TargetLanguage language)
    {
        import std.regex;
        
        string[] deps;
        
        try
        {
            if (language == TargetLanguage.Python)
            {
                // Match: import numpy, from pandas import ...
                auto re = regex(`^(?:import|from)\s+([a-zA-Z_][a-zA-Z0-9_]*)`, "m");
                foreach (match; matchAll(content, re))
                {
                    auto dep = match[1];
                    if (!deps.canFind(dep))
                        deps ~= dep;
                }
            }
            else if (language == TargetLanguage.JavaScript || language == TargetLanguage.TypeScript)
            {
                // Match: import React from 'react', require('express')
                auto re = regex(`(?:import|require)\s*\(?\s*['"]([^'"]+)['"]`, "m");
                foreach (match; matchAll(content, re))
                {
                    auto dep = match[1];
                    if (!deps.canFind(dep))
                        deps ~= dep;
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to extract dependencies from content: " ~ e.msg);
        }
        
        return deps;
    }
    
    private string[] extractPackageJsonDependencies(string packageJsonContent)
    {
        import std.regex;
        import std.json;
        
        string[] deps;
        
        try
        {
            auto json = parseJSON(packageJsonContent);
            
            // Extract from dependencies
            if ("dependencies" in json)
            {
                foreach (string key, value; json["dependencies"].object)
                {
                    if (!deps.canFind(key))
                        deps ~= key;
                }
            }
            
            // Extract from devDependencies
            if ("devDependencies" in json)
            {
                foreach (string key, value; json["devDependencies"].object)
                {
                    if (!deps.canFind(key))
                        deps ~= key;
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to parse package.json dependencies: " ~ e.msg);
        }
        
        return deps;
    }
    
    /// Get file extensions for a language - delegates to centralized registry
    private string[] languageExtensions(TargetLanguage language)
    {
        return getLanguageExtensions(language);
    }
}
