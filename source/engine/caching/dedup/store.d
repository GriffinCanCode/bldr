module engine.caching.dedup.store;

import std.file : exists, mkdirRecurse, write, read, remove, dirEntries, SpanMode;
import std.path : buildPath, dirName, baseName;
import std.algorithm : map, filter, sum;
import std.array : array;
import std.conv : to;
import std.datetime : Clock;
import core.sync.mutex : Mutex;
import engine.caching.storage.cas : ContentAddressableStorage;
import engine.caching.dedup.dedup : DedupEngine, BlobRef, DedupStats;
import engine.caching.dedup.manifest;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// Deduplicated action result store
/// Combines CAS blob storage with manifest-based action results
/// 
/// Architecture:
/// ┌─────────────────────────────────────────┐
/// │           DedupStore                     │
/// ├─────────────────────────────────────────┤
/// │  manifests/           blobs/            │
/// │  ├── action1.mnft     ├── ab/          │
/// │  ├── action2.mnft     │   └── ab12...  │
/// │  └── action3.mnft     ├── cd/          │
/// │                       │   └── cd34...  │
/// │  (small metadata)     (large content)  │
/// └─────────────────────────────────────────┘
/// 
/// Benefits:
/// - 30-70% storage reduction on large monorepos
/// - O(1) deduplication via content addressing
/// - Incremental GC via reference counting
final class DedupStore
{
    private string storeDir;
    private string manifestDir;
    private DedupEngine engine;
    private ContentAddressableStorage cas;
    private Mutex storeMutex;
    
    // Index: actionId -> manifest hash
    private string[string] manifestIndex;
    
    this(string storeDir = ".builder-cache/dedup") @system
    {
        this.storeDir = storeDir;
        this.manifestDir = buildPath(storeDir, "manifests");
        this.storeMutex = new Mutex();
        
        // Initialize directories
        if (!exists(storeDir)) mkdirRecurse(storeDir);
        if (!exists(manifestDir)) mkdirRecurse(manifestDir);
        
        // Initialize CAS and dedup engine
        this.cas = new ContentAddressableStorage(buildPath(storeDir, "blobs"));
        this.engine = new DedupEngine(cas);
        
        // Load manifest index
        loadIndex();
    }
    
    /// Store action result with deduplication
    /// Returns: manifest hash for retrieval
    BuildResult!string put(
        string actionId,
        const(ubyte)[][] outputs,
        string[] paths,
        string inputsHash,
        string execHash = "",
        bool success = true
    ) @system
    {
        synchronized (storeMutex)
        {
            // Build manifest (stores blobs in CAS)
            auto manifestResult = buildManifest(
                engine, actionId, outputs, paths, inputsHash, execHash, success);
            
            if (manifestResult.isErr)
                return Err!(string, BuildError)(manifestResult.unwrapErr());
            
            auto manifest = manifestResult.unwrap();
            
            // Serialize and store manifest
            auto manifestData = ManifestStorage.serialize(manifest);
            immutable manifestHash = FastHash.hashBytes(manifestData);
            
            auto manifestPath = getManifestPath(actionId);
            auto dir = dirName(manifestPath);
            if (!exists(dir)) mkdirRecurse(dir);
            
            write(manifestPath, manifestData);
            
            // Update index
            manifestIndex[actionId] = manifestHash;
            
            return Ok!(string, BuildError)(manifestHash);
        }
    }
    
    /// Get action result manifest
    BuildResult!ActionManifest get(string actionId) @system
    {
        synchronized (storeMutex)
        {
            auto manifestPath = getManifestPath(actionId);
            
            if (!exists(manifestPath))
                return Err!(ActionManifest, BuildError)(Errors.cache(
                    "Manifest not found: " ~ actionId, Cache.NotFound).build());
            
            auto data = cast(ubyte[])read(manifestPath);
            return ManifestStorage.deserialize(data);
        }
    }
    
    /// Check if action result exists
    bool has(string actionId) @system
    {
        synchronized (storeMutex)
        {
            return exists(getManifestPath(actionId));
        }
    }
    
    /// Materialize action outputs to memory
    BuildResult!(OutputFile[]) materialize(string actionId) @system
    {
        auto manifestResult = get(actionId);
        if (manifestResult.isErr)
            return Err!(OutputFile[], BuildError)(manifestResult.unwrapErr());
        
        return materializeManifest(engine, manifestResult.unwrap());
    }
    
    /// Delete action result and dereference blobs
    VoidBuildResult remove_(string actionId) @system
    {
        synchronized (storeMutex)
        {
            // Get manifest to find blob refs
            auto manifestResult = get(actionId);
            if (manifestResult.isOk)
            {
                // Dereference all blobs
                auto manifest = manifestResult.unwrap();
                auto hashes = collectBlobHashes(manifest);
                engine.removeRefs(hashes);
            }
            
            // Remove manifest file
            auto manifestPath = getManifestPath(actionId);
            if (exists(manifestPath))
                remove(manifestPath);
            
            manifestIndex.remove(actionId);
            
            return Ok!BuildError();
        }
    }
    
    /// Bulk remove action results (optimized for eviction)
    VoidBuildResult removeBatch(const(string)[] actionIds) @system
    {
        synchronized (storeMutex)
        {
            string[] allHashes;
            
            foreach (actionId; actionIds)
            {
                auto manifestResult = get(actionId);
                if (manifestResult.isOk)
                    allHashes ~= collectBlobHashes(manifestResult.unwrap());
                
                auto manifestPath = getManifestPath(actionId);
                if (exists(manifestPath))
                    remove(manifestPath);
                
                manifestIndex.remove(actionId);
            }
            
            // Bulk dereference
            engine.removeRefs(allHashes);
            
            return Ok!BuildError();
        }
    }
    
    /// Get store statistics
    DedupStoreStats getStats() @system
    {
        synchronized (storeMutex)
        {
            DedupStoreStats stats;
            stats.dedup = engine.getStats();
            stats.manifestCount = manifestIndex.length;
            
            // Calculate manifest storage
            try
            {
                stats.manifestBytes = dirEntries(manifestDir, SpanMode.depth)
                    .filter!(e => e.isFile)
                    .map!(e => e.size)
                    .sum;
            }
            catch (Exception) {}
            
            // Get CAS stats
            auto casStats = cas.getStats();
            stats.blobCount = casStats.uniqueBlobs;
            stats.blobBytes = casStats.totalSize;
            stats.dedupRatio = casStats.deduplicationRatio;
            
            return stats;
        }
    }
    
    /// Get the underlying dedup engine (for advanced operations)
    DedupEngine getEngine() @system => engine;
    
    /// Get the underlying CAS (for direct blob access)
    ContentAddressableStorage getCAS() @system => cas;
    
    /// List all stored action IDs
    string[] listActions() @system
    {
        synchronized (storeMutex)
        {
            return manifestIndex.keys.array;
        }
    }
    
    /// Verify store integrity
    BuildResult!IntegrityReport verify() @system
    {
        IntegrityReport report;
        
        synchronized (storeMutex)
        {
            foreach (actionId; manifestIndex.keys)
            {
                auto manifestResult = get(actionId);
                if (manifestResult.isErr)
                {
                    report.corruptedManifests ~= actionId;
                    continue;
                }
                
                auto manifest = manifestResult.unwrap();
                foreach (ref entry; manifest.outputs)
                {
                    if (!cas.hasBlob(entry.blobHash))
                        report.missingBlobs ~= entry.blobHash;
                }
                
                report.manifestsChecked++;
            }
            
            report.blobsChecked = cast(size_t)cas.listBlobs().length;
        }
        
        return Ok!(IntegrityReport, BuildError)(report);
    }
    
private:
    string getManifestPath(string actionId) const @system
    {
        // Shard by first 2 chars of hash for filesystem performance
        immutable hash = FastHash.hashString(actionId);
        immutable shard = hash.length >= 2 ? hash[0 .. 2] : "00";
        return buildPath(manifestDir, shard, actionId ~ ".mnft");
    }
    
    void loadIndex() @system
    {
        try
        {
            foreach (entry; dirEntries(manifestDir, "*.mnft", SpanMode.depth))
            {
                if (entry.isFile)
                {
                    auto actionId = baseName(entry.name)[0 .. $ - 5]; // strip .mnft
                    auto data = cast(ubyte[])read(entry.name);
                    manifestIndex[actionId] = FastHash.hashBytes(data);
                }
            }
        }
        catch (Exception) {}
    }
}

/// Store statistics
struct DedupStoreStats
{
    DedupStats dedup;           // Deduplication engine stats
    size_t manifestCount;       // Number of action manifests
    size_t manifestBytes;       // Total manifest storage
    size_t blobCount;           // Unique blobs in CAS
    size_t blobBytes;           // Total blob storage
    float dedupRatio;           // Deduplication ratio (%)
    
    /// Estimated savings vs non-deduplicated storage
    size_t estimatedSavings() const pure @safe
        => dedup.savedBytes;
    
    /// Total storage used
    size_t totalStorage() const pure @safe
        => manifestBytes + blobBytes;
}

/// Store integrity report
struct IntegrityReport
{
    size_t manifestsChecked;
    size_t blobsChecked;
    string[] corruptedManifests;
    string[] missingBlobs;
    
    bool isHealthy() const pure @safe
        => corruptedManifests.length == 0 && missingBlobs.length == 0;
}

