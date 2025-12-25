module engine.caching.storage.source_tracker;

import std.file : exists;
import std.algorithm : map, filter;
import std.array : array;
import core.sync.mutex : Mutex;
import engine.caching.storage.source_repository : SourceRepository;
import engine.caching.storage.source_ref : SourceRef, SourceRefSet;
import infrastructure.analysis.tracking.tracker : FileChangeTracker;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// High-level source tracker combining change detection with content-addressing
/// Integrates FileChangeTracker (for change detection) with SourceRepository (for CAS storage)
final class SourceTracker
{
    private SourceRepository repository;
    private FileChangeTracker changeTracker;
    private Mutex trackerMutex;
    
    // Statistics
    private size_t filesTracked;
    private size_t changesDetected;
    private size_t storageOperations;
    
    this(SourceRepository repository, FileChangeTracker changeTracker = null) @system
    {
        this.repository = repository;
        this.changeTracker = changeTracker is null ? new FileChangeTracker() : changeTracker;
        this.trackerMutex = new Mutex();
    }
    
    /// Track and store a source file
    /// Returns source reference or error
    BuildResult!SourceRef track(string path) @system
    {
        synchronized (trackerMutex)
        {
            // Store in repository (CAS)
            auto storeResult = repository.store(path);
            if (storeResult.isErr)
                return storeResult;
            
            // Track for change detection
            auto trackResult = changeTracker.track(path);
            if (trackResult.isErr)
                return Err!(SourceRef, BuildError)(trackResult.unwrapErr());
            
            filesTracked++;
            storageOperations++;
            
            return storeResult;
        }
    }
    
    /// Track and store multiple source files
    BuildResult!SourceRefSet trackBatch(const(string)[] paths) @system
    {
        synchronized (trackerMutex)
        {
            // Store all in repository
            auto storeResult = repository.storeBatch(paths);
            if (storeResult.isErr)
                return storeResult;
            
            // Track all for change detection
            auto trackResult = changeTracker.trackBatch(paths.dup);
            if (trackResult.isErr)
                return Err!(SourceRefSet, BuildError)(trackResult.unwrapErr());
            
            filesTracked += paths.length;
            storageOperations += paths.length;
            
            return storeResult;
        }
    }
    
    /// Check if any tracked files have changed
    /// Returns array of changed file paths with their new references
    struct ChangedFile
    {
        string path;
        string oldHash;
        string newHash;
        SourceRef newRef;
    }
    
    BuildResult!(ChangedFile[]) detectChanges(const(string)[] paths) @system
    {
        synchronized (trackerMutex)
        {
            ChangedFile[] changed;
            
            foreach (path; paths)
            {
                if (!exists(path))
                    continue;
                
                // Check if file changed
                auto changeResult = changeTracker.checkChange(path);
                if (changeResult.isErr)
                    continue;
                
                if (!changeResult.unwrap().hasChanged)
                    continue;
                
                // Get old hash
                auto oldRefResult = repository.getRefByPath(path);
                immutable oldHash = oldRefResult.isOk ? oldRefResult.unwrap().hash : "";
                
                // Compute new hash and store
                auto newRefResult = repository.store(path);
                if (newRefResult.isErr)
                    continue;
                
                auto newRef = newRefResult.unwrap();
                
                ChangedFile cf;
                cf.path = path;
                cf.oldHash = oldHash;
                cf.newHash = newRef.hash;
                cf.newRef = newRef;
                
                changed ~= cf;
                changesDetected++;
            }
            
            return Ok!(ChangedFile[], BuildError)(changed);
        }
    }
    
    /// Verify file integrity (matches stored hash)
    BuildResult!bool verify(string path) @system
    {
        synchronized (trackerMutex)
        {
            return repository.verify(path);
        }
    }
    
    /// Get source reference for path
    BuildResult!SourceRef getRef(string path) @system
    {
        synchronized (trackerMutex)
        {
            return repository.getRefByPath(path);
        }
    }
    
    /// Materialize source file from CAS
    VoidBuildResult materialize(string hash, string targetPath) @system
    {
        synchronized (trackerMutex)
        {
            return repository.materialize(hash, targetPath);
        }
    }
    
    /// Untrack file
    void untrack(string path) @system
    {
        synchronized (trackerMutex)
        {
            changeTracker.untrack(path);
        }
    }
    
    /// Get statistics
    struct TrackerStats
    {
        size_t filesTracked;
        size_t changesDetected;
        size_t storageOperations;
        
        // From repository
        size_t sourcesStored;
        size_t deduplicationHits;
        ulong bytesStored;
        ulong bytesSaved;
        float deduplicationRatio;
    }
    
    TrackerStats getStats() @system
    {
        synchronized (trackerMutex)
        {
            TrackerStats stats;
            stats.filesTracked = filesTracked;
            stats.changesDetected = changesDetected;
            stats.storageOperations = storageOperations;
            
            // Get repository stats
            auto repoStats = repository.getStats();
            stats.sourcesStored = repoStats.sourcesStored;
            stats.deduplicationHits = repoStats.deduplicationHits;
            stats.bytesStored = repoStats.bytesStored;
            stats.bytesSaved = repoStats.bytesSaved;
            stats.deduplicationRatio = repoStats.deduplicationRatio;
            
            return stats;
        }
    }
    
    /// Clear all tracking
    void clear() @system
    {
        synchronized (trackerMutex)
        {
            changeTracker.clear();
            filesTracked = 0;
            changesDetected = 0;
            storageOperations = 0;
        }
    }
}

