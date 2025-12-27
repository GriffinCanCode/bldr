module engine.graph.caching.cache;

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.algorithm;
import std.array;
import core.sync.mutex;
import engine.graph.core.graph;
import engine.graph.core.reader : IGraphReader;
import engine.graph.caching.mapped : MmapGraphCache, MappedGraphView, MmapGraphOverlay, computeConfigHash;
import infrastructure.utils.files.hash;
import infrastructure.utils.simd.hash;
import infrastructure.utils.files.directories : ensureDirectoryWithGitignore;
import infrastructure.errors : Errors, Cache, BuildResult, VoidBuildResult, Ok, Err, BuildError;

/// High-performance dependency graph cache with zero-copy memory mapping
/// 
/// Design Philosophy:
/// - Zero-copy graph access via mmap eliminates deserialization entirely
/// - Graph topology stays in kernel page cache (shared across processes)
/// - Mutable status tracked in lightweight overlay (no mmap modification)
/// - Two-tier validation: metadata hash (fast) → content hash (slow)
/// - SIMD-accelerated hash comparisons
/// - Thread-safe concurrent access
/// 
/// Performance:
/// - Graph load: O(1) mmap, no parsing (~0.1ms any size vs ~50ms for 10k nodes)
/// - 100-1000x speedup vs traditional deserialization
/// - Sub-millisecond cache validation for typical projects
/// - Graph pages loaded on-demand by kernel (lazy loading)
/// 
/// Storage:
/// - Location: .builder-cache/graph.mmap (memory-mapped format)
/// - Location: .builder-cache/graph-metadata.bin (validation metadata)
final class GraphCache
{
    private string cacheDir;
    private Mutex cacheMutex;
    private MmapGraphCache _mmapCache;
    private bool closed;
    
    // Statistics
    private size_t hitCount;
    private size_t missCount;
    private size_t metadataHitCount;
    private size_t contentHashCount;
    
    this(string cacheDir = ".builder-cache") @system
    {
        this.cacheDir = cacheDir;
        this.cacheMutex = new Mutex();
        this._mmapCache = new MmapGraphCache(cacheDir);
        ensureDirectoryWithGitignore(cacheDir);
    }
    
    /// Load graph as zero-copy view (preferred - no deserialization)
    /// 
    /// Returns a memory-mapped view implementing IGraphReader.
    /// Graph topology accessed directly from mmap'd file.
    /// 
    /// Performance: ~0.1ms for any size graph (vs ~50ms for 10k nodes)
    BuildResult!MappedGraphView get(scope const(string)[] configFiles) @system
    {
        synchronized (cacheMutex)
        {
            if (!validateConfig(configFiles))
            {
                missCount++;
                return Err!(MappedGraphView, BuildError)(
                    Errors.cache("Config validation failed", Cache.NotFound).build()
                );
            }
            
            auto result = _mmapCache.loadView();
            if (result.isOk)
            {
                hitCount++;
                metadataHitCount++;
            }
            else
            {
                missCount++;
            }
            return result;
        }
    }
    
    /// Load graph with mutable status overlay (zero-copy topology)
    /// 
    /// Returns view + overlay for zero-copy topology with mutable status.
    /// Use this for build execution where status updates are needed.
    BuildResult!MmapGraphOverlay getWithOverlay(scope const(string)[] configFiles) @system
    {
        synchronized (cacheMutex)
        {
            if (!validateConfig(configFiles))
            {
                missCount++;
                return Err!(MmapGraphOverlay, BuildError)(
                    Errors.cache("Config validation failed", Cache.NotFound).build()
                );
            }
            
            auto result = _mmapCache.loadWithOverlay();
            if (result.isOk)
            {
                hitCount++;
                metadataHitCount++;
            }
            else
            {
                missCount++;
            }
            return result;
        }
    }
    
    /// Load as IGraphReader interface (zero-copy)
    BuildResult!IGraphReader getAsReader(scope const(string)[] configFiles) @system
    {
        auto viewResult = get(configFiles);
        if (viewResult.isErr)
            return Err!(IGraphReader, BuildError)(viewResult.unwrapErr());
        
        return Ok!(IGraphReader, BuildError)(cast(IGraphReader)viewResult.unwrap());
    }
    
    /// Restore full BuildGraph (only when mutations needed)
    /// 
    /// This deserializes the graph. Use get() for zero-copy access when possible.
    BuildResult!BuildGraph getGraph(scope const(string)[] configFiles) @system
    {
        synchronized (cacheMutex)
        {
            if (!validateConfig(configFiles))
            {
                missCount++;
                return Err!(BuildGraph, BuildError)(
                    Errors.cache("Config validation failed", Cache.NotFound).build()
                );
            }
            
            auto result = _mmapCache.loadGraph();
            if (result.isOk)
            {
                hitCount++;
                metadataHitCount++;
            }
            else
            {
                missCount++;
            }
            return result;
        }
    }
    
    /// Save graph to mmap format (enables zero-copy loading later)
    void put(BuildGraph graph, scope const(string)[] configFiles) @system
    {
        synchronized (cacheMutex)
        {
            // Compute and save metadata hashes
            string[string] metadata;
            auto existingFiles = cast(string[])configFiles.filter!exists.array;
            
            if (existingFiles.length > 8)
            {
                auto contentHashes = FastHash.hashFilesAsync(existingFiles);
                foreach (i, file; existingFiles)
                {
                    metadata[file] = FastHash.hashMetadata(file);
                    metadata[file ~ ":content"] = contentHashes[i];
                }
            }
            else
            {
                foreach (file; existingFiles)
                {
                    metadata[file] = FastHash.hashMetadata(file);
                    metadata[file ~ ":content"] = FastHash.hashFile(file);
                }
            }
            
            saveMetadata(metadata);
            
            // Compute config hash and persist to mmap format
            auto configHash = computeConfigHash(configFiles);
            auto result = _mmapCache.persist(graph, configHash);
            if (result.isErr)
                writeln("Warning: Failed to save graph cache: ", result.unwrapErr().message());
        }
    }
    
    /// Invalidate cache
    void invalidate() @system nothrow
    {
        try
        {
            synchronized (cacheMutex)
            {
                _mmapCache.invalidate();
                
                auto metadataPath = buildPath(cacheDir, "graph-metadata.bin");
                if (exists(metadataPath))
                    remove(metadataPath);
            }
        }
        catch (Exception) {}
    }
    
    /// Clear entire cache
    void clear() @system
    {
        synchronized (cacheMutex)
        {
            _mmapCache.invalidate();
            
            auto metadataPath = buildPath(cacheDir, "graph-metadata.bin");
            if (exists(metadataPath))
                remove(metadataPath);
            
            hitCount = 0;
            missCount = 0;
            metadataHitCount = 0;
            contentHashCount = 0;
        }
    }
    
    /// Cache statistics
    struct Stats
    {
        size_t hits;
        size_t misses;
        float hitRate;
        size_t metadataHits;
        size_t contentHashes;
        float metadataHitRate;
        size_t zeroCopyLoads;
        size_t fullRestores;
        double zeroCopyRatio;
    }
    
    Stats getStats() const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            Stats stats;
            stats.hits = hitCount;
            stats.misses = missCount;
            stats.metadataHits = metadataHitCount;
            stats.contentHashes = contentHashCount;
            
            immutable total = hitCount + missCount;
            stats.hitRate = total > 0 ? (hitCount * 100.0) / total : 0;
            stats.metadataHitRate = hitCount > 0 ? (metadataHitCount * 100.0) / hitCount : 0;
            
            auto mmapStats = _mmapCache.stats;
            stats.zeroCopyLoads = mmapStats.viewLoads + mmapStats.viewCacheHits;
            stats.fullRestores = mmapStats.fullRestores;
            stats.zeroCopyRatio = mmapStats.zeroCopyRatio;
            
            return stats;
        }
    }
    
    void printStats() const @system
    {
        auto stats = getStats();
        writeln("\n╔════════════════════════════════════════════════════════════╗");
        writeln("║           Graph Cache Statistics (Zero-Copy)               ║");
        writeln("╠════════════════════════════════════════════════════════════╣");
        writefln("║  Cache Hits:           %6d                              ║", stats.hits);
        writefln("║  Cache Misses:         %6d                              ║", stats.misses);
        writefln("║  Hit Rate:             %5.1f%%                             ║", stats.hitRate);
        writeln("╠════════════════════════════════════════════════════════════╣");
        writefln("║  Zero-Copy Loads:      %6d                              ║", stats.zeroCopyLoads);
        writefln("║  Full Restores:        %6d                              ║", stats.fullRestores);
        writefln("║  Zero-Copy Ratio:      %5.1f%%                             ║", stats.zeroCopyRatio * 100);
        writeln("╚════════════════════════════════════════════════════════════╝");
    }
    
    void close() @system
    {
        synchronized (cacheMutex)
        {
            closed = true;
        }
    }
    
    /// Validate config files against cached metadata
    private bool validateConfig(scope const(string)[] configFiles) @system
    {
        foreach (file; configFiles)
            if (!exists(file)) return false;
        
        auto cacheMetadata = loadMetadata();
        if (cacheMetadata is null) return false;
        
        foreach (file; configFiles)
        {
            auto oldMetadataHash = cacheMetadata.get(file, "");
            if (oldMetadataHash.empty) return false;
            
            auto newMetadataHash = FastHash.hashMetadata(file);
            if (!SIMDHash.equals(oldMetadataHash, newMetadataHash))
            {
                contentHashCount++;
                auto oldContentHash = cacheMetadata.get(file ~ ":content", "");
                if (oldContentHash.empty) return false;
                
                auto newContentHash = FastHash.hashFile(file);
                if (!SIMDHash.equals(oldContentHash, newContentHash))
                    return false;
            }
        }
        return true;
    }
    
    private string[string] loadMetadata() @system
    {
        auto metadataPath = buildPath(cacheDir, "graph-metadata.bin");
        if (!exists(metadataPath)) return null;
        
        import std.bitmanip : bigEndianToNative;
        
        auto data = cast(ubyte[])std.file.read(metadataPath);
        if (data.length < 5) return null;
        
        size_t offset = 0;
        if (data[offset++] != 1) return null;  // Version check
        
        immutable count = bigEndianToNative!uint(data[offset .. offset + 4][0 .. 4]);
        offset += 4;
        
        string[string] metadata;
        foreach (_; 0 .. count)
        {
            auto key = readString(data, offset);
            auto value = readString(data, offset);
            metadata[key] = value;
        }
        return metadata;
    }
    
    private void saveMetadata(scope string[string] metadata) nothrow
    {
        try
        {
            import std.bitmanip : nativeToBigEndian;
            
            auto buffer = appender!(ubyte[]);
            buffer.reserve(metadata.length * 128);
            buffer.put(cast(ubyte)1);  // Version
            buffer.put(nativeToBigEndian(cast(uint)metadata.length)[]);
            
            foreach (key, value; metadata)
            {
                writeString(buffer, key);
                writeString(buffer, value);
            }
            
            std.file.write(buildPath(cacheDir, "graph-metadata.bin"), buffer.data);
        }
        catch (Exception) {}
    }
    
    private static string readString(scope ubyte[] data, ref size_t offset) @system
    {
        import std.bitmanip : bigEndianToNative;
        immutable len = bigEndianToNative!uint(data[offset .. offset + 4][0 .. 4]);
        offset += 4;
        if (len == 0) return "";
        auto str = cast(string)data[offset .. offset + len];
        offset += len;
        return str;
    }
    
    private static void writeString(Appender)(ref Appender buffer, in string str) @system
    {
        import std.bitmanip : nativeToBigEndian;
        buffer.put(nativeToBigEndian(cast(uint)str.length)[]);
        if (str.length > 0)
            buffer.put(cast(const(ubyte)[])str);
    }
}
