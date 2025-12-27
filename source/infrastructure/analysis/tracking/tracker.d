module infrastructure.analysis.tracking.tracker;

import std.file;
import std.path;
import std.datetime;
import std.algorithm;
import std.array;
import std.conv;
import core.sync.mutex;
import infrastructure.analysis.tracking.interface_;
import infrastructure.utils.files.hash;
import infrastructure.errors;

/// File change tracking state
struct FileState
{
    string path;
    string metadataHash;  // Fast: mtime + size
    string contentHash;   // Slow: full content hash
    SysTime lastModified;
    ulong size;
    bool exists;
}

/// File change detection using two-tier validation
/// Optimized for minimal I/O: metadata check → content hash only if needed
final class FileChangeTracker : IFileChangeTracker
{
    private FileState[string] states;
    private Mutex trackerMutex;
    
    // Performance metrics
    private size_t metadataChecks;
    private size_t contentHashChecks;
    private size_t changesDetected;
    
    this() @system
    {
        this.trackerMutex = new Mutex();
    }
    
    /// Initialize tracking for a file
    VoidBuildResult track(string path) @system
    {
        synchronized (trackerMutex)
        {
            try
            {
                auto state = captureState(path);
                states[path] = state;
                return Ok!BuildError();
            }
            catch (Exception e)
            {
                return VoidBuildResult.err(
                    Errors.io(path, "Failed to track file: " ~ e.msg, IO.FileReadFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
        }
    }
    
    /// Track multiple files (batch operation)
    VoidBuildResult trackBatch(string[] paths) @system
    {
        foreach (path; paths)
        {
            auto result = track(path);
            if (result.isErr)
                return result;
        }
        return Ok!BuildError();
    }
    
    /// Check if file has changed since last track
    /// Returns: tuple (hasChanged, contentHash)
    BuildResult!ChangeResult checkChange(string path) @system
    {
        synchronized (trackerMutex)
        {
            metadataChecks++;
            
            try
            {
                auto oldState = path in states;
                if (oldState is null)
                {
                    // File not tracked - consider it changed
                    auto newState = captureState(path);
                    states[path] = newState;
                    changesDetected++;
                    
                    return BuildResult!ChangeResult.ok(
                        ChangeResult(true, newState.contentHash, ChangeKind.New)
                    );
                }
                
                // Check if file still exists
                if (!exists(path))
                {
                    if (oldState.exists)
                    {
                        // File was deleted
                        states[path].exists = false;
                        changesDetected++;
                        return BuildResult!ChangeResult.ok(
                            ChangeResult(true, "", ChangeKind.Deleted)
                        );
                    }
                    else
                    {
                        // Still doesn't exist
                        return BuildResult!ChangeResult.ok(
                            ChangeResult(false, "", ChangeKind.Unchanged)
                        );
                    }
                }
                
                // Fast path: metadata check
                auto newMetadataHash = FastHash.hashMetadata(path);
                if (newMetadataHash == oldState.metadataHash)
                {
                    // Metadata unchanged - assume content unchanged
                    return BuildResult!ChangeResult.ok(
                        ChangeResult(false, oldState.contentHash, ChangeKind.Unchanged)
                    );
                }
                
                // Slow path: content changed or metadata touch
                contentHashChecks++;
                auto newContentHash = FastHash.hashFile(path);
                
                if (newContentHash == oldState.contentHash)
                {
                    // Content unchanged, just metadata (e.g., touch)
                    // Update metadata hash
                    states[path].metadataHash = newMetadataHash;
                    states[path].lastModified = DirEntry(path).timeLastModified;
                    
                    return BuildResult!ChangeResult.ok(
                        ChangeResult(false, newContentHash, ChangeKind.Unchanged)
                    );
                }
                
                // Content actually changed
                auto newState = captureState(path);
                states[path] = newState;
                changesDetected++;
                
                return BuildResult!ChangeResult.ok(
                    ChangeResult(true, newContentHash, ChangeKind.Modified)
                );
            }
            catch (Exception e)
            {
                return BuildResult!ChangeResult.err(
                    Errors.io(path, "Failed to check file change: " ~ e.msg, IO.FileReadFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
        }
    }
    
    /// Check multiple files for changes (batch operation)
    BuildResult!(ChangeResult[string]) checkChanges(string[] paths) @system
    {
        ChangeResult[string] results;
        
        foreach (path; paths)
        {
            auto result = checkChange(path);
            if (result.isErr)
                return BuildResult!(ChangeResult[string]).err(result.unwrapErr());
            
            results[path] = result.unwrap();
        }
        
        return BuildResult!(ChangeResult[string]).ok(results);
    }
    
    /// Get current state for a file
    BuildResult!(FileState*) getState(string path) @system
    {
        synchronized (trackerMutex)
        {
            auto state = path in states;
            if (state is null)
            {
                return BuildResult!(FileState*).err(
                    Errors.io(path, "File not tracked", IO.FileNotFound)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            return BuildResult!(FileState*).ok(state);
        }
    }
    
    /// Update state for a file (after analysis)
    VoidBuildResult updateState(string path, string contentHash) @system
    {
        synchronized (trackerMutex)
        {
            auto state = path in states;
            if (state is null)
            {
                return VoidBuildResult.err(
                    Errors.io(path, "File not tracked", IO.FileNotFound)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            state.contentHash = contentHash;
            return Ok!BuildError();
        }
    }
    
    /// Remove file from tracking
    void untrack(string path) @system
    {
        synchronized (trackerMutex)
        {
            states.remove(path);
        }
    }
    
    /// Get all tracked files
    string[] getTrackedFiles() @system
    {
        synchronized (trackerMutex)
        {
            return states.keys;
        }
    }
    
    /// Clear all tracking state
    void clear() @system
    {
        synchronized (trackerMutex)
        {
            states.clear();
            metadataChecks = 0;
            contentHashChecks = 0;
            changesDetected = 0;
        }
    }
    
    /// Get statistics (implements IFileChangeTracker)
    override IFileChangeTracker.Stats getStats() const @system
    {
        synchronized (cast(Mutex)trackerMutex)
        {
            IFileChangeTracker.Stats stats;
            stats.trackedFiles = states.length;
            stats.metadataChecks = metadataChecks;
            stats.contentHashChecks = contentHashChecks;
            stats.changesDetected = changesDetected;
            
            if (metadataChecks > 0)
            {
                immutable fastPath = metadataChecks - contentHashChecks;
                stats.fastPathRate = (fastPath * 100.0) / metadataChecks;
            }
            
            return stats;
        }
    }
    
    // Private helpers
    
    private FileState captureState(string path) @system
    {
        FileState state;
        state.path = path;
        
        if (!exists(path))
        {
            state.exists = false;
            return state;
        }
        
        state.exists = true;
        
        auto info = DirEntry(path);
        state.lastModified = info.timeLastModified;
        state.size = info.size;
        
        state.metadataHash = FastHash.hashMetadata(path);
        state.contentHash = FastHash.hashFile(path);
        
        return state;
    }
}

/// Result of change detection
struct ChangeResult
{
    bool hasChanged;
    string contentHash;
    ChangeKind kind;
}

/// Type of change detected
enum ChangeKind
{
    Unchanged,
    Modified,
    New,
    Deleted
}

