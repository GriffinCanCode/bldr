module engine.graph.dynamic.dynamic;

import std.algorithm;
import std.array;
import std.conv;
import core.atomic;
import core.sync.mutex;
import engine.graph.core.graph;
import engine.graph.dynamic.discovery;
import infrastructure.config.schema.schema;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Dynamic build graph - extends BuildGraph with runtime mutation capabilities
/// Enables actions to discover new dependencies and extend the graph during execution
/// 
/// Design Philosophy:
/// - Static analysis produces initial graph (analysis phase)
/// - Dynamic discovery extends graph during execution (discovery phase)
/// - Maintains all invariants: DAG property, correct topological order
/// - Thread-safe: all mutations are synchronized
/// 
/// Use Cases:
/// - Code generation (protobuf, GraphQL, etc.) discovering output files
/// - Template expansion creating new targets
/// - Build scripts determining platform-specific dependencies
/// - Dynamic linking discovering shared libraries
final class DynamicBuildGraph
{
    private BuildGraph baseGraph;
    private GraphExtension extension;
    private DiscoveryStatus[string] discoveryStatus; // Per-node discovery status
    private core.sync.mutex.Mutex mutex;
    
    /// Create dynamic graph wrapping a static base graph
    this(BuildGraph baseGraph) @trusted
    {
        this.baseGraph = baseGraph;
        this.extension = new GraphExtension(baseGraph);
        this.mutex = new core.sync.mutex.Mutex();
    }
    
    /// Get the underlying base graph
    @property BuildGraph graph() @trusted pure nothrow @nogc
    {
        return baseGraph;
    }
    
    /// Mark a node as having discovery capability
    void markDiscoverable(TargetId id) @trusted
    {
        synchronized (mutex)
        {
            discoveryStatus[id.toString()] = DiscoveryStatus.Pending;
        }
    }
    
    /// Check if a node has discovery capability
    bool isDiscoverable(TargetId id) const @trusted
    {
        synchronized (cast(core.sync.mutex.Mutex)mutex)
        {
            auto key = id.toString();
            return (key in discoveryStatus) !is null && 
                   discoveryStatus[key] != DiscoveryStatus.None;
        }
    }
    
    /// Record discovery from an action
    void recordDiscovery(DiscoveryMetadata discovery) @trusted
    {
        synchronized (mutex)
        {
            // Update discovery status
            auto originKey = discovery.originTarget.toString();
            if (originKey in discoveryStatus)
                discoveryStatus[originKey] = DiscoveryStatus.Discovered;
            
            // Record in extension
            extension.recordDiscovery(discovery);
            
            structuredLog.debug_("discovery_recorded_for_").field("detail", "Discovery recorded for " ~ originKey ~ 
                          ": " ~ discovery.newTargets.length.to!string ~ " new targets, " ~
                          discovery.discoveredDependents.length.to!string ~ " new dependents").emit();
        }
    }
    
    /// Apply all pending discoveries and get newly scheduled nodes
    /// Returns nodes that should be added to the execution queue
    BuildResult!(BuildNode[]) applyDiscoveries() @system
    {
        auto result = extension.applyDiscoveries();
        if (result.isErr)
            return result;
        
        auto newNodes = result.unwrap();
        
        synchronized (mutex)
        {
            // Mark discoveries as applied
            foreach (node; newNodes)
            {
                auto key = node.id.toString();
                if (key in discoveryStatus)
                    discoveryStatus[key] = DiscoveryStatus.Applied;
            }
        }
        
        // Initialize pending deps for new nodes
        foreach (node; newNodes)
            node.initPendingDeps();
        
        structuredLog.info("applied_discoveries_").field("detail", "Applied discoveries: " ~ newNodes.length.to!string ~ " new nodes scheduled").emit();
        
        return BuildResult!(BuildNode[]).ok(newNodes);
    }
    
    /// Check if there are pending discoveries to apply
    bool hasPendingDiscoveries() const @trusted
    {
        return extension.getStats().totalDiscoveries > 0;
    }
    
    /// Get discovery statistics
    auto getDiscoveryStats() const @trusted
    {
        return extension.getStats();
    }
    
    /// Create a target for discovered generated code
    /// Infers language from file extensions and creates appropriate target
    static Target createDiscoveredTarget(
        string name,
        string[] sources,
        TargetId[] deps,
        string outputPath = ""
    ) @system
    {
        import std.path : extension;
        
        Target target;
        target.name = name;
        target.sources = sources;
        target.deps = deps.map!(d => d.toString()).array;
        target.outputPath = outputPath;
        
        // Infer type and language from sources
        if (!sources.empty)
        {
            auto ext = sources[0].extension;
            
            // Infer language from extension
            switch (ext)
            {
                case ".d":
                    target.language = TargetLanguage.D;
                    target.type = TargetType.Library;
                    break;
                case ".cpp", ".cc", ".cxx", ".c++":
                    target.language = TargetLanguage.Cpp;
                    target.type = TargetType.Library;
                    break;
                case ".c":
                    target.language = TargetLanguage.C;
                    target.type = TargetType.Library;
                    break;
                case ".go":
                    target.language = TargetLanguage.Go;
                    target.type = TargetType.Library;
                    break;
                case ".rs":
                    target.language = TargetLanguage.Rust;
                    target.type = TargetType.Library;
                    break;
                case ".py":
                    target.language = TargetLanguage.Python;
                    target.type = TargetType.Library;
                    break;
                case ".ts":
                    target.language = TargetLanguage.TypeScript;
                    target.type = TargetType.Library;
                    break;
                case ".js":
                    target.language = TargetLanguage.JavaScript;
                    target.type = TargetType.Library;
                    break;
                case ".java":
                    target.language = TargetLanguage.Java;
                    target.type = TargetType.Library;
                    break;
                default:
                    // Default to custom for unknown extensions
                    target.type = TargetType.Custom;
                    break;
            }
        }
        else
        {
            target.type = TargetType.Custom;
        }
        
        return target;
    }
}

/// Helper for common discovery patterns
struct DiscoveryPatterns
{
    /// Create discovery for code generation (e.g., protobuf)
    /// Generates compile targets for generated source files
    static DiscoveryMetadata codeGeneration(
        TargetId originTarget,
        string[] generatedFiles,
        string targetNamePrefix = "generated"
    ) @system
    {
        auto builder = DiscoveryBuilder.forTarget(originTarget);
        builder = builder.addOutputs(generatedFiles);
        
        // Group generated files by language
        Target[] newTargets;
        TargetId[] dependentIds;
        
        import std.path : baseName, stripExtension;
        import std.algorithm : filter;
        
        // Create compile targets for each language
        string[][string] filesByExt;
        foreach (file; generatedFiles)
        {
            import std.path : extension;
            auto ext = file.extension;
            if (ext !in filesByExt)
                filesByExt[ext] = [];
            filesByExt[ext] ~= file;
        }
        
        foreach (ext, files; filesByExt)
        {
            auto targetName = targetNamePrefix ~ "-" ~ baseName(ext);
            auto targetId = TargetId(targetName);
            
            auto target = DynamicBuildGraph.createDiscoveredTarget(
                targetName,
                files,
                [originTarget]
            );
            
            newTargets ~= target;
            dependentIds ~= targetId;
        }
        
        builder = builder.addTargets(newTargets);
        builder = builder.addDependents(dependentIds);
        
        return builder.build();
    }
    
    /// Create discovery for dynamic library dependencies
    /// Discovers shared libraries and creates link targets
    static DiscoveryMetadata libraryDiscovery(
        TargetId originTarget,
        string[] libraryPaths
    ) @system
    {
        auto builder = DiscoveryBuilder.forTarget(originTarget);
        builder = builder.addOutputs(libraryPaths);
        builder = builder.withMetadata("discovery_type", "libraries");
        
        return builder.build();
    }
    
    /// Create discovery for test generation
    /// Discovers test files and creates test targets
    static DiscoveryMetadata testDiscovery(
        TargetId originTarget,
        string[] testFiles
    ) @system
    {
        auto builder = DiscoveryBuilder.forTarget(originTarget);
        builder = builder.addOutputs(testFiles);
        
        Target[] testTargets;
        TargetId[] testIds;
        
        foreach (i, testFile; testFiles)
        {
            import std.path : baseName, stripExtension;
            auto testName = "test-" ~ baseName(testFile).stripExtension;
            auto testId = TargetId(testName);
            
            auto target = DynamicBuildGraph.createDiscoveredTarget(
                testName,
                [testFile],
                [originTarget]
            );
            target.type = TargetType.Test;
            
            testTargets ~= target;
            testIds ~= testId;
        }
        
        builder = builder.addTargets(testTargets);
        builder = builder.addDependents(testIds);
        
        return builder.build();
    }
}


