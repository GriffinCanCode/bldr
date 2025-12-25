module infrastructure.analysis.incremental.analyzer;

import std.stdio;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.conv;
import std.datetime.stopwatch;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.caching.interface_;
import infrastructure.analysis.tracking.interface_;
import infrastructure.analysis.incremental.interface_;
import infrastructure.config.schema.schema;
import infrastructure.utils.logging.logger;
import infrastructure.utils.files.hash;
import infrastructure.utils.concurrency.parallel;
import infrastructure.errors;

/// Incremental dependency analyzer with dependency injection
/// Coordinates change tracking, analysis caching, and selective reanalysis
/// Design: Only analyzes changed files, reuses cached analysis for unchanged files
final class IncrementalAnalyzer : IIncrementalAnalyzer
{
    private IAnalysisCache cache;
    private IFileChangeTracker tracker;
    private WorkspaceConfig _config;
    
    // Metrics
    private size_t filesReanalyzed;
    private size_t filesCachedHit;
    private size_t totalFiles;
    
    /// Constructor with dependency injection
    /// Parameters:
    ///   config = Workspace configuration
    ///   cache = Analysis cache implementation
    ///   tracker = File change tracker implementation
    this(WorkspaceConfig config, IAnalysisCache cache, IFileChangeTracker tracker) @system
    {
        this._config = config;
        this.cache = cache;
        this.tracker = tracker;
    }
    
    /// Analyze target with incremental optimization
    /// Returns: Result with TargetAnalysis
    BuildResult!TargetAnalysis analyzeTarget(ref Target target) @system
    {
        auto sw = StopWatch(AutoStart.yes);
        
        TargetAnalysis result;
        result.targetName = target.name;
        
        totalFiles = target.sources.length;
        filesReanalyzed = 0;
        filesCachedHit = 0;
        
        // Check which files have changed
        auto changesResult = tracker.checkChanges(target.sources);
        if (changesResult.isErr)
        {
            Logger.warning("Change tracking failed, incremental analysis disabled");
            auto error = createAnalysisError(
                target.name,
                "Incremental analysis unavailable - change tracking failed",
                ErrorCode.AnalysisFailed
            );
            error.addContext(ErrorContext("initializing incremental analysis", "change tracking initialization failed"));
            error.addSuggestion(ErrorSuggestion("Full rebuild will be performed"));
            error.addSuggestion(ErrorSuggestion.fileCheck("Check file system permissions for change tracking"));
            return BuildResult!TargetAnalysis.err(error);
        }
        
        auto changes = changesResult.unwrap();
        
        // Classify files: changed vs unchanged
        string[] changedFiles;
        string[] unchangedFiles;
        
        foreach (source; target.sources)
        {
            auto change = source in changes;
            if (change !is null && change.hasChanged)
                changedFiles ~= source;
            else
                unchangedFiles ~= source;
        }
        
        Logger.debugLog("Incremental analysis: " ~ 
                       changedFiles.length.to!string ~ " changed, " ~
                       unchangedFiles.length.to!string ~ " unchanged");
        
        // Reuse cached analysis for unchanged files
        FileAnalysis[] analyses;
        
        foreach (source; unchangedFiles)
        {
            auto changeInfo = changes[source];
            auto cachedResult = cache.get(changeInfo.contentHash);
            
            if (cachedResult.isErr)
            {
                Logger.warning("Cache lookup failed for " ~ source);
                changedFiles ~= source;  // Fallback: reanalyze
                continue;
            }
            
            auto cached = cachedResult.unwrap();
            if (cached !is null)
            {
                analyses ~= *cached;
                filesCachedHit++;
                Logger.debugLog("  Cache hit: " ~ source);
            }
            else
            {
                // Cache miss - need to analyze
                changedFiles ~= source;
            }
        }
        
        // Return cached analyses (changed files handled by caller)
        result.files = analyses;
        result.dependencies = [];
        
        // Add explicit dependencies
        foreach (dep; target.deps)
        {
            // Dependencies are already resolved by the full analyzer
            if (!result.dependencies.canFind!(d => d.targetName == dep))
            {
                result.dependencies ~= Dependency.direct(dep, dep);
            }
        }
        
        // Compute metrics
        sw.stop();
        auto allImports = result.allImports();
        result.metrics = AnalysisMetrics(
            result.files.length,
            allImports.length,
            result.dependencies.length,
            sw.peek().total!"msecs",
            0
        );
        
        logIncrementalStats();
        
        return Ok!(TargetAnalysis, BuildError)(result);
    }
    
    /// Initialize tracking for all sources in workspace
    VoidBuildResult initialize(WorkspaceConfig config) @system
    {
        Logger.info("Initializing incremental analysis tracking...");
        
        string[] allSources;
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (exists(source) && !allSources.canFind(source))
                    allSources ~= source;
            }
        }
        
        Logger.debugLog("Tracking " ~ allSources.length.to!string ~ " source files");
        
        auto result = tracker.trackBatch(allSources);
        if (result.isErr)
        {
            Logger.error("Failed to initialize file tracking");
            return result;
        }
        
        Logger.success("Incremental analysis initialized");
        return Ok!BuildError();
    }
    
    /// Invalidate cache for specific files
    void invalidate(string[] paths) @system
    {
        foreach (path; paths)
        {
            tracker.untrack(path);
        }
    }
    
    /// Clear all caches and tracking
    void clear() @system
    {
        cache.clear();
        tracker.clear();
        filesReanalyzed = 0;
        filesCachedHit = 0;
        totalFiles = 0;
    }
    
    /// Get combined statistics (implementing IIncrementalAnalyzer)
    IIncrementalAnalyzer.Stats getStats() @system
    {
        IIncrementalAnalyzer.Stats stats;
        stats.totalFiles = totalFiles;
        stats.filesReanalyzed = filesReanalyzed;
        stats.filesCached = filesCachedHit;
        
        if (totalFiles > 0)
        {
            stats.cacheHitRate = (filesCachedHit * 100.0) / totalFiles;
            stats.reductionRate = ((totalFiles - filesReanalyzed) * 100.0) / totalFiles;
        }
        
        // Map cache stats
        auto cacheStats = cache.getStats();
        stats.cacheStats.hits = cacheStats.hits;
        stats.cacheStats.misses = cacheStats.misses;
        stats.cacheStats.stores = cacheStats.stores;
        stats.cacheStats.hitRate = cacheStats.hitRate;
        stats.cacheStats.totalQueries = cacheStats.totalQueries;
        
        // Map tracker stats
        auto trackerStats = tracker.getStats();
        stats.trackerStats.trackedFiles = trackerStats.trackedFiles;
        stats.trackerStats.metadataChecks = trackerStats.metadataChecks;
        stats.trackerStats.contentHashChecks = trackerStats.contentHashChecks;
        stats.trackerStats.changesDetected = trackerStats.changesDetected;
        stats.trackerStats.fastPathRate = trackerStats.fastPathRate;
        
        return stats;
    }
    
    /// Print statistics
    void printStats() @system
    {
        auto stats = getStats();
        
        writeln("\n╔════════════════════════════════════════════════════════════╗");
        writeln("║       Incremental Dependency Analysis Statistics          ║");
        writeln("╠════════════════════════════════════════════════════════════╣");
        writefln("║  Total Files:          %6d                              ║", stats.totalFiles);
        writefln("║  Files Reanalyzed:     %6d                              ║", stats.filesReanalyzed);
        writefln("║  Files from Cache:     %6d                              ║", stats.filesCached);
        writefln("║  Cache Hit Rate:       %5.1f%%                             ║", stats.cacheHitRate);
        writefln("║  Work Reduction:       %5.1f%%                             ║", stats.reductionRate);
        writeln("╠════════════════════════════════════════════════════════════╣");
        writefln("║  Metadata Checks:      %6d                              ║", stats.trackerStats.metadataChecks);
        writefln("║  Content Hash Checks:  %6d                              ║", stats.trackerStats.contentHashChecks);
        writefln("║  Fast Path Rate:       %5.1f%%                             ║", stats.trackerStats.fastPathRate);
        writefln("║  Changes Detected:     %6d                              ║", stats.trackerStats.changesDetected);
        writeln("╚════════════════════════════════════════════════════════════╝");
    }
    
    private void logIncrementalStats() @system
    {
        if (totalFiles == 0)
            return;
        
        immutable saved = totalFiles - filesReanalyzed;
        immutable reduction = (saved * 100.0) / totalFiles;
        
        if (reduction > 0)
        {
            Logger.success("Incremental analysis: " ~
                          saved.to!string ~ "/" ~ totalFiles.to!string ~
                          " files cached (" ~ reduction.to!string[0..4] ~ "% reduction)");
        }
    }
}

