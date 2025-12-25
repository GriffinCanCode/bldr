module infrastructure.analysis.incremental.watcher;

import std.stdio;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import core.time : Duration, msecs;
import infrastructure.utils.files.watch;
import infrastructure.utils.logging.logger;
import infrastructure.analysis.incremental.interface_;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// Proactive analysis cache updater using file watching
/// Automatically invalidates and updates cache when files change
/// Now uses dependency injection with IIncrementalAnalyzer
final class AnalysisWatcher
{
    private IIncrementalAnalyzer analyzer;
    private IFileWatcher watcher;
    private WorkspaceConfig config;
    private bool active;
    
    // Statistics
    private size_t filesInvalidated;
    private size_t eventsProcessed;
    
    this(IIncrementalAnalyzer analyzer, WorkspaceConfig config) @system
    {
        this.analyzer = analyzer;
        this.config = config;
        this.watcher = FileWatcherFactory.create();
    }
    
    /// Start watching for file changes
    VoidBuildResult start(string watchPath = "") @system
    {
        if (active)
        {
            auto error = new WatchError(
                "Watcher already active",
                ErrorCode.WatchError
            );
            return VoidBuildResult.err(error);
        }
        
        immutable path = watchPath.empty ? config.root : watchPath;
        
        Logger.info("Starting incremental analysis watcher on: " ~ path);
        
        WatchConfig watchConfig;
        watchConfig.debounceDelay = 200.msecs;  // 200ms debounce
        watchConfig.recursive = true;
        watchConfig.useNativeWatcher = true;
        
        auto result = watcher.watch(path, watchConfig, &handleFileEvents);
        if (result.isErr)
        {
            Logger.error("Failed to start file watcher");
            return result;
        }
        
        active = true;
        Logger.success("Incremental analysis watcher started");
        
        return Ok!BuildError();
    }
    
    /// Stop watching
    void stop() @system
    {
        if (!active)
            return;
        
        watcher.stop();
        active = false;
        
        Logger.info("Incremental analysis watcher stopped");
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
        bool isActive;
    }
    
    Stats getStats() const @system
    {
        Stats stats;
        stats.filesInvalidated = filesInvalidated;
        stats.eventsProcessed = eventsProcessed;
        stats.isActive = active;
        return stats;
    }
    
    private void handleFileEvents(const FileEvent[] events) @system
    {
        if (!active || events.length == 0)
            return;
        
        eventsProcessed += events.length;
        
        // Collect affected source files
        string[] affectedFiles;
        
        foreach (ref event; events)
        {
            // Only care about source files in targets
            if (isSourceFile(event.path))
            {
                affectedFiles ~= event.path;
                
                Logger.debugLog("File change detected: " ~ event.path ~ 
                               " (" ~ event.kind.to!string ~ ")");
            }
        }
        
        if (affectedFiles.empty)
            return;
        
        // Invalidate cache for affected files
        try
        {
            analyzer.invalidate(affectedFiles);
            filesInvalidated += affectedFiles.length;
            
            Logger.debugLog("Invalidated " ~ affectedFiles.length.to!string ~ 
                           " file(s) from analysis cache");
        }
        catch (Exception e)
        {
            Logger.error("Failed to invalidate cache: " ~ e.msg);
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

