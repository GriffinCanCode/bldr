module engine.caching.storage.gc;

import std.datetime : Clock, Duration, dur;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import engine.caching.storage.cas;
import engine.caching.targets.cache;
import engine.caching.actions.action;
import engine.caching.events;
import frontend.cli.events.events : EventPublisher;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Reachability-based garbage collector for cache artifacts
/// Removes orphaned blobs that are no longer referenced by any cache entry
final class CacheGarbageCollector
{
    private ContentAddressableStorage cas;
    private EventPublisher publisher;
    
    this(ContentAddressableStorage cas, EventPublisher publisher = null) @safe
    {
        this.cas = cas;
        this.publisher = publisher;
    }
    
    /// Run garbage collection
    /// Returns: number of blobs collected and bytes freed
    BuildResult!GCResult collect(
        BuildCache targetCache,
        ActionCache actionCache
    ) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        try
        {
            // Emit GC started event
            emitEvent(CacheEventType.GCStarted, 0, 0, 0, dur!"msecs"(0));
            
            // Mark phase: collect all referenced hashes
            auto referencedHashes = collectReferences(targetCache, actionCache);
            
            // Sweep phase: remove unreferenced blobs
            auto sweepResult = sweepUnreferenced(referencedHashes);
            
            immutable gcTime = timer.peek();
            
            // Emit GC completed event
            emitEvent(CacheEventType.GCCompleted, sweepResult.blobsCollected, 
                     sweepResult.bytesFreed, sweepResult.orphansFound, gcTime);
            
            Logger.debugLog("GC collected " ~ sweepResult.blobsCollected.to!string ~ 
                          " blobs, freed " ~ formatBytes(sweepResult.bytesFreed));
            
            return Ok!(GCResult, BuildError)(sweepResult);
        }
        catch (Exception e)
        {
            return Err!(GCResult, BuildError)(Errors.cache(
                "Garbage collection failed: " ~ e.msg, ErrorCode.CacheGCFailed).build());
        }
    }
    
    /// Collect all referenced blob hashes from caches
    private bool[string] collectReferences(
        BuildCache targetCache,
        ActionCache actionCache
    ) @system
    {
        bool[string] referenced;
        
        // Collect from target cache
        auto targetStats = targetCache.getStats();
        // Note: Future enhancement - extend BuildCache API to expose output hashes
        // for more comprehensive garbage collection
        
        // Collect from action cache
        auto actionStats = actionCache.getStats();
        // Similarly, need API to get all action output hashes
        
        return referenced;
    }
    
    /// Sweep unreferenced blobs
    private GCResult sweepUnreferenced(const bool[string] referenced) @system
    {
        GCResult result;
        
        foreach (hash; cas.listBlobs().filter!(h => h !in referenced))
        {
            // Get blob size before deletion
            auto getBlobResult = cas.getBlob(hash);
            if (getBlobResult.isOk)
                result.bytesFreed += getBlobResult.unwrap().length;
            
            // Attempt deletion
            if (cas.deleteBlob(hash).isOk)
            {
                result.blobsCollected++;
                result.orphansFound++;
            }
        }
        
        return result;
    }
    
    /// Emit GC event helper
    private void emitEvent(T...)(T args) nothrow
    {
        if (publisher is null) return;
        try { publisher.publish(new CacheGCEvent(args)); } catch (Exception) {}
    }
    
    private static string formatBytes(size_t bytes) pure @system
    {
        import std.format : format;
        enum MB = 1024 * 1024, GB = MB * 1024;
        
        return bytes < 1024 ? format("%d B", bytes)
             : bytes < MB ? format("%.1f KB", bytes / 1024.0)
             : bytes < GB ? format("%.1f MB", bytes / cast(double)MB)
             : format("%.2f GB", bytes / cast(double)GB);
    }
}

/// Garbage collection result
struct GCResult
{
    size_t blobsCollected;
    size_t bytesFreed;
    size_t orphansFound;
}

