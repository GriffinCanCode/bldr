module engine.caching.storage.materialization;

import std.file : exists, mkdirRecurse, remove;
import std.path : dirName, buildPath, relativePath;
import std.algorithm : map, filter, sort;
import std.array : array;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Duration, dur;
import std.conv : to;
import core.sync.mutex : Mutex;
import engine.caching.storage.source_repository : SourceRepository;
import engine.caching.storage.source_ref : SourceRef, SourceRefSet;
import infrastructure.utils.logging.logger : Logger;
import infrastructure.errors;

/// Workspace materialization utilities
/// Restore source files from CAS to workspace (git-like checkout)
final class WorkspaceMaterializer
{
    private SourceRepository repository;
    private Mutex materializerMutex;
    private MaterializationConfig config;
    
    // Statistics
    private size_t filesRestored;
    private size_t filesSkipped;
    private size_t filesUpdated;
    private ulong bytesWritten;
    
    this(SourceRepository repository, MaterializationConfig config = MaterializationConfig.init) @system
    {
        this.repository = repository;
        this.config = config;
        this.materializerMutex = new Mutex();
    }
    
    /// Materialize sources to workspace
    BuildResult!MaterializationResult materialize(
        SourceRefSet refSet,
        string workspaceRoot = "."
    ) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        MaterializationResult result;
        
        synchronized (materializerMutex)
        {
            Logger.info("Materializing " ~ refSet.length.to!string ~ " source file(s)...");
            
            foreach (ref source; refSet.sources)
            {
                if (source.originalPath.length == 0)
                    continue;
                
                // Compute target path relative to workspace
                immutable targetPath = buildPath(workspaceRoot, source.originalPath);
                
                // Check if file already exists with correct hash (skip if unchanged)
                if (config.skipUnchanged && exists(targetPath))
                {
                    auto verifyResult = repository.verify(source.originalPath);
                    if (verifyResult.isOk && verifyResult.unwrap())
                    {
                        filesSkipped++;
                        result.filesSkipped++;
                        continue;
                    }
                }
                
                // Materialize from CAS
                auto matResult = repository.materialize(source.hash, targetPath);
                if (matResult.isErr)
                {
                    result.errors ~= MaterializationError(
                        source.originalPath,
                        source.hash,
                        matResult.unwrapErr().message
                    );
                    continue;
                }
                
                // Update stats
                if (exists(targetPath))
                {
                    filesUpdated++;
                    result.filesUpdated++;
                }
                else
                {
                    filesRestored++;
                    result.filesCreated++;
                }
                
                bytesWritten += source.size;
                result.bytesWritten += source.size;
                result.filesProcessed++;
                
                if (config.verbose)
                    Logger.debugLog("Materialized: " ~ source.toString());
            }
            
            result.duration = timer.peek();
            result.success = result.errors.length == 0;
            
            if (result.success)
            {
                Logger.success(
                    "Materialized " ~ result.filesProcessed.to!string ~ 
                    " file(s) (" ~ formatBytes(result.bytesWritten) ~ ") in " ~ 
                    formatDuration(result.duration)
                );
            }
            else
            {
                Logger.error(
                    "Materialization completed with " ~ result.errors.length.to!string ~ " error(s)"
                );
            }
            
            return Ok!(MaterializationResult, BuildError)(result);
        }
    }
    
    /// Incremental update: only materialize changed sources
    BuildResult!MaterializationResult update(
        SourceRefSet oldRefs,
        SourceRefSet newRefs,
        string workspaceRoot = "."
    ) @system
    {
        synchronized (materializerMutex)
        {
            // Build diff: only materialize changed files
            SourceRefSet changedRefs;
            
            foreach (ref newSource; newRefs.sources)
            {
                auto oldSource = oldRefs.getByPath(newSource.originalPath);
                
                // File is new or changed
                if (oldSource is null || oldSource.hash != newSource.hash)
                {
                    changedRefs.add(newSource);
                }
            }
            
            if (changedRefs.empty)
            {
                Logger.info("No source changes detected");
                MaterializationResult result;
                result.success = true;
                result.filesProcessed = 0;
                return Ok!(MaterializationResult, BuildError)(result);
            }
            
            Logger.info("Updating " ~ changedRefs.length.to!string ~ " changed source(s)...");
            return materialize(changedRefs, workspaceRoot);
        }
    }
    
    /// Clean workspace: remove files not in source set
    BuildResult!CleanupResult clean(
        SourceRefSet refSet,
        string workspaceRoot = ".",
        bool dryRun = false
    ) @system
    {
        synchronized (materializerMutex)
        {
            CleanupResult result;
            
            // Build set of valid paths
            bool[string] validPaths;
            foreach (ref source; refSet.sources)
            {
                if (source.originalPath.length > 0)
                    validPaths[source.originalPath] = true;
            }
            
            // Scan workspace for extra files
            import std.file : dirEntries, SpanMode, isFile;
            
            try
            {
                foreach (entry; dirEntries(workspaceRoot, SpanMode.depth))
                {
                    if (!isFile(entry.name))
                        continue;
                    
                    immutable relPath = relativePath(entry.name, workspaceRoot);
                    
                    // Skip files in valid set
                    if (relPath in validPaths)
                        continue;
                    
                    // Skip ignored patterns
                    if (isIgnoredPath(relPath))
                        continue;
                    
                    // Mark for removal
                    result.filesToRemove ~= relPath;
                    
                    if (!dryRun)
                    {
                        try
                        {
                            remove(entry.name);
                            result.filesRemoved++;
                        }
                        catch (Exception e)
                        {
                            result.errors ~= "Failed to remove " ~ relPath ~ ": " ~ e.msg;
                        }
                    }
                }
                
                result.success = result.errors.length == 0;
                
                if (dryRun)
                {
                    Logger.info("Would remove " ~ result.filesToRemove.length.to!string ~ " file(s)");
                }
                else
                {
                    Logger.success("Removed " ~ result.filesRemoved.to!string ~ " file(s)");
                }
            }
            catch (Exception e)
            {
                return Err!(CleanupResult, BuildError)(
                    Errors.io(workspaceRoot, "Workspace cleanup failed: " ~ e.msg, ErrorCode.FileDeleteFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            return Ok!(CleanupResult, BuildError)(result);
        }
    }
    
    /// Get statistics
    struct MaterializerStats
    {
        size_t filesRestored;
        size_t filesSkipped;
        size_t filesUpdated;
        ulong bytesWritten;
    }
    
    MaterializerStats getStats() @system
    {
        synchronized (materializerMutex)
        {
            MaterializerStats stats;
            stats.filesRestored = filesRestored;
            stats.filesSkipped = filesSkipped;
            stats.filesUpdated = filesUpdated;
            stats.bytesWritten = bytesWritten;
            return stats;
        }
    }
    
    private bool isIgnoredPath(string path) const @safe
    {
        import std.path : baseName;
        import std.algorithm : startsWith;
        
        // Ignore builder cache
        if (path.startsWith(".builder-cache/"))
            return true;
        
        // Ignore version control
        if (path.startsWith(".git/"))
            return true;
        
        // Ignore build outputs
        immutable base = baseName(path);
        if (base.startsWith(".") || base.startsWith("bin/") || base.startsWith("dist/"))
            return true;
        
        return false;
    }
}

/// Materialization configuration
struct MaterializationConfig
{
    bool skipUnchanged = true;  // Skip files that haven't changed
    bool verbose = false;        // Verbose logging
    bool verifyChecksums = true; // Verify checksums after materialization
}

/// Materialization result
struct MaterializationResult
{
    bool success;
    size_t filesProcessed;
    size_t filesCreated;
    size_t filesUpdated;
    size_t filesSkipped;
    ulong bytesWritten;
    MaterializationError[] errors;
    
    import std.datetime : Duration;
    Duration duration;
}

/// Materialization error
struct MaterializationError
{
    string path;
    string hash;
    string message;
}

/// Cleanup result
struct CleanupResult
{
    bool success;
    string[] filesToRemove;
    size_t filesRemoved;
    string[] errors;
}

/// Format bytes for human-readable display
private string formatBytes(ulong bytes) @safe
{
    import std.format : format;
    
    if (bytes < 1024)
        return format("%d B", bytes);
    if (bytes < 1024 * 1024)
        return format("%.1f KB", bytes / 1024.0);
    if (bytes < 1024 * 1024 * 1024)
        return format("%.1f MB", bytes / (1024.0 * 1024.0));
    
    return format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
}

/// Format duration for human-readable display
private string formatDuration(Duration duration) @safe
{
    import std.format : format;
    
    if (duration < dur!"seconds"(1))
        return format("%d ms", duration.total!"msecs");
    if (duration < dur!"minutes"(1))
        return format("%.2f s", duration.total!"msecs" / 1000.0);
    
    return format("%.2f min", duration.total!"seconds" / 60.0);
}

