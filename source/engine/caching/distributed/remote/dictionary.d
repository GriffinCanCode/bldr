module engine.caching.distributed.remote.dictionary;

import std.algorithm : map, filter, sort, sum, min, max;
import std.array : array, appender;
import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.datetime : Duration, MonoTime, SysTime, Clock, seconds, minutes, hours;
import std.file : exists, read, write, mkdirRecurse, getSize, dirEntries, SpanMode;
import std.path : buildPath, dirName, baseName;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.utils.compression.zstd;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;
import infrastructure.errors;

/// Dictionary metadata for version tracking
struct DictionaryMeta
{
    uint id;                    // Dictionary ID from zstd
    ubyte[32] contentHash;      // BLAKE3 hash of dictionary content
    size_t size;                // Dictionary size in bytes
    SysTime createdAt;          // When dictionary was trained
    size_t samplesUsed;         // Number of samples used in training
    size_t totalSampleBytes;    // Total bytes from samples
    float avgCompressionRatio;  // Average compression ratio achieved
    
    /// Serialize metadata
    ubyte[] serialize() const @trusted
    {
        auto buf = appender!(ubyte[])();
        buf ~= nativeToBigEndian(id)[];
        buf ~= contentHash[];
        buf ~= nativeToBigEndian(cast(ulong)size)[];
        buf ~= nativeToBigEndian(cast(ulong)samplesUsed)[];
        buf ~= nativeToBigEndian(cast(ulong)totalSampleBytes)[];
        buf ~= nativeToBigEndian(*cast(uint*)&avgCompressionRatio)[];
        return buf[];
    }
    
    /// Deserialize metadata
    static DictionaryMeta deserialize(const(ubyte)[] data) @trusted
    {
        DictionaryMeta meta;
        if (data.length < 56) return meta;
        
        size_t pos = 0;
        meta.id = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        meta.contentHash = data[pos .. pos + 32][0 .. 32]; pos += 32;
        meta.size = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
        meta.samplesUsed = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
        meta.totalSampleBytes = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
        
        if (data.length >= pos + 4)
        {
            uint ratioBytes = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]);
            meta.avgCompressionRatio = *cast(float*)&ratioBytes;
        }
        
        return meta;
    }
}

/// Shared dictionary manager for distributed workers
/// Coordinates dictionary training, distribution, and versioning
final class SharedDictionaryManager
{
    private string _storageDir;
    private Mutex _mutex;
    private SharedDictConfig _config;
    
    // Current dictionary state
    private ubyte[] _currentDict;
    private DictionaryMeta _currentMeta;
    private ZSTD_CDict* _compiledCDict;
    private ZSTD_DDict* _compiledDDict;
    
    // Sample collection for training
    private ubyte[][] _trainingSamples;
    private size_t _totalSampleBytes;
    
    // Statistics
    private DictionaryStats _stats;
    
    this(string storageDir, SharedDictConfig config = SharedDictConfig.init) @trusted
    {
        _storageDir = storageDir;
        _config = config;
        _mutex = new Mutex();
        
        if (!exists(storageDir))
            mkdirRecurse(storageDir);
        
        loadLatestDictionary();
    }
    
    ~this() @trusted
    {
        if (_compiledCDict) ZSTD_freeCDict(_compiledCDict);
        if (_compiledDDict) ZSTD_freeDDict(_compiledDDict);
    }
    
    /// Add sample data for dictionary training
    void addSample(const(ubyte)[] data) @trusted
    {
        if (data.length < _config.minSampleSize || data.length > _config.maxSampleSize)
            return;
        
        synchronized (_mutex)
        {
            // Limit sample count and total size
            if (_trainingSamples.length >= _config.maxSamples)
            {
                // Evict oldest sample
                _totalSampleBytes -= _trainingSamples[0].length;
                _trainingSamples = _trainingSamples[1 .. $];
            }
            
            if (_totalSampleBytes + data.length > _config.maxTotalSampleBytes)
                return;
            
            _trainingSamples ~= data.dup;
            _totalSampleBytes += data.length;
            _stats.samplesCollected++;
        }
    }
    
    /// Train new dictionary from collected samples
    /// Returns true if training succeeded and dictionary was updated
    VoidBuildResult train() @trusted
    {
        synchronized (_mutex)
        {
            if (_trainingSamples.length < _config.minSamplesForTraining)
                return VoidBuildResult.err(Errors.generic(
                    "Not enough samples for dictionary training: " ~ 
                    _trainingSamples.length.to!string ~ " < " ~ 
                    _config.minSamplesForTraining.to!string).build());
            
            auto startTime = MonoTime.currTime;
            
            // Concatenate samples
            size_t totalSize = _trainingSamples.map!(s => s.length).sum;
            auto samplesBuffer = new ubyte[](totalSize);
            auto samplesSizes = new size_t[](_trainingSamples.length);
            
            size_t offset = 0;
            foreach (i, sample; _trainingSamples)
            {
                samplesBuffer[offset .. offset + sample.length] = sample[];
                samplesSizes[i] = sample.length;
                offset += sample.length;
            }
            
            // Train dictionary
            auto dictBuffer = new ubyte[](_config.dictSize);
            auto trainedSize = ZDICT_trainFromBuffer(
                dictBuffer.ptr, dictBuffer.length,
                samplesBuffer.ptr, samplesSizes.ptr,
                cast(uint)_trainingSamples.length
            );
            
            if (ZDICT_isError(trainedSize))
                return VoidBuildResult.err(Errors.cache(
                    "Dictionary training failed: " ~ 
                    cast(string)ZDICT_getErrorName(trainedSize)[0..strLen(ZDICT_getErrorName(trainedSize))],
                    Cache.CompressionFailed).build());
            
            // Update current dictionary
            _currentDict = dictBuffer[0 .. trainedSize].dup;
            
            // Compute metadata
            auto hasher = Blake3(0);
            hasher.put(_currentDict);
            _currentMeta.contentHash = hasher.finish(32)[0 .. 32];
            _currentMeta.id = ZSTD_getDictID_fromDict(_currentDict.ptr, _currentDict.length);
            _currentMeta.size = _currentDict.length;
            _currentMeta.createdAt = Clock.currTime();
            _currentMeta.samplesUsed = _trainingSamples.length;
            _currentMeta.totalSampleBytes = totalSize;
            
            // Compile dictionary for fast compression
            compileDictionary();
            
            // Measure compression ratio on samples
            measureCompressionRatio();
            
            // Persist
            saveDictionary();
            
            // Update stats
            _stats.dictionariesTrained++;
            _stats.lastTrainingTime = MonoTime.currTime - startTime;
            
            // Clear samples after successful training
            _trainingSamples = [];
            _totalSampleBytes = 0;
            
            return VoidBuildResult.ok();
        }
    }
    
    /// Compress data using shared dictionary
    BuildResult!(ubyte[]) compress(const(ubyte)[] data, int level = 3) @trusted
    {
        if (data.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot compress empty data").build());
        
        synchronized (_mutex)
        {
            auto dstCapacity = ZSTD_compressBound(data.length);
            auto output = new ubyte[](dstCapacity);
            
            auto cctx = ZSTD_createCCtx();
            scope(exit) if (cctx) ZSTD_freeCCtx(cctx);
            
            size_t written;
            if (_compiledCDict !is null)
            {
                written = ZSTD_compress_usingCDict(cctx, 
                    output.ptr, output.length, 
                    data.ptr, data.length, _compiledCDict);
                _stats.compressionsWithDict++;
            }
            else
            {
                written = ZSTD_compressCCtx(cctx, 
                    output.ptr, output.length, 
                    data.ptr, data.length, level);
                _stats.compressionsWithoutDict++;
            }
            
            if (ZSTD_isError(written))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Compression failed", Cache.CompressionFailed).build());
            
            _stats.bytesCompressed += data.length;
            _stats.bytesAfterCompression += written;
            
            return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
        }
    }
    
    /// Decompress data using shared dictionary
    BuildResult!(ubyte[]) decompress(const(ubyte)[] data) @trusted
    {
        if (data.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot decompress empty data").build());
        
        synchronized (_mutex)
        {
            // Check if frame requires dictionary
            auto dictId = ZSTD_getDictID_fromFrame(data.ptr, data.length);
            
            auto dctx = ZSTD_createDCtx();
            scope(exit) if (dctx) ZSTD_freeDCtx(dctx);
            
            // Get decompressed size
            auto frameSize = ZSTD_getFrameContentSize(data.ptr, data.length);
            size_t dstCapacity = (frameSize != ZSTD_CONTENTSIZE_UNKNOWN && frameSize != ZSTD_CONTENTSIZE_ERROR)
                ? cast(size_t)frameSize
                : data.length * 4;
            
            auto output = new ubyte[](dstCapacity);
            
            size_t written;
            if (dictId != 0 && _compiledDDict !is null && dictId == _currentMeta.id)
            {
                written = ZSTD_decompress_usingDDict(dctx, 
                    output.ptr, output.length, 
                    data.ptr, data.length, _compiledDDict);
            }
            else if (dictId != 0 && dictId != _currentMeta.id)
            {
                // Dictionary mismatch - try to load correct version
                auto loadResult = loadDictionaryById(dictId);
                if (loadResult.isOk)
                {
                    auto dict = loadResult.unwrap();
                    auto ddict = ZSTD_createDDict(dict.ptr, dict.length);
                    scope(exit) if (ddict) ZSTD_freeDDict(ddict);
                    
                    written = ZSTD_decompress_usingDDict(dctx, 
                        output.ptr, output.length, 
                        data.ptr, data.length, ddict);
                }
                else
                {
                    return Err!(ubyte[], BuildError)(Errors.cache(
                        "Dictionary mismatch: required ID " ~ dictId.to!string,
                        Cache.CompressionFailed).build());
                }
            }
            else
            {
                written = ZSTD_decompressDCtx(dctx, 
                    output.ptr, output.length, 
                    data.ptr, data.length);
            }
            
            if (ZSTD_isError(written))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Decompression failed", Cache.CompressionFailed).build());
            
            return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
        }
    }
    
    /// Get current dictionary for distribution to workers
    /// Returns dictionary data and metadata
    DictionaryPackage getCurrentDictionary() @trusted
    {
        synchronized (_mutex)
        {
            DictionaryPackage pkg;
            pkg.data = _currentDict.dup;
            pkg.meta = _currentMeta;
            return pkg;
        }
    }
    
    /// Import dictionary from remote source (for workers)
    VoidBuildResult importDictionary(const(ubyte)[] data, DictionaryMeta meta) @trusted
    {
        synchronized (_mutex)
        {
            // Verify hash
            auto hasher = Blake3(0);
            hasher.put(data);
            auto hash = hasher.finish(32)[0 .. 32];
            
            if (hash != meta.contentHash)
                return VoidBuildResult.err(Errors.cache(
                    "Dictionary hash mismatch", Cache.Corrupted).build());
            
            // Verify dictionary ID
            auto id = ZSTD_getDictID_fromDict(data.ptr, data.length);
            if (id != meta.id)
                return VoidBuildResult.err(Errors.cache(
                    "Dictionary ID mismatch", Cache.Corrupted).build());
            
            _currentDict = data.dup;
            _currentMeta = meta;
            compileDictionary();
            saveDictionary();
            
            _stats.dictionariesReceived++;
            
            return VoidBuildResult.ok();
        }
    }
    
    /// Check if we have a valid dictionary
    bool hasDictionary() const @trusted
    {
        return _currentDict.length > 0;
    }
    
    /// Get current dictionary ID
    uint getDictionaryId() const @trusted
    {
        return _currentMeta.id;
    }
    
    /// Get dictionary metadata
    DictionaryMeta getMetadata() @trusted
    {
        synchronized (_mutex) { return _currentMeta; }
    }
    
    /// Get statistics
    DictionaryStats getStats() @trusted
    {
        synchronized (_mutex) { return _stats; }
    }
    
    /// Check if dictionary needs retraining
    bool needsRetraining() @trusted
    {
        synchronized (_mutex)
        {
            // No dictionary yet
            if (_currentDict.length == 0)
                return _trainingSamples.length >= _config.minSamplesForTraining;
            
            // Dictionary is old
            auto age = Clock.currTime() - _currentMeta.createdAt;
            if (age > _config.maxDictionaryAge)
                return _trainingSamples.length >= _config.minSamplesForTraining;
            
            // Compression ratio has degraded
            if (_currentMeta.avgCompressionRatio > 0 && _stats.bytesCompressed > 0)
            {
                auto currentRatio = cast(float)_stats.bytesAfterCompression / _stats.bytesCompressed;
                if (currentRatio > _currentMeta.avgCompressionRatio * 1.2f)  // 20% worse
                    return _trainingSamples.length >= _config.minSamplesForTraining;
            }
            
            return false;
        }
    }
    
private:
    /// Compile dictionary for fast compression/decompression
    void compileDictionary() @trusted
    {
        if (_compiledCDict) ZSTD_freeCDict(_compiledCDict);
        if (_compiledDDict) ZSTD_freeDDict(_compiledDDict);
        
        if (_currentDict.length > 0)
        {
            _compiledCDict = ZSTD_createCDict(_currentDict.ptr, _currentDict.length, 3);
            _compiledDDict = ZSTD_createDDict(_currentDict.ptr, _currentDict.length);
        }
        else
        {
            _compiledCDict = null;
            _compiledDDict = null;
        }
    }
    
    /// Measure compression ratio on samples
    void measureCompressionRatio() @trusted
    {
        if (_trainingSamples.length == 0 || _compiledCDict is null)
            return;
        
        size_t totalOriginal = 0;
        size_t totalCompressed = 0;
        
        auto cctx = ZSTD_createCCtx();
        scope(exit) if (cctx) ZSTD_freeCCtx(cctx);
        
        foreach (sample; _trainingSamples[0 .. min(100, $)])
        {
            auto dstCapacity = ZSTD_compressBound(sample.length);
            auto output = new ubyte[](dstCapacity);
            
            auto written = ZSTD_compress_usingCDict(cctx, 
                output.ptr, output.length, 
                sample.ptr, sample.length, _compiledCDict);
            
            if (!ZSTD_isError(written))
            {
                totalOriginal += sample.length;
                totalCompressed += written;
            }
        }
        
        if (totalOriginal > 0)
            _currentMeta.avgCompressionRatio = cast(float)totalCompressed / totalOriginal;
    }
    
    /// Save dictionary to disk
    void saveDictionary() @trusted
    {
        if (_currentDict.length == 0)
            return;
        
        auto dictPath = buildPath(_storageDir, "dict_" ~ _currentMeta.id.to!string ~ ".zdict");
        auto metaPath = buildPath(_storageDir, "dict_" ~ _currentMeta.id.to!string ~ ".meta");
        auto latestPath = buildPath(_storageDir, "latest.id");
        
        write(dictPath, _currentDict);
        write(metaPath, _currentMeta.serialize());
        write(latestPath, _currentMeta.id.to!string);
    }
    
    /// Load latest dictionary from disk
    void loadLatestDictionary() @trusted
    {
        auto latestPath = buildPath(_storageDir, "latest.id");
        
        if (!exists(latestPath))
            return;
        
        try
        {
            auto idStr = cast(string)read(latestPath);
            auto id = idStr.to!uint;
            
            auto dictPath = buildPath(_storageDir, "dict_" ~ idStr ~ ".zdict");
            auto metaPath = buildPath(_storageDir, "dict_" ~ idStr ~ ".meta");
            
            if (exists(dictPath) && exists(metaPath))
            {
                _currentDict = cast(ubyte[])read(dictPath);
                _currentMeta = DictionaryMeta.deserialize(cast(ubyte[])read(metaPath));
                compileDictionary();
            }
        }
        catch (Exception) {}
    }
    
    /// Load dictionary by ID
    BuildResult!(ubyte[]) loadDictionaryById(uint id) @trusted
    {
        auto dictPath = buildPath(_storageDir, "dict_" ~ id.to!string ~ ".zdict");
        
        if (!exists(dictPath))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Dictionary not found: " ~ id.to!string, Cache.NotFound).build());
        
        return Ok!(ubyte[], BuildError)(cast(ubyte[])read(dictPath));
    }
}

/// Configuration for shared dictionary manager
struct SharedDictConfig
{
    size_t dictSize = 110 * 1024;              // 110KB dictionary
    size_t minSampleSize = 256;                 // Min sample size to collect
    size_t maxSampleSize = 1024 * 1024;         // Max sample size (1MB)
    size_t maxSamples = 1000;                   // Max samples to keep
    size_t maxTotalSampleBytes = 100 * 1024 * 1024;  // 100MB total samples
    size_t minSamplesForTraining = 50;          // Min samples before training
    Duration maxDictionaryAge = 24.hours;       // Retrain after this duration
}

/// Dictionary package for distribution
struct DictionaryPackage
{
    ubyte[] data;
    DictionaryMeta meta;
    
    /// Serialize for network transfer
    ubyte[] serialize() const @trusted
    {
        auto buf = appender!(ubyte[])();
        auto metaData = meta.serialize();
        buf ~= nativeToBigEndian(cast(uint)metaData.length)[];
        buf ~= metaData;
        buf ~= nativeToBigEndian(cast(uint)data.length)[];
        buf ~= data;
        return buf[];
    }
    
    /// Deserialize from network
    static DictionaryPackage deserialize(const(ubyte)[] raw) @trusted
    {
        DictionaryPackage pkg;
        if (raw.length < 8) return pkg;
        
        size_t pos = 0;
        auto metaLen = bigEndianToNative!uint(raw[pos .. pos + 4][0 .. 4]); pos += 4;
        
        if (raw.length < pos + metaLen + 4) return pkg;
        pkg.meta = DictionaryMeta.deserialize(raw[pos .. pos + metaLen]);
        pos += metaLen;
        
        auto dataLen = bigEndianToNative!uint(raw[pos .. pos + 4][0 .. 4]); pos += 4;
        
        if (raw.length < pos + dataLen) return pkg;
        pkg.data = raw[pos .. pos + dataLen].dup;
        
        return pkg;
    }
}

/// Dictionary statistics
struct DictionaryStats
{
    size_t samplesCollected;
    size_t dictionariesTrained;
    size_t dictionariesReceived;
    size_t compressionsWithDict;
    size_t compressionsWithoutDict;
    size_t bytesCompressed;
    size_t bytesAfterCompression;
    Duration lastTrainingTime;
    
    float compressionRatio() const pure nothrow @nogc @trusted
        => bytesCompressed == 0 ? 1.0f : cast(float)bytesAfterCompression / bytesCompressed;
    
    float dictUsageRate() const pure nothrow @nogc @trusted
    {
        auto total = compressionsWithDict + compressionsWithoutDict;
        return total == 0 ? 0.0f : cast(float)compressionsWithDict / total;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Dict: trained=%d ratio=%.2f%% usage=%.1f%% samples=%d",
            dictionariesTrained, compressionRatio * 100,
            dictUsageRate * 100, samplesCollected
        );
    }
}

// Helper to get null-terminated string length
private size_t strLen(const(char)* s) @trusted nothrow @nogc
{
    if (s is null) return 0;
    size_t len = 0;
    while (s[len] != '\0') len++;
    return len;
}

/// Distributed dictionary synchronization protocol
/// Enables workers to share and update dictionaries
struct DictionarySyncProtocol
{
    /// Message types for dictionary sync
    enum MessageType : ubyte
    {
        RequestLatest = 1,      // Request latest dictionary
        DictionaryResponse = 2, // Response with dictionary data
        DictionaryUpdate = 3,   // Broadcast new dictionary
        Heartbeat = 4           // Keepalive with current dict ID
    }
    
    /// Sync message header
    struct Header
    {
        MessageType type;
        uint dictionaryId;
        size_t payloadSize;
        
        ubyte[] serialize() const @trusted
        {
            ubyte[13] buf;
            buf[0] = cast(ubyte)type;
            buf[1 .. 5] = nativeToBigEndian(dictionaryId)[];
            buf[5 .. 13] = nativeToBigEndian(cast(ulong)payloadSize)[];
            return buf[].dup;
        }
        
        static Header deserialize(const(ubyte)[] data) @trusted
        {
            Header h;
            if (data.length < 13) return h;
            h.type = cast(MessageType)data[0];
            h.dictionaryId = bigEndianToNative!uint(data[1 .. 5][0 .. 4]);
            h.payloadSize = bigEndianToNative!ulong(data[5 .. 13][0 .. 8]);
            return h;
        }
    }
    
    /// Create request for latest dictionary
    static ubyte[] createRequest(uint currentId) @trusted
    {
        Header h;
        h.type = MessageType.RequestLatest;
        h.dictionaryId = currentId;
        h.payloadSize = 0;
        return h.serialize();
    }
    
    /// Create dictionary response
    static ubyte[] createResponse(DictionaryPackage pkg) @trusted
    {
        auto payload = pkg.serialize();
        Header h;
        h.type = MessageType.DictionaryResponse;
        h.dictionaryId = pkg.meta.id;
        h.payloadSize = payload.length;
        
        auto buf = appender!(ubyte[])();
        buf ~= h.serialize();
        buf ~= payload;
        return buf[];
    }
    
    /// Create dictionary update broadcast
    static ubyte[] createUpdate(DictionaryPackage pkg) @trusted
    {
        auto payload = pkg.serialize();
        Header h;
        h.type = MessageType.DictionaryUpdate;
        h.dictionaryId = pkg.meta.id;
        h.payloadSize = payload.length;
        
        auto buf = appender!(ubyte[])();
        buf ~= h.serialize();
        buf ~= payload;
        return buf[];
    }
    
    /// Create heartbeat with current dictionary ID
    static ubyte[] createHeartbeat(uint dictId) @trusted
    {
        Header h;
        h.type = MessageType.Heartbeat;
        h.dictionaryId = dictId;
        h.payloadSize = 0;
        return h.serialize();
    }
}

/// Unit tests
unittest
{
    import std.stdio;
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m dictionary.SharedDictionaryManager - Sample collection");
    
    auto testDir = buildPath(tempDir(), "bldr-test-dict");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    SharedDictConfig config;
    config.minSamplesForTraining = 5;
    
    auto mgr = new SharedDictionaryManager(testDir, config);
    
    // Add samples
    foreach (i; 0 .. 10)
    {
        auto sample = new ubyte[](1024);
        foreach (j, ref b; sample) b = cast(ubyte)((i + j) % 256);
        mgr.addSample(sample);
    }
    
    auto stats = mgr.getStats();
    assert(stats.samplesCollected == 10);
    
    writeln("\x1b[32m  ✓ Sample collection\x1b[0m");
}

unittest
{
    import std.stdio;
    
    writeln("\x1b[36m[TEST]\x1b[0m dictionary.DictionaryPackage - Serialization");
    
    DictionaryPackage pkg;
    pkg.data = cast(ubyte[])"test dictionary data".dup;
    pkg.meta.id = 12345;
    pkg.meta.size = pkg.data.length;
    
    auto serialized = pkg.serialize();
    auto restored = DictionaryPackage.deserialize(serialized);
    
    assert(restored.meta.id == pkg.meta.id);
    assert(restored.data == pkg.data);
    
    writeln("\x1b[32m  ✓ Serialization round-trip\x1b[0m");
}

unittest
{
    import std.stdio;
    
    writeln("\x1b[36m[TEST]\x1b[0m dictionary.DictionarySyncProtocol - Message creation");
    
    // Test heartbeat
    auto heartbeat = DictionarySyncProtocol.createHeartbeat(42);
    auto header = DictionarySyncProtocol.Header.deserialize(heartbeat);
    assert(header.type == DictionarySyncProtocol.MessageType.Heartbeat);
    assert(header.dictionaryId == 42);
    
    // Test request
    auto request = DictionarySyncProtocol.createRequest(0);
    header = DictionarySyncProtocol.Header.deserialize(request);
    assert(header.type == DictionarySyncProtocol.MessageType.RequestLatest);
    
    writeln("\x1b[32m  ✓ Message creation\x1b[0m");
}

