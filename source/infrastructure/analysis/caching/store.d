module infrastructure.analysis.caching.store;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import core.sync.mutex;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.caching.interface_;
import engine.caching.storage.cas;
import infrastructure.utils.files.hash;
import infrastructure.errors;

/// Content-addressable analysis cache
/// Stores FileAnalysis results indexed by content hash for deduplication
/// Inspired by Bazel's action cache and Buck2's DICE engine
final class AnalysisCache : IAnalysisCache
{
    private ContentAddressableStorage cas;
    private string cacheDir;
    private Mutex cacheMutex;
    
    // Statistics
    private size_t hitCount;
    private size_t missCount;
    private size_t storeCount;
    
    this(string cacheDir = ".builder-cache/analysis") @system
    {
        this.cacheDir = cacheDir;
        this.cacheMutex = new Mutex();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        // Use shared CAS for storage efficiency
        this.cas = new ContentAddressableStorage(buildPath(cacheDir, "blobs"));
    }
    
    /// Get cached analysis for a file by content hash
    /// Returns null on cache miss
    BuildResult!(FileAnalysis*) get(string contentHash) @system
    {
        synchronized (cacheMutex)
        {
            // Check if analysis exists in CAS
            auto blobResult = cas.getBlob(contentHash);
            if (blobResult.isErr)
            {
                missCount++;
                return BuildResult!(FileAnalysis*).ok(null);
            }
            
            try
            {
                // Deserialize analysis
                auto data = blobResult.unwrap();
                auto analysis = deserializeAnalysis(data);
                
                hitCount++;
                auto result = new FileAnalysis();
                result.path = analysis.path;
                result.imports = analysis.imports;
                result.contentHash = analysis.contentHash;
                result.hasErrors = analysis.hasErrors;
                result.errors = analysis.errors;
                return BuildResult!(FileAnalysis*).ok(result);
            }
            catch (Exception e)
            {
                missCount++;
                auto error = Errors.cache("Failed to deserialize analysis: " ~ e.msg, Cache.LoadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build();
                return BuildResult!(FileAnalysis*).err(error);
            }
        }
    }
    
    /// Store file analysis indexed by content hash
    VoidBuildResult put(string contentHash, const ref FileAnalysis analysis) @system
    {
        synchronized (cacheMutex)
        {
            try
            {
                // Serialize analysis
                auto data = serializeAnalysis(analysis);
                
                // Store in CAS (automatic deduplication)
                auto storeResult = cas.putBlob(data);
                if (storeResult.isErr)
                    return VoidBuildResult.err(storeResult.unwrapErr());
                
                storeCount++;
                return Ok!BuildError();
            }
            catch (Exception e)
            {
                auto error = Errors.cache("Failed to cache analysis: " ~ e.msg, Cache.WriteFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build();
                return VoidBuildResult.err(error);
            }
        }
    }
    
    /// Check if analysis exists for content hash
    bool has(string contentHash) @system
    {
        synchronized (cacheMutex)
        {
            return cas.hasBlob(contentHash);
        }
    }
    
    /// Get batch of analyses (optimized for bulk operations)
    BuildResult!(FileAnalysis*[string]) getBatch(string[] contentHashes) @system
    {
        FileAnalysis*[string] results;
        
        foreach (hash; contentHashes)
        {
            auto result = get(hash);
            if (result.isErr)
                return BuildResult!(FileAnalysis*[string]).err(result.unwrapErr());
            
            auto analysis = result.unwrap();
            if (analysis !is null)
                results[hash] = analysis;
        }
        
        return BuildResult!(FileAnalysis*[string]).ok(results);
    }
    
    /// Store batch of analyses (optimized for bulk operations)
    VoidBuildResult putBatch(FileAnalysis[string] analyses) @system
    {
        foreach (contentHash, analysis; analyses)
        {
            auto result = put(contentHash, analysis);
            if (result.isErr)
                return result;
        }
        
        return Ok!BuildError();
    }
    
    /// Clear cache
    void clear() @system
    {
        synchronized (cacheMutex)
        {
            if (exists(cacheDir))
            {
                try
                {
                    rmdirRecurse(cacheDir);
                    mkdirRecurse(cacheDir);
                }
                catch (Exception) {}
            }
            
            hitCount = 0;
            missCount = 0;
            storeCount = 0;
        }
    }
    
    /// Get cache statistics (implements IAnalysisCache)
    override IAnalysisCache.Stats getStats() const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            IAnalysisCache.Stats stats;
            stats.hits = hitCount;
            stats.misses = missCount;
            stats.stores = storeCount;
            stats.totalQueries = hitCount + missCount;
            
            if (stats.totalQueries > 0)
                stats.hitRate = (hitCount * 100.0) / stats.totalQueries;
            
            return stats;
        }
    }
    
    // Serialization
    
    private ubyte[] serializeAnalysis(const ref FileAnalysis analysis) @system
    {
        import std.bitmanip : nativeToBigEndian;
        
        auto buffer = appender!(ubyte[]);
        buffer.reserve(4096);
        
        // Version
        buffer.put(cast(ubyte)1);
        
        // Path
        writeString(buffer, analysis.path);
        
        // Content hash
        writeString(buffer, analysis.contentHash);
        
        // Has errors flag
        buffer.put(cast(ubyte)(analysis.hasErrors ? 1 : 0));
        
        // Errors count and data
        buffer.put(nativeToBigEndian(cast(uint)analysis.errors.length)[]);
        foreach (error; analysis.errors)
            writeString(buffer, error);
        
        // Imports count and data
        buffer.put(nativeToBigEndian(cast(uint)analysis.imports.length)[]);
        foreach (imp; analysis.imports)
        {
            writeString(buffer, imp.moduleName);
            buffer.put(cast(ubyte)imp.kind);
            writeString(buffer, imp.location.file);
            buffer.put(nativeToBigEndian(cast(ulong)imp.location.line)[]);
            buffer.put(nativeToBigEndian(cast(ulong)imp.location.column)[]);
        }
        
        return buffer.data;
    }
    
    private FileAnalysis deserializeAnalysis(const ubyte[] data) @system
    {
        import std.bitmanip : bigEndianToNative;
        
        FileAnalysis analysis;
        size_t offset = 0;
        
        // Version
        immutable version_ = data[offset++];
        if (version_ != 1)
            throw new Exception("Unsupported analysis cache version");
        
        // Path
        analysis.path = readString(data, offset);
        
        // Content hash
        analysis.contentHash = readString(data, offset);
        
        // Has errors
        analysis.hasErrors = data[offset++] != 0;
        
        // Errors
        immutable ubyte[4] errorCountBytes = data[offset .. offset + 4][0 .. 4];
        immutable errorCount = bigEndianToNative!uint(errorCountBytes);
        offset += 4;
        
        analysis.errors.length = errorCount;
        foreach (i; 0 .. errorCount)
            analysis.errors[i] = readString(data, offset);
        
        // Imports
        immutable ubyte[4] importCountBytes = data[offset .. offset + 4][0 .. 4];
        immutable importCount = bigEndianToNative!uint(importCountBytes);
        offset += 4;
        
        analysis.imports.length = importCount;
        foreach (i; 0 .. importCount)
        {
            Import imp;
            imp.moduleName = readString(data, offset);
            imp.kind = cast(ImportKind)data[offset++];
            imp.location.file = readString(data, offset);
            
            immutable ubyte[8] lineBytes = data[offset .. offset + 8][0 .. 8];
            imp.location.line = bigEndianToNative!ulong(lineBytes);
            offset += 8;
            
            immutable ubyte[8] colBytes = data[offset .. offset + 8][0 .. 8];
            imp.location.column = bigEndianToNative!ulong(colBytes);
            offset += 8;
            
            analysis.imports[i] = imp;
        }
        
        return analysis;
    }
    
    private static void writeString(Appender)(ref Appender buffer, in string str) @system
    {
        import std.bitmanip : nativeToBigEndian;
        
        buffer.put(nativeToBigEndian(cast(uint)str.length)[]);
        if (str.length > 0)
            buffer.put(cast(const(ubyte)[])str);
    }
    
    private static string readString(const ubyte[] data, ref size_t offset) @system
    {
        import std.bitmanip : bigEndianToNative;
        
        immutable ubyte[4] lenBytes = data[offset .. offset + 4][0 .. 4];
        immutable len = bigEndianToNative!uint(lenBytes);
        offset += 4;
        
        if (len == 0)
            return "";
        
        auto str = cast(string)data[offset .. offset + len];
        offset += len;
        return str.idup;
    }
}

