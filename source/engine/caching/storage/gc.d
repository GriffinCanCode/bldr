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
import infrastructure.utils.logging;

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
    ///
    /// Mark-and-sweep over the CAS. The caller must supply every root set that
    /// can reach a blob — the two caches below plus `extraRoots` for producers
    /// the GC cannot see (the source repository, most importantly). A blob
    /// absent from the union is deleted, so an incomplete root set is data loss.
    ///
    /// Returns: number of blobs collected and bytes freed
    BuildResult!GCResult collect(
        BuildCache targetCache,
        ActionCache actionCache,
        const bool[string] extraRoots = null
    ) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        try
        {
            // Emit GC started event
            emitEvent(CacheEventType.GCStarted, 0, 0, 0, dur!"msecs"(0));
            
            // Mark phase: collect all referenced hashes
            auto referencedHashes = collectReferences(targetCache, actionCache, extraRoots);
            auto blobs = cas.listBlobs();
            
            // Refuse to sweep on an empty root set against a populated store: that
            // means the mark phase failed to see the roots, not that everything
            // is garbage. Sweeping here would wipe the entire cache.
            if (referencedHashes.length == 0 && blobs.length > 0)
            {
                return Err!(GCResult, BuildError)(Errors.cache(
                    "Refusing to collect: no cache entries reference any blob, " ~
                    "but the store holds " ~ blobs.length.to!string ~ ". This " ~
                    "indicates an incomplete mark phase rather than a fully " ~
                    "garbage store.",
                    Cache.GCFailed).build());
            }
            
            // Sweep phase: remove unreferenced blobs
            auto sweepResult = sweepUnreferenced(blobs, referencedHashes);
            
            immutable gcTime = timer.peek();
            
            // Emit GC completed event
            emitEvent(CacheEventType.GCCompleted, sweepResult.blobsCollected, 
                     sweepResult.bytesFreed, sweepResult.orphansFound, gcTime);
            
            structuredLog.debug_("gc_completed")
                .field("blobs_collected", sweepResult.blobsCollected)
                .field("bytes_freed", sweepResult.bytesFreed)
                .emit();
            
            return Ok!(GCResult, BuildError)(sweepResult);
        }
        catch (Exception e)
        {
            return Err!(GCResult, BuildError)(Errors.cache(
                "Garbage collection failed: " ~ e.msg, Cache.GCFailed).build());
        }
    }
    
    /// Collect all referenced blob hashes from caches
    private bool[string] collectReferences(
        BuildCache targetCache,
        ActionCache actionCache,
        const bool[string] extraRoots
    ) @system
    {
        bool[string] referenced;
        
        foreach (hash; targetCache.referencedHashes().byKey)
            referenced[hash] = true;
        
        foreach (hash; actionCache.referencedHashes().byKey)
            referenced[hash] = true;
        
        foreach (hash; extraRoots.byKey)
            referenced[hash] = true;
        
        return referenced;
    }
    
    /// Sweep unreferenced blobs
    private GCResult sweepUnreferenced(string[] blobs, const bool[string] referenced) @system
    {
        GCResult result;
        
        foreach (hash; blobs.filter!(h => h !in referenced))
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

