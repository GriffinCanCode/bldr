module engine.caching.distributed.remote.client;

import std.datetime : Clock, Duration, dur;
import std.file : exists, read, write, remove, getSize;
import std.path : buildPath;
import std.algorithm : min;
import core.sync.mutex;
import engine.caching.distributed.remote.protocol;
import engine.caching.distributed.remote.transport;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.security.integrity : IntegrityValidator;
import infrastructure.utils.compression.compress;
import infrastructure.utils.files.chunking : ChunkManifest, ChunkTransfer, TransferStats, ContentChunker;
import infrastructure.errors;

/// Remote cache client with connection pooling and retry logic
/// Provides high-level interface for artifact storage and retrieval
final class RemoteCacheClient
{
    private RemoteCacheConfig config;
    private HttpTransport transport;
    private RemoteCacheStats stats;
    private Mutex statsMutex;
    private IntegrityValidator validator;
    
    /// Constructor
    this(RemoteCacheConfig config) @trusted
    {
        this.config = config;
        this.transport = new HttpTransport(config);
        this.statsMutex = new Mutex();
        
        // Initialize integrity validator for workspace isolation
        import std.file : getcwd;
        this.validator = IntegrityValidator.fromEnvironment(getcwd());
    }
    
    /// Destructor
    ~this() @trusted
    {
        // Transport cleanup handled by its destructor
    }
    
    /// Fetch artifact from remote cache
    /// Returns: artifact data or error
    BuildResult!(ubyte[]) get(string contentHash) @trusted
    {
        if (!config.enabled())
            return Err!(ubyte[], BuildError)(
                Errors.cache("Remote cache not configured", ErrorCode.CacheDisabled).build());
        
        immutable startTime = Clock.currStdTime();
        
        // Execute with retry logic
        auto result = executeWithRetry(() => transport.get(contentHash));
        
        synchronized (statsMutex)
        {
            stats.getRequests++;
            
            if (result.isOk)
            {
                stats.hits++;
                auto data = result.unwrap();
                stats.bytesDownloaded += data.length;
                
                // Decompress if needed (check first byte for compression marker)
                if (data.length > 0 && data[0] == 0xFD)  // Zstd magic number
                {
                    auto compressor = new Compressor();
                    auto decompressResult = compressor.decompress(data, CompressionAlgorithm.Zstd);
                    
                    if (decompressResult.isOk)
                        return Ok!(ubyte[], BuildError)(decompressResult.unwrap());
                    // If decompression fails, return compressed data (fallback)
                }
                else if (data.length > 0 && data[0] == 0x04)  // LZ4 magic number
                {
                    auto compressor = new Compressor();
                    auto decompressResult = compressor.decompress(data, CompressionAlgorithm.Lz4);
                    
                    if (decompressResult.isOk)
                        return Ok!(ubyte[], BuildError)(decompressResult.unwrap());
                }
            }
            else
            {
                stats.misses++;
                
                // Check if it's truly missing vs error
                auto error = result.unwrapErr();
                if (auto cacheErr = cast(CacheError)error)
                {
                    if (cacheErr.code != ErrorCode.CacheNotFound)
                        stats.errors++;
                }
                else
                {
                    stats.errors++;
                }
            }
            
            updateLatency(startTime);
            stats.compute();
        }
        
        return result;
    }
    
    /// Store artifact in remote cache
    BuildResult!bool put(string contentHash, const(ubyte)[] data) @trusted
    {
        if (!config.enabled())
            return Err!(bool, BuildError)(
                Errors.cache("Remote cache not configured", ErrorCode.CacheDisabled).build());
        
        // Check size limit
        if (data.length > config.maxArtifactSize)
            return Err!(bool, BuildError)(
                Errors.cache("Artifact exceeds maximum size", ErrorCode.CacheTooLarge).build());
        
        immutable startTime = Clock.currStdTime();
        
        // Compress if enabled and beneficial
        ubyte[] payload = cast(ubyte[])data;
        if (config.enableCompression && data.length > 1024)
        {
            auto compressor = new Compressor(CompressionAlgorithm.Zstd, StandardLevel.Default);
            auto compressResult = compressor.compress(data);
            
            if (compressResult.isOk)
            {
                auto compressed = compressResult.unwrap();
                
                // Only use compressed version if it's significantly smaller (>5% reduction)
                if (Compressor.shouldCompress(compressed.originalSize, compressed.compressedSize))
                {
                    payload = compressed.data;
                }
            }
            // On compression failure, fallback to uncompressed (already set)
        }
        
        // Execute with retry logic
        auto result = executeWithRetry!bool(() @trusted {
            auto putResult = transport.put(contentHash, payload);
            if (putResult.isErr)
                return Err!(bool, BuildError)(putResult.unwrapErr());
            return Ok!(bool, BuildError)(true);
        });
        
        synchronized (statsMutex)
        {
            stats.putRequests++;
            
            if (result.isOk)
                stats.bytesUploaded += payload.length;
            else
                stats.errors++;
            
            updateLatency(startTime);
            stats.compute();
        }
        
        return result;
    }
    
    /// Check if artifact exists in remote cache
    BuildResult!bool has(string contentHash) @trusted
    {
        if (!config.enabled())
            return Err!(bool, BuildError)(
                Errors.cache("Remote cache not configured", ErrorCode.CacheDisabled).build());
        
        immutable startTime = Clock.currStdTime();
        
        // Execute with retry logic
        auto result = executeWithRetry(() => transport.head(contentHash));
        
        synchronized (statsMutex)
        {
            stats.headRequests++;
            
            if (result.isOk)
            {
                if (result.unwrap())
                    stats.hits++;
                else
                    stats.misses++;
            }
            else
            {
                stats.errors++;
            }
            
            updateLatency(startTime);
            stats.compute();
        }
        
        return result;
    }
    
    /// Get cache statistics
    RemoteCacheStats getStats() @trusted
    {
        synchronized (statsMutex)
        {
            return stats;
        }
    }
    
    /// Reset statistics
    void resetStats() @trusted
    {
        synchronized (statsMutex)
        {
            stats = RemoteCacheStats.init;
        }
    }
    
    private void updateLatency(long startTime) nothrow
    {
        try
        {
            immutable endTime = Clock.currStdTime();
            immutable latency = (endTime - startTime) / 10_000.0; // Convert to milliseconds
            
            // Exponential moving average
            immutable alpha = 0.2;
            if (stats.averageLatency == 0.0)
                stats.averageLatency = latency;
            else
                stats.averageLatency = alpha * latency + (1.0 - alpha) * stats.averageLatency;
        }
        catch (Exception) {}
    }
    
    private BuildResult!T executeWithRetry(T)(
        BuildResult!T delegate() @trusted operation
    ) @trusted
    {
        size_t attempts = 0;
        BuildResult!T lastResult;
        
        while (attempts < config.maxRetries)
        {
            lastResult = operation();
            
            if (lastResult.isOk)
                return lastResult;
            
            // Check if error is retryable
            auto error = lastResult.unwrapErr();
            if (!isRetryable(error))
                return lastResult;
            
            attempts++;
            
            // Exponential backoff with jitter
            if (attempts < config.maxRetries)
            {
                import std.random : uniform;
                import core.thread : Thread;
                import core.time : msecs;
                
                immutable baseDelay = 100 * (1 << attempts); // 100ms, 200ms, 400ms, ...
                immutable jitter = uniform(0, baseDelay / 4);
                immutable delay = baseDelay + jitter;
                
                Thread.sleep(delay.msecs);
            }
        }
        
        return lastResult;
    }
    
    private bool isRetryable(BuildError error) pure @trusted nothrow
    {
        try
        {
            // Network errors are retryable
            if (cast(NetworkError)error !is null)
                return true;
            
            // Some cache errors are retryable
            if (auto cacheErr = cast(CacheError)error)
            {
                return cacheErr.code == ErrorCode.NetworkError ||
                       cacheErr.code == ErrorCode.CacheTimeout;
            }
            
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    // ==================== Chunk-Based Transfer API ====================
    
    /// Upload a single chunk to remote cache
    /// Used by chunk transfer mechanism for large files
    BuildResult!bool putChunk(string chunkHash, const(ubyte)[] data) @trusted
    {
        // Use standard put with chunk hash as key
        return put(chunkHash, data);
    }
    
    /// Download a single chunk from remote cache
    BuildResult!(ubyte[]) getChunk(string chunkHash) @trusted
    {
        // Use standard get with chunk hash as key
        return get(chunkHash);
    }
    
    /// Check if a chunk exists in remote cache
    BuildResult!bool hasChunk(string chunkHash) @trusted
    {
        return has(chunkHash);
    }
    
    /// Upload file using chunk-based transfer (for large files)
    /// Returns: Transfer statistics and manifest
    BuildResult!ChunkBasedUpload putFileChunked(
        string filePath,
        string fileHash
    ) @trusted
    {
        immutable startTime = Clock.currStdTime();
        
        // Check if file exists
        if (!exists(filePath))
            return Err!(ChunkBasedUpload, BuildError)(
                Errors.io(filePath, "File not found: " ~ filePath, ErrorCode.FileNotFound).build());
        
        // Check file size threshold (only use chunking for files > 1MB)
        auto fileSize = getSize(filePath);
        if (fileSize < 1_048_576)  // 1 MB
        {
            // Use regular upload for small files
            auto data = cast(ubyte[])read(filePath);
            auto putResult = put(fileHash, data);
            
            if (putResult.isErr)
                return Err!(ChunkBasedUpload, BuildError)(putResult.unwrapErr());
            
            // Return result with no chunking
            ChunkBasedUpload result;
            result.stats.totalChunks = 1;
            result.stats.chunksTransferred = 1;
            result.stats.bytesTransferred = fileSize;
            result.useChunking = false;
            
            return Ok!(ChunkBasedUpload, BuildError)(result);
        }
        
        // Use chunk-based upload for large files
        bool delegate(string, const(ubyte)[]) @trusted uploadDelegate = 
            (string chunkHash, const(ubyte)[] chunkData) @trusted {
                auto result = putChunk(chunkHash, chunkData);
                return result.isOk && result.unwrap();
            };
        
        auto uploadResult = ChunkTransfer.uploadFileChunked(
            filePath,
            uploadDelegate
        );
        
        if (uploadResult.isErr)
            return Err!(ChunkBasedUpload, BuildError)(
                Errors.cache("Chunk upload failed: " ~ uploadResult.unwrapErr(), ErrorCode.CacheLoadFailed).build());
        
        auto manifest = uploadResult.unwrap();
        
        // Store manifest in cache with special key
        auto manifestResult = putManifest(fileHash, manifest);
        if (manifestResult.isErr)
            return Err!(ChunkBasedUpload, BuildError)(
                Errors.cache("Failed to upload manifest: " ~ manifestResult.unwrapErr().message, ErrorCode.CacheLoadFailed).build());
        
        synchronized (statsMutex)
        {
            updateLatency(startTime);
        }
        
        ChunkBasedUpload result;
        result.manifest = manifest;
        result.stats.totalChunks = manifest.chunks.length;
        result.stats.chunksTransferred = manifest.chunks.length;
        result.stats.bytesTransferred = manifest.totalSize;
        result.useChunking = true;
        
        return Ok!(ChunkBasedUpload, BuildError)(result);
    }
    
    /// Download file using chunk-based transfer
    BuildResult!TransferStats getFileChunked(
        string fileHash,
        string outputPath
    ) @trusted
    {
        immutable startTime = Clock.currStdTime();
        
        // First, try to get the manifest
        auto manifestResult = getManifest(fileHash);
        if (manifestResult.isErr)
        {
            // Fallback to regular download if no manifest exists
            auto dataResult = get(fileHash);
            if (dataResult.isErr)
                return Err!(TransferStats, BuildError)(dataResult.unwrapErr());
            
            auto data = dataResult.unwrap();
            write(outputPath, data);
            
            TransferStats stats;
            stats.totalChunks = 1;
            stats.chunksTransferred = 1;
            stats.bytesTransferred = data.length;
            
            return Ok!(TransferStats, BuildError)(stats);
        }
        
        auto manifest = manifestResult.unwrap();
        
        // Download using chunks
        Result!(ubyte[], string) delegate(string) @trusted downloadDelegate =
            (string chunkHash) @trusted {
                auto result = getChunk(chunkHash);
                if (result.isErr)
                    return Err!(ubyte[], string)(result.unwrapErr().message);
                return Ok!(ubyte[], string)(result.unwrap());
            };
        
        auto downloadResult = ChunkTransfer.downloadChunks(
            outputPath,
            manifest,
            downloadDelegate
        );
        
        if (downloadResult.isErr)
            return Err!(TransferStats, BuildError)(
                Errors.cache("Chunk download failed: " ~ downloadResult.unwrapErr(), ErrorCode.CacheLoadFailed).build());
        
        synchronized (statsMutex)
        {
            updateLatency(startTime);
        }
        
        return Ok!(TransferStats, BuildError)(downloadResult.unwrap());
    }
    
    /// Update file with only changed chunks (incremental upload)
    /// Returns: Transfer statistics showing bandwidth savings
    BuildResult!TransferStats updateFileChunked(
        string filePath,
        string fileHash,
        string oldFileHash
    ) @trusted
    {
        immutable startTime = Clock.currStdTime();
        
        // Get old manifest to compare
        auto oldManifestResult = getManifest(oldFileHash);
        if (oldManifestResult.isErr)
        {
            // If no old manifest, do full upload
            auto uploadResult = putFileChunked(filePath, fileHash);
            if (uploadResult.isErr)
                return Err!(TransferStats, BuildError)(uploadResult.unwrapErr());
            
            return Ok!(TransferStats, BuildError)(uploadResult.unwrap().stats);
        }
        
        auto oldManifest = oldManifestResult.unwrap();
        
        // Chunk the new file
        auto chunkResult = ContentChunker.chunkFile(filePath);
        if (chunkResult.chunks.length == 0)
            return Err!(TransferStats, BuildError)(
                Errors.cache("Failed to chunk file: " ~ filePath, ErrorCode.CacheLoadFailed).build());
        
        // Build new manifest
        ChunkManifest newManifest;
        newManifest.fileHash = chunkResult.combinedHash;
        newManifest.chunks = chunkResult.chunks;
        newManifest.totalSize = getSize(filePath);
        
        // Upload only changed chunks
        bool delegate(string, const(ubyte)[]) @trusted uploadDelegate = 
            (string chunkHash, const(ubyte)[] chunkData) @trusted {
                auto result = putChunk(chunkHash, chunkData);
                return result.isOk && result.unwrap();
            };
        
        auto uploadResult = ChunkTransfer.uploadChangedChunks(
            filePath,
            newManifest,
            oldManifest,
            uploadDelegate
        );
        
        if (uploadResult.isErr)
            return Err!(TransferStats, BuildError)(
                Errors.cache("Incremental chunk upload failed: " ~ uploadResult.unwrapErr(), ErrorCode.CacheLoadFailed).build());
        
        // Store new manifest
        auto manifestResult = putManifest(fileHash, newManifest);
        if (manifestResult.isErr)
            return Err!(TransferStats, BuildError)(
                Errors.cache("Failed to upload manifest: " ~ manifestResult.unwrapErr().message, ErrorCode.CacheLoadFailed).build());
        
        synchronized (statsMutex)
        {
            updateLatency(startTime);
        }
        
        return Ok!(TransferStats, BuildError)(uploadResult.unwrap());
    }
    
    /// Store chunk manifest in cache
    private VoidBuildResult putManifest(string fileHash, ChunkManifest manifest) @trusted
    {
        // Serialize manifest
        import std.json : JSONValue;
        
        JSONValue manifestJson;
        manifestJson["fileHash"] = manifest.fileHash;
        manifestJson["totalSize"] = manifest.totalSize;
        
        JSONValue[] chunksJson;
        foreach (chunk; manifest.chunks)
        {
            JSONValue chunkJson;
            chunkJson["offset"] = chunk.offset;
            chunkJson["length"] = chunk.length;
            chunkJson["hash"] = chunk.hash;
            chunksJson ~= chunkJson;
        }
        manifestJson["chunks"] = chunksJson;
        
        auto manifestData = cast(ubyte[])manifestJson.toString();
        
        // Store with special manifest key
        immutable manifestKey = fileHash ~ ".manifest";
        auto putResult = put(manifestKey, manifestData);
        
        if (putResult.isErr)
            return VoidBuildResult.err(putResult.unwrapErr());
        
        return Ok!BuildError();
    }
    
    /// Retrieve chunk manifest from cache
    private BuildResult!ChunkManifest getManifest(string fileHash) @trusted
    {
        import std.json : parseJSON, JSONException;
        
        // Retrieve with special manifest key
        immutable manifestKey = fileHash ~ ".manifest";
        auto getResult = get(manifestKey);
        
        if (getResult.isErr)
            return Err!(ChunkManifest, BuildError)(getResult.unwrapErr());
        
        auto manifestData = getResult.unwrap();
        
        try
        {
            auto manifestJson = parseJSON(cast(string)manifestData);
            
            ChunkManifest manifest;
            manifest.fileHash = manifestJson["fileHash"].str;
            manifest.totalSize = cast(size_t)manifestJson["totalSize"].integer;
            
            foreach (chunkJson; manifestJson["chunks"].array)
            {
                ContentChunker.Chunk chunk;
                chunk.offset = cast(size_t)chunkJson["offset"].integer;
                chunk.length = cast(size_t)chunkJson["length"].integer;
                chunk.hash = chunkJson["hash"].str;
                manifest.chunks ~= chunk;
            }
            
            return Ok!(ChunkManifest, BuildError)(manifest);
        }
        catch (JSONException e)
        {
            return Err!(ChunkManifest, BuildError)(
                Errors.cache("Failed to parse manifest: " ~ e.msg, ErrorCode.CacheCorrupted).build());
        }
    }
}

/// Result type for chunk-based upload
struct ChunkBasedUpload
{
    ChunkManifest manifest;
    TransferStats stats;
    bool useChunking;  // Whether chunking was actually used
}


