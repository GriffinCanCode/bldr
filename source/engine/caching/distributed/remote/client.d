module engine.caching.distributed.remote.client;

import std.datetime : Clock, Duration, dur;
import std.file : exists, read, write, remove, getSize;
import std.path : buildPath;
import std.algorithm : min, map;
import std.array : array;
import core.sync.mutex;
import engine.caching.distributed.remote.protocol;
import engine.caching.distributed.remote.transport;
import engine.caching.distributed.remote.delta : DeltaCompressor, DeltaPackage, RsyncDelta;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.security.integrity : IntegrityValidator;
import infrastructure.utils.compression.compress;
import infrastructure.utils.files.chunking : ChunkManifest, ChunkTransfer, TransferStats, ContentChunker;
import infrastructure.utils.files.cdc : FastCDC, CDCManifest = ChunkManifest, shouldChunk, LARGE_ARTIFACT_THRESHOLD;
import infrastructure.utils.crypto.merkle : MerkleProof;
import infrastructure.utils.simd.bloom : BloomFilter;
import infrastructure.errors;
import engine.caching.distributed.remote.dictionary : SharedDictionaryManager, SharedDictConfig, DictionaryPackage, DictionarySyncProtocol;

/// Remote cache client with connection pooling and retry logic
/// Provides high-level interface for artifact storage and retrieval
/// 
/// Optimizations:
/// - Bloom filter for fast negative lookups (avoid network for known misses)
/// - Connection pooling for reduced latency
/// - Retry logic with exponential backoff
/// - FastCDC chunking for large artifacts
final class RemoteCacheClient
{
    private RemoteCacheConfig config;
    private HttpTransport transport;
    private RemoteCacheStats stats;
    private Mutex statsMutex;
    private IntegrityValidator validator;
    private BloomFilter knownEntries;  // Fast negative lookup filter
    private shared size_t bloomFilterSaves;  // Network requests avoided
    
    // Shared dictionary compression for network transfers
    private SharedDictionaryManager _dictManager;
    private bool _useDictCompression;
    
    /// Constructor
    this(RemoteCacheConfig config) @trusted
    {
        this.config = config;
        this.transport = new HttpTransport(config);
        this.statsMutex = new Mutex();
        
        // Initialize integrity validator for workspace isolation
        import std.file : getcwd;
        this.validator = IntegrityValidator.fromEnvironment(getcwd());
        
        // Initialize bloom filter for fast negative lookups
        // Sized for 100K entries with 0.1% FPR - avoids network for known misses
        this.knownEntries = BloomFilter.create(100_000, 0.001);
    }
    
    /// Initialize shared dictionary compression for improved network transfer efficiency
    /// Dictionary-based compression typically provides 30-50% better ratios for similar artifacts
    void initDictionaryCompression(string cacheDir, SharedDictConfig dictConfig = SharedDictConfig.init) @trusted
    {
        _dictManager = new SharedDictionaryManager(cacheDir, dictConfig);
        _useDictCompression = true;
    }
    
    /// Get the dictionary manager for external coordination
    SharedDictionaryManager getDictionaryManager() @trusted => _dictManager;
    
    /// Check if dictionary compression is enabled
    bool isDictionaryCompressionEnabled() const @safe => _useDictCompression;
    
    /// Sync dictionary from coordinator (for worker nodes)
    VoidBuildResult syncDictionary() @trusted
    {
        if (!_useDictCompression || _dictManager is null)
            return VoidBuildResult.err(Errors.generic("Dictionary compression not enabled").build());
        
        // Request latest dictionary from server
        auto requestMsg = DictionarySyncProtocol.createRequest(_dictManager.getDictionaryId());
        auto dictKey = "__dict_sync__";
        
        auto result = executeWithRetry(() => transport.get(dictKey));
        if (result.isErr)
            return VoidBuildResult.err(result.unwrapErr());
        
        auto responseData = result.unwrap();
        if (responseData.length < 13)
            return VoidBuildResult.ok();  // No dictionary available
        
        auto header = DictionarySyncProtocol.Header.deserialize(responseData);
        
        // Already have latest
        if (header.dictionaryId == _dictManager.getDictionaryId())
            return VoidBuildResult.ok();
        
        // Import new dictionary
        if (header.type == DictionarySyncProtocol.MessageType.DictionaryResponse ||
            header.type == DictionarySyncProtocol.MessageType.DictionaryUpdate)
        {
            auto pkg = DictionaryPackage.deserialize(responseData[13 .. $]);
            return _dictManager.importDictionary(pkg.data, pkg.meta);
        }
        
        return VoidBuildResult.ok();
    }
    
    /// Broadcast dictionary update to server (for coordinator)
    VoidBuildResult broadcastDictionary() @trusted
    {
        if (!_useDictCompression || _dictManager is null)
            return VoidBuildResult.err(Errors.generic("Dictionary compression not enabled").build());
        
        auto pkg = _dictManager.getCurrentDictionary();
        if (pkg.data.length == 0)
            return VoidBuildResult.err(Errors.generic("No dictionary to broadcast").build());
        
        auto msg = DictionarySyncProtocol.createUpdate(pkg);
        auto dictKey = "__dict_sync__";
        
        auto result = executeWithRetry!bool(() @trusted {
            auto putResult = transport.put(dictKey, msg);
            if (putResult.isErr)
                return Err!(bool, BuildError)(putResult.unwrapErr());
            return Ok!(bool, BuildError)(true);
        });
        
        return result.isOk ? VoidBuildResult.ok() : VoidBuildResult.err(result.unwrapErr());
    }
    
    /// Destructor
    ~this() @trusted
    {
        // Transport cleanup handled by its destructor
    }
    
    /// Fetch artifact from remote cache
    /// Automatically handles FastCDC chunked artifacts
    /// Returns: artifact data or error
    BuildResult!(ubyte[]) get(string contentHash) @trusted
    {
        if (!config.enabled())
            return Err!(ubyte[], BuildError)(
                Errors.cache("Remote cache not configured", Cache.Disabled).build());
        
        immutable startTime = Clock.currStdTime();
        
        // First check if this is a CDC-chunked artifact
        immutable cdcKey = "cdc:" ~ contentHash;
        auto cdcResult = executeWithRetry(() => transport.get(cdcKey));
        
        if (cdcResult.isOk)
            return getWithFastCDC(contentHash, cdcResult.unwrap(), startTime);
        
        // Standard fetch
        auto result = executeWithRetry(() => transport.get(contentHash));
        
        synchronized (statsMutex)
        {
            stats.getRequests++;
            
            if (result.isOk)
            {
                stats.hits++;
                auto data = result.unwrap();
                stats.bytesDownloaded += data.length;
                
                // Add to bloom filter for future fast lookups
                if (knownEntries.valid) knownEntries.insert(contentHash);
                
                // Decompress if needed (check first byte for compression marker)
                if (data.length > 0 && data[0] == 0xFD)  // Zstd magic number
                {
                    // Try dictionary decompression first
                    if (_useDictCompression && _dictManager !is null)
                    {
                        auto dictResult = _dictManager.decompress(data);
                        if (dictResult.isOk)
                            return Ok!(ubyte[], BuildError)(dictResult.unwrap());
                    }
                    
                    // Fallback to standard decompression
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
                    if (cacheErr.code != cast(ErrorCode) Cache.NotFound)
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
    
    /// Retrieve large artifact from FastCDC chunks
    private BuildResult!(ubyte[]) getWithFastCDC(string contentHash, ubyte[] manifestData, long startTime) @trusted
    {
        import infrastructure.utils.crypto.blake3 : toHexString;
        
        // Parse manifest
        auto parseResult = CDCManifest.deserialize(manifestData);
        if (parseResult.isErr)
            return Err!(ubyte[], BuildError)(
                Errors.cache("Invalid CDC manifest: " ~ parseResult.unwrapErr(), Cache.Corrupted).build());
        
        auto manifest = parseResult.unwrap();
        
        // Allocate output buffer
        auto output = new ubyte[manifest.totalSize];
        size_t bytesDownloaded = 0;
        
        // Download and reassemble chunks
        foreach (ref r; manifest.refs)
        {
            immutable chunkHash = toHexString(r.hash[]);
            
            auto chunkResult = executeWithRetry(() => transport.get(chunkHash));
            if (chunkResult.isErr)
                return Err!(ubyte[], BuildError)(chunkResult.unwrapErr());
            
            auto chunkData = chunkResult.unwrap();
            if (chunkData.length != r.length)
                return Err!(ubyte[], BuildError)(
                    Errors.cache("Chunk size mismatch", Cache.Corrupted).build());
            
            // Copy to output buffer
            output[r.offset .. r.offset + r.length] = chunkData[];
            bytesDownloaded += chunkData.length;
        }
        
        // Verify reassembled hash
        immutable actualHash = FastHash.hashBytes(output);
        if (actualHash != contentHash)
            return Err!(ubyte[], BuildError)(
                Errors.cache("Reassembled artifact hash mismatch", Cache.Corrupted).build());
        
        synchronized (statsMutex)
        {
            stats.getRequests++;
            stats.hits++;
            stats.bytesDownloaded += bytesDownloaded;
            stats.cdcChunksDownloaded += manifest.chunkCount;
            updateLatency(startTime);
            stats.compute();
        }
        
        return Ok!(ubyte[], BuildError)(output);
    }
    
    /// Store artifact in remote cache
    BuildResult!bool put(string contentHash, const(ubyte)[] data) @trusted
    {
        if (!config.enabled())
            return Err!(bool, BuildError)(
                Errors.cache("Remote cache not configured", Cache.Disabled).build());
        
        // Check size limit
        if (data.length > config.maxArtifactSize)
            return Err!(bool, BuildError)(
                Errors.cache("Artifact exceeds maximum size", Cache.TooLarge).build());
        
        immutable startTime = Clock.currStdTime();
        
        // Compress if enabled and beneficial
        ubyte[] payload = cast(ubyte[])data;
        if (config.enableCompression && data.length > 1024)
        {
            // Prefer dictionary compression if available (30-50% better ratio)
            if (_useDictCompression && _dictManager !is null && _dictManager.hasDictionary())
            {
                auto dictResult = _dictManager.compress(data, 3);
                if (dictResult.isOk)
                {
                    auto compressed = dictResult.unwrap();
                    if (compressed.length < data.length * 9 / 10)  // >10% reduction
                    {
                        payload = compressed;
                        
                        // Add sample for dictionary training improvement
                        _dictManager.addSample(data);
                    }
                }
            }
            
            // Fallback to standard compression
            if (payload.length == data.length)
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
            {
                stats.bytesUploaded += payload.length;
                // Add to bloom filter for future fast lookups
                if (knownEntries.valid) knownEntries.insert(contentHash);
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
    
    /// Check if artifact exists in remote cache
    /// Uses bloom filter for fast negative lookups - avoids network for known misses
    BuildResult!bool has(string contentHash) @trusted
    {
        import core.atomic : atomicOp;
        
        if (!config.enabled())
            return Err!(bool, BuildError)(
                Errors.cache("Remote cache not configured", Cache.Disabled).build());
        
        // Fast path: bloom filter says definitely not in cache
        // Bloom filters have no false negatives, so if it says "not present", it's certain
        if (knownEntries.valid && !knownEntries.mayContain(contentHash))
        {
            synchronized (statsMutex)
            {
                stats.headRequests++;
                stats.misses++;
            }
            atomicOp!"+="(bloomFilterSaves, 1);
            return Ok!(bool, BuildError)(false);
        }
        
        immutable startTime = Clock.currStdTime();
        
        // Execute with retry logic
        auto result = executeWithRetry(() => transport.head(contentHash));
        
        synchronized (statsMutex)
        {
            stats.headRequests++;
            
            if (result.isOk)
            {
                if (result.unwrap())
                {
                    stats.hits++;
                    // Add to bloom filter for future fast lookups
                    if (knownEntries.valid) knownEntries.insert(contentHash);
                }
                else
                {
                    stats.misses++;
                }
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
    
    /// Get bloom filter statistics
    /// Returns: (network requests saved, estimated entries, memory bytes)
    auto getBloomFilterStats() @system
    {
        import core.atomic : atomicLoad;
        struct BloomStats { size_t networkSaved; size_t estimatedEntries; size_t memoryBytes; }
        return BloomStats(
            atomicLoad(bloomFilterSaves),
            knownEntries.valid ? knownEntries.itemCount : 0,
            knownEntries.valid ? knownEntries.memoryBytes : 0
        );
    }
    
    /// Reset statistics
    void resetStats() @trusted
    {
        import core.atomic : atomicStore;
        synchronized (statsMutex)
        {
            stats = RemoteCacheStats.init;
        }
        atomicStore(bloomFilterSaves, cast(size_t)0);
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
    
    private Result!(T, BuildError) executeWithRetry(T)(
        Result!(T, BuildError) delegate() operation
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
                return cacheErr.code == cast(ErrorCode) Network.Error ||
                       cacheErr.code == cast(ErrorCode) Cache.Timeout;
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
                Errors.io(filePath, "File not found: " ~ filePath, IO.FileNotFound).build());
        
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
                Errors.cache("Chunk upload failed: " ~ uploadResult.unwrapErr(), Cache.LoadFailed).build());
        
        auto manifest = uploadResult.unwrap();
        
        // Store manifest in cache with special key
        auto manifestResult = putManifest(fileHash, manifest);
        if (manifestResult.isErr)
            return Err!(ChunkBasedUpload, BuildError)(
                Errors.cache("Failed to upload manifest: " ~ manifestResult.unwrapErr().message, Cache.LoadFailed).build());
        
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
                Errors.cache("Chunk download failed: " ~ downloadResult.unwrapErr(), Cache.LoadFailed).build());
        
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
                Errors.cache("Failed to chunk file: " ~ filePath, Cache.LoadFailed).build());
        
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
                Errors.cache("Incremental chunk upload failed: " ~ uploadResult.unwrapErr(), Cache.LoadFailed).build());
        
        // Store new manifest
        auto manifestResult = putManifest(fileHash, newManifest);
        if (manifestResult.isErr)
            return Err!(TransferStats, BuildError)(
                Errors.cache("Failed to upload manifest: " ~ manifestResult.unwrapErr().message, Cache.LoadFailed).build());
        
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
                Errors.cache("Failed to parse manifest: " ~ e.msg, Cache.Corrupted).build());
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

/// Delta transfer result
struct DeltaUploadResult
{
    size_t originalSize;
    size_t deltaSize;
    size_t bytesSaved;
    bool usedDelta;
    
    double savingsPercent() const pure @safe nothrow @nogc
        => originalSize > 0 ? 100.0 * bytesSaved / originalSize : 0.0;
}

/// Remote cache client with delta compression support
/// Mixin for delta transfer operations
mixin template DeltaTransferOps()
{
    private DeltaCompressor _deltaCompressor;
    
    /// Initialize delta compressor (call after construction if using delta)
    void initDeltaCompression(string cacheDir) @trusted
    {
        _deltaCompressor = new DeltaCompressor(cacheDir);
    }
    
    /// Upload artifact using delta compression against a base version
    /// Returns delta statistics showing bandwidth savings
    BuildResult!DeltaUploadResult putWithDelta(
        string contentHash,
        const(ubyte)[] data,
        string baseHash
    ) @trusted
    {
        if (_deltaCompressor is null)
            return Err!(DeltaUploadResult, BuildError)(
                Errors.cache("Delta compressor not initialized", Cache.Disabled).build());
        
        // Get base data for delta computation
        auto baseResult = get(baseHash);
        if (baseResult.isErr)
        {
            // No base available, do full upload
            auto putResult = put(contentHash, data);
            if (putResult.isErr)
                return Err!(DeltaUploadResult, BuildError)(putResult.unwrapErr());
            
            DeltaUploadResult result;
            result.originalSize = data.length;
            result.deltaSize = data.length;
            result.bytesSaved = 0;
            result.usedDelta = false;
            return Ok!(DeltaUploadResult, BuildError)(result);
        }
        
        auto baseData = baseResult.unwrap();
        
        // Compute delta
        auto deltaResult = _deltaCompressor.createDelta(baseData, data);
        if (deltaResult.isErr)
        {
            // Delta failed, do full upload
            auto putResult = put(contentHash, data);
            if (putResult.isErr)
                return Err!(DeltaUploadResult, BuildError)(putResult.unwrapErr());
            
            DeltaUploadResult result;
            result.originalSize = data.length;
            result.deltaSize = data.length;
            result.bytesSaved = 0;
            result.usedDelta = false;
            return Ok!(DeltaUploadResult, BuildError)(result);
        }
        
        auto deltaPkg = deltaResult.unwrap();
        
        // Only use delta if it saves space
        if (deltaPkg.deltaSize >= data.length)
        {
            auto putResult = put(contentHash, data);
            if (putResult.isErr)
                return Err!(DeltaUploadResult, BuildError)(putResult.unwrapErr());
            
            DeltaUploadResult result;
            result.originalSize = data.length;
            result.deltaSize = data.length;
            result.bytesSaved = 0;
            result.usedDelta = false;
            return Ok!(DeltaUploadResult, BuildError)(result);
        }
        
        // Upload delta package
        immutable deltaKey = "delta:" ~ contentHash ~ ":" ~ baseHash;
        auto putResult = put(deltaKey, deltaPkg.data);
        if (putResult.isErr)
            return Err!(DeltaUploadResult, BuildError)(putResult.unwrapErr());
        
        // Store metadata for reconstruction
        ubyte[] metadata;
        metadata ~= cast(ubyte)(deltaPkg.compressed ? 1 : 0);
        metadata ~= (cast(ubyte*)&deltaPkg.originalNewSize)[0 .. size_t.sizeof];
        
        auto metaKey = "delta-meta:" ~ contentHash;
        auto metaResult = put(metaKey, metadata);
        if (metaResult.isErr)
            return Err!(DeltaUploadResult, BuildError)(metaResult.unwrapErr());
        
        DeltaUploadResult result;
        result.originalSize = data.length;
        result.deltaSize = deltaPkg.deltaSize;
        result.bytesSaved = data.length - deltaPkg.deltaSize;
        result.usedDelta = true;
        
        synchronized (statsMutex)
        {
            stats.deltaUploads++;
            stats.deltaByteSavings += result.bytesSaved;
        }
        
        return Ok!(DeltaUploadResult, BuildError)(result);
    }
    
    /// Get artifact, reconstructing from delta if necessary
    BuildResult!(ubyte[]) getWithDelta(string contentHash, string baseHash) @trusted
    {
        if (_deltaCompressor is null)
            return get(contentHash);
        
        // Try delta reconstruction first
        immutable deltaKey = "delta:" ~ contentHash ~ ":" ~ baseHash;
        auto deltaResult = get(deltaKey);
        
        if (deltaResult.isErr)
            return get(contentHash);  // No delta, get full blob
        
        // Get base for reconstruction
        auto baseResult = get(baseHash);
        if (baseResult.isErr)
            return get(contentHash);  // Can't get base, try full blob
        
        // Reconstruct from delta
        DeltaPackage pkg;
        pkg.data = deltaResult.unwrap();
        
        // Get metadata
        auto metaKey = "delta-meta:" ~ contentHash;
        auto metaResult = get(metaKey);
        if (metaResult.isOk)
        {
            auto meta = metaResult.unwrap();
            if (meta.length > 0)
            {
                pkg.compressed = meta[0] != 0;
                if (meta.length >= 1 + size_t.sizeof)
                    pkg.originalNewSize = *(cast(size_t*)(meta.ptr + 1));
            }
        }
        
        auto reconstructResult = _deltaCompressor.applyDelta(baseResult.unwrap(), pkg);
        if (reconstructResult.isErr)
            return get(contentHash);  // Reconstruction failed, try full blob
        
        return reconstructResult;
    }
    
    /// Get Merkle proof for a specific chunk of an artifact
    /// Enables partial artifact validation without full download
    BuildResult!MerkleProof getChunkProof(string artifactHash, uint chunkIndex) @trusted
    {
        import infrastructure.utils.files.cdc : ChunkManifest;
        
        // Get manifest
        auto manifestKey = "cdc:" ~ artifactHash;
        auto manifestResult = executeWithRetry(() => transport.get(manifestKey));
        
        if (manifestResult.isErr)
            return Err!(MerkleProof, BuildError)(Errors.cache(
                "Manifest not found for artifact: " ~ artifactHash, Cache.NotFound).build());
        
        auto parseResult = ChunkManifest.deserialize(manifestResult.unwrap());
        if (parseResult.isErr)
            return Err!(MerkleProof, BuildError)(Errors.cache(
                "Failed to parse manifest", Cache.LoadFailed).build());
        
        auto manifest = parseResult.unwrap();
        
        if (chunkIndex >= manifest.chunkCount)
            return Err!(MerkleProof, BuildError)(Errors.cache(
                "Chunk index out of range", Cache.NotFound).build());
        
        // Generate proof from manifest
        auto proof = manifest.generateProof(chunkIndex);
        return Ok!(MerkleProof, BuildError)(proof);
    }
    
    /// Compare two artifact versions using Merkle tree diff
    /// Returns indices of changed chunks for incremental updates
    BuildResult!(uint[]) compareArtifacts(string localHash, string remoteHash) @trusted
    {
        import infrastructure.utils.files.cdc : ChunkManifest;
        
        // Get remote manifest
        auto remoteKey = "cdc:" ~ remoteHash;
        auto remoteResult = executeWithRetry(() => transport.get(remoteKey));
        
        if (remoteResult.isErr)
            return Err!(uint[], BuildError)(Errors.cache(
                "Remote manifest not found: " ~ remoteHash, Cache.NotFound).build());
        
        auto remoteParseResult = ChunkManifest.deserialize(remoteResult.unwrap());
        if (remoteParseResult.isErr)
            return Err!(uint[], BuildError)(Errors.cache(
                "Failed to parse remote manifest", Cache.LoadFailed).build());
        
        auto remoteManifest = remoteParseResult.unwrap();
        
        // Get local manifest
        auto localKey = "cdc:" ~ localHash;
        auto localResult = executeWithRetry(() => transport.get(localKey));
        
        if (localResult.isErr)
        {
            // No local manifest - return all chunks as changed
            uint[] allIndices;
            foreach (i; 0 .. remoteManifest.chunkCount)
                allIndices ~= cast(uint)i;
            return Ok!(uint[], BuildError)(allIndices);
        }
        
        auto localParseResult = ChunkManifest.deserialize(localResult.unwrap());
        if (localParseResult.isErr)
        {
            // Can't parse local - return all chunks as changed
            uint[] allIndices;
            foreach (i; 0 .. remoteManifest.chunkCount)
                allIndices ~= cast(uint)i;
            return Ok!(uint[], BuildError)(allIndices);
        }
        
        auto localManifest = localParseResult.unwrap();
        
        // Use Merkle tree diff for O(log n) comparison
        auto changedIndices = remoteManifest.findChanged(localManifest);
        return Ok!(uint[], BuildError)(changedIndices);
    }
}


