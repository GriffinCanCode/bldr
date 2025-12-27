module infrastructure.analysis.incremental.watcher;

import std.stdio;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import core.time : Duration, msecs;
import infrastructure.utils.files.watch;
import infrastructure.utils.logging;
import infrastructure.analysis.incremental.interface_;
import infrastructure.config.schema.schema;
import infrastructure.parsing.treesitter.adapter;
import infrastructure.errors;

/// Proactive analysis cache updater using file watching
/// Automatically invalidates and updates cache when files change
/// Uses incremental parsing for efficient re-analysis
final class AnalysisWatcher
{
    private IIncrementalAnalyzer analyzer;
    private IFileWatcher watcher;
    private WorkspaceConfig config;
    private IncrementalParseAdapter parseAdapter;
    private bool active;
    
    // Statistics
    private size_t filesInvalidated;
    private size_t eventsProcessed;
    private size_t incrementalParses;
    
    this(IIncrementalAnalyzer analyzer, WorkspaceConfig config) @system
    {
        this.analyzer = analyzer;
        this.config = config;
        this.watcher = FileWatcherFactory.create();
        this.parseAdapter = new IncrementalParseAdapter(true);
    }
    
    /// Start watching for file changes
    VoidBuildResult start(string watchPath = "") @system
    {
        if (active)
        {
            auto error = new WatchError(
                "Watcher already active",
                Watch.Error
            );
            return VoidBuildResult.err(error);
        }
        
        immutable path = watchPath.empty ? config.root : watchPath;
        
        structuredLog.info("starting_incremental_analysis_watcher_on").field("detail", "Starting incremental analysis watcher on: " ~ path).emit();
        
        WatchConfig watchConfig;
        watchConfig.debounceDelay = 200.msecs;  // 200ms debounce
        watchConfig.recursive = true;
        watchConfig.useNativeWatcher = true;
        
        auto result = watcher.watch(path, watchConfig, &handleFileEvents);
        if (result.isErr)
        {
            structuredLog.error("failed_to_start_file_watcher").emit();
            return result;
        }
        
        active = true;
        structuredLog.info("incremental_analysis_watcher_started").emit();
        
        return Ok!BuildError();
    }
    
    /// Stop watching
    void stop() @system
    {
        if (!active)
            return;
        
        watcher.stop();
        parseAdapter.clear();
        active = false;
        
        structuredLog.info("incremental_analysis_watcher_stopped").emit();
    }
    
    /// Check if watcher is active
    bool isActive() const pure nothrow @nogc
    {
        return active;
    }
    
    /// Get statistics
    struct Stats
    {
        size_t filesInvalidated;
        size_t eventsProcessed;
        size_t incrementalParses;
        float incrementalRate;
        bool isActive;
    }
    
    Stats getStats() @system
    {
        Stats stats;
        stats.filesInvalidated = filesInvalidated;
        stats.eventsProcessed = eventsProcessed;
        stats.incrementalParses = incrementalParses;
        stats.isActive = active;
        
        // Get incremental parsing stats
        auto parseStats = parseAdapter.getStats();
        stats.incrementalRate = parseStats.treeStats.incrementalRate;
        
        return stats;
    }
    
    private void handleFileEvents(const FileEvent[] events) @system
    {
        if (!active || events.length == 0)
            return;
        
        eventsProcessed += events.length;
        
        // Filter to source file events
        FileEvent[] sourceEvents;
        string[] affectedFiles;
        
        foreach (ref event; events)
        {
            if (isSourceFile(event.path))
            {
                sourceEvents ~= event;
                affectedFiles ~= event.path;
                
                structuredLog.debug_("file_change_detected_").field("detail", "File change detected: " ~ event.path ~ 
                               " (" ~ event.kind.to!string ~ ")").emit();
            }
        }
        
        if (affectedFiles.empty)
            return;
        
        // Use incremental parsing for efficient re-analysis
        try
        {
            // Process changes with incremental parser
            auto updatedASTs = parseAdapter.processChanges(sourceEvents);
            incrementalParses += updatedASTs.length;
            
            structuredLog.debug_("incrementally_parsed_").field("detail", "Incrementally parsed " ~ updatedASTs.length.to!string ~ 
                           " file(s)").emit();
            
            // Invalidate analyzer cache for affected files
            analyzer.invalidate(affectedFiles);
            filesInvalidated += affectedFiles.length;
            
            structuredLog.debug_("invalidated_").field("detail", "Invalidated " ~ affectedFiles.length.to!string ~ 
                           " file(s) from analysis cache").emit();
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_process_file_changes_").field("detail", "Failed to process file changes: " ~ e.msg).emit();
        }
    }
    
    private bool isSourceFile(string path) const @system
    {
        import std.path : extension;
        
        // Check if file is in any target's sources
        foreach (ref target; config.targets)
        {
            if (target.sources.canFind(path))
                return true;
        }
        
        // Check by extension as fallback
        immutable ext = extension(path);
        if (ext.empty)
            return false;
        
        // Common source file extensions
        immutable sourceExts = [
            ".d", ".py", ".js", ".ts", ".jsx", ".tsx",
            ".go", ".rs", ".c", ".cpp", ".cc", ".cxx",
            ".h", ".hpp", ".java", ".kt", ".cs", ".fs",
            ".swift", ".rb", ".php", ".lua", ".r", ".ml",
            ".hs", ".elm", ".nim", ".zig", ".pl", ".pm"
        ];
        
        return sourceExts.canFind(ext);
    }
}

