module infrastructure.utils.compression.streaming;

import infrastructure.utils.compression.zstd;
import infrastructure.utils.compression.lz4;
import infrastructure.errors;
import std.algorithm : min;

/// Streaming compression context for large artifacts
/// Processes data in chunks to minimize memory usage
/// Thread-safe when using separate contexts per thread
final class ZstdStream
{
    private ZSTD_CStream* cstream;
    private ZSTD_DStream* dstream;
    private ZSTD_CDict* cdict;
    private ZSTD_DDict* ddict;
    private int level;
    private bool initialized;
    
    /// Recommended chunk sizes for streaming
    static size_t inputChunkSize() @trusted nothrow @nogc => ZSTD_CStreamInSize();
    static size_t outputChunkSize() @trusted nothrow @nogc => ZSTD_CStreamOutSize();
    
    /// Create streaming context with compression level (1-22)
    this(int compressionLevel = 3) @trusted
    {
        level = compressionLevel;
        cstream = ZSTD_createCStream();
        dstream = ZSTD_createDStream();
    }
    
    ~this() @trusted
    {
        if (cstream) ZSTD_freeCStream(cstream);
        if (dstream) ZSTD_freeDStream(dstream);
        if (cdict) ZSTD_freeCDict(cdict);
        if (ddict) ZSTD_freeDDict(ddict);
    }
    
    /// Load dictionary for compression (improves ratio on similar data)
    VoidBuildResult loadDictionary(const(ubyte)[] dict) @trusted
    {
        if (dict.length == 0) return VoidBuildResult.ok();
        
        if (cdict) ZSTD_freeCDict(cdict);
        if (ddict) ZSTD_freeDDict(ddict);
        
        cdict = ZSTD_createCDict(dict.ptr, dict.length, level);
        ddict = ZSTD_createDDict(dict.ptr, dict.length);
        
        if (!cdict || !ddict)
            return VoidBuildResult.err(Errors.cache("Failed to load dictionary", Cache.CompressionFailed).build());
        
        return VoidBuildResult.ok();
    }
    
    /// Compress data using streaming API
    /// For large artifacts: processes in chunks to bound memory
    BuildResult!(ubyte[]) compress(const(ubyte)[] src) @trusted
    {
        if (src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot compress empty data").build());
        
        // Initialize stream
        size_t initResult = cdict 
            ? ZSTD_initCStream_usingCDict(cstream, cdict)
            : ZSTD_initCStream(cstream, level);
        
        if (ZSTD_isError(initResult))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Stream init failed: " ~ cast(string)ZSTD_getErrorName(initResult)[0..strLen(ZSTD_getErrorName(initResult))],
                Cache.CompressionFailed).build());
        
        // Allocate output buffer (worst case + overhead)
        auto dstCapacity = ZSTD_compressBound(src.length);
        auto output = new ubyte[](dstCapacity);
        
        ZSTD_inBuffer input = { src.ptr, src.length, 0 };
        ZSTD_outBuffer outBuf = { output.ptr, output.length, 0 };
        
        // Compress all input
        while (input.pos < input.size)
        {
            auto remaining = ZSTD_compressStream(cstream, &outBuf, &input);
            if (ZSTD_isError(remaining))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Compression failed: " ~ cast(string)ZSTD_getErrorName(remaining)[0..strLen(ZSTD_getErrorName(remaining))],
                    Cache.CompressionFailed).build());
        }
        
        // Flush remaining data
        size_t remaining;
        do {
            remaining = ZSTD_endStream(cstream, &outBuf);
            if (ZSTD_isError(remaining))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "End stream failed", Cache.CompressionFailed).build());
        } while (remaining > 0);
        
        return Ok!(ubyte[], BuildError)(output[0 .. outBuf.pos].dup);
    }
    
    /// Decompress data using streaming API
    BuildResult!(ubyte[]) decompress(const(ubyte)[] src) @trusted
    {
        if (src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot decompress empty data").build());
        
        // Initialize stream
        size_t initResult = ddict
            ? ZSTD_initDStream_usingDDict(dstream, ddict)
            : ZSTD_initDStream(dstream);
        
        if (ZSTD_isError(initResult))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Decompress init failed", Cache.CompressionFailed).build());
        
        // Get decompressed size if available
        auto frameSize = ZSTD_getFrameContentSize(src.ptr, src.length);
        size_t dstCapacity = (frameSize != ZSTD_CONTENTSIZE_UNKNOWN && frameSize != ZSTD_CONTENTSIZE_ERROR)
            ? cast(size_t)frameSize
            : src.length * 4;  // Heuristic: 4x expansion
        
        auto output = new ubyte[](dstCapacity);
        ZSTD_inBuffer input = { src.ptr, src.length, 0 };
        ZSTD_outBuffer outBuf = { output.ptr, output.length, 0 };
        
        while (input.pos < input.size)
        {
            auto result = ZSTD_decompressStream(dstream, &outBuf, &input);
            if (ZSTD_isError(result))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Decompression failed: " ~ cast(string)ZSTD_getErrorName(result)[0..strLen(ZSTD_getErrorName(result))],
                    Cache.CompressionFailed).build());
            
            // Need more output space
            if (outBuf.pos == outBuf.size && input.pos < input.size)
            {
                auto newSize = output.length * 2;
                auto newOutput = new ubyte[](newSize);
                newOutput[0 .. outBuf.pos] = output[0 .. outBuf.pos];
                output = newOutput;
                outBuf.dst = output.ptr;
                outBuf.size = output.length;
            }
        }
        
        return Ok!(ubyte[], BuildError)(output[0 .. outBuf.pos].dup);
    }
    
    /// Compress data in chunks, calling sink for each output chunk
    /// Memory-efficient for very large artifacts
    VoidBuildResult compressChunked(
        const(ubyte)[] src,
        scope void delegate(const(ubyte)[]) @safe sink,
        size_t chunkSize = 0
    ) @trusted
    {
        if (chunkSize == 0) chunkSize = ZSTD_CStreamOutSize();
        
        size_t initResult = cdict
            ? ZSTD_initCStream_usingCDict(cstream, cdict)
            : ZSTD_initCStream(cstream, level);
        
        if (ZSTD_isError(initResult))
            return VoidBuildResult.err(Errors.cache("Stream init failed", Cache.CompressionFailed).build());
        
        auto outputBuf = new ubyte[](chunkSize);
        ZSTD_inBuffer input = { src.ptr, src.length, 0 };
        ZSTD_outBuffer outBuf = { outputBuf.ptr, outputBuf.length, 0 };
        
        while (input.pos < input.size)
        {
            outBuf.pos = 0;
            auto remaining = ZSTD_compressStream(cstream, &outBuf, &input);
            if (ZSTD_isError(remaining))
                return VoidBuildResult.err(Errors.cache("Compression failed", Cache.CompressionFailed).build());
            
            if (outBuf.pos > 0)
                sink(outputBuf[0 .. outBuf.pos]);
        }
        
        // Flush
        size_t remaining;
        do {
            outBuf.pos = 0;
            remaining = ZSTD_endStream(cstream, &outBuf);
            if (ZSTD_isError(remaining))
                return VoidBuildResult.err(Errors.cache("End stream failed", Cache.CompressionFailed).build());
            if (outBuf.pos > 0)
                sink(outputBuf[0 .. outBuf.pos]);
        } while (remaining > 0);
        
        return VoidBuildResult.ok();
    }
}

/// LZ4 streaming compression (frame format)
final class Lz4Stream
{
    private LZ4F_compressionContext_t cctx;
    private LZ4F_decompressionContext_t dctx;
    private int level;
    
    /// Create LZ4 streaming context
    this(int compressionLevel = 0) @trusted
    {
        level = compressionLevel;
        LZ4F_createCompressionContext(&cctx, LZ4F_VERSION);
        LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION);
    }
    
    ~this() @trusted
    {
        if (cctx) LZ4F_freeCompressionContext(cctx);
        if (dctx) LZ4F_freeDecompressionContext(dctx);
    }
    
    /// Compress data using LZ4 frame format
    BuildResult!(ubyte[]) compress(const(ubyte)[] src) @trusted
    {
        if (src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot compress empty data").build());
        
        LZ4F_preferences_t prefs;
        prefs.compressionLevel = level;
        prefs.frameInfo.blockSizeID = LZ4F_blockSizeID_t.LZ4F_max256KB;
        prefs.autoFlush = 1;
        
        auto bound = LZ4F_compressFrameBound(src.length, &prefs);
        auto output = new ubyte[](bound);
        
        auto written = LZ4F_compressFrame(output.ptr, output.length, src.ptr, src.length, &prefs);
        if (LZ4F_isError(written))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "LZ4 compression failed: " ~ cast(string)LZ4F_getErrorName(written)[0..strLen(LZ4F_getErrorName(written))],
                Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
    }
    
    /// Decompress LZ4 frame data
    BuildResult!(ubyte[]) decompress(const(ubyte)[] src) @trusted
    {
        if (src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot decompress empty data").build());
        
        LZ4F_resetDecompressionContext(dctx);
        
        // Get frame info for output size hint
        LZ4F_frameInfo_t info;
        size_t srcSize = src.length;
        auto headerSize = LZ4F_getFrameInfo(dctx, &info, src.ptr, &srcSize);
        
        if (LZ4F_isError(headerSize))
            return Err!(ubyte[], BuildError)(Errors.cache("Invalid LZ4 frame", Cache.CompressionFailed).build());
        
        // Estimate output size
        size_t dstCapacity = info.contentSize > 0 ? cast(size_t)info.contentSize : src.length * 4;
        auto output = new ubyte[](dstCapacity);
        
        size_t srcPos = headerSize;
        size_t dstPos = 0;
        
        while (srcPos < src.length)
        {
            size_t srcChunk = src.length - srcPos;
            size_t dstChunk = output.length - dstPos;
            
            auto result = LZ4F_decompress(dctx, 
                output.ptr + dstPos, &dstChunk,
                src.ptr + srcPos, &srcChunk, null);
            
            if (LZ4F_isError(result))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "LZ4 decompression failed", Cache.CompressionFailed).build());
            
            srcPos += srcChunk;
            dstPos += dstChunk;
            
            // Expand if needed
            if (dstPos >= output.length && srcPos < src.length)
            {
                auto newOutput = new ubyte[](output.length * 2);
                newOutput[0 .. dstPos] = output[0 .. dstPos];
                output = newOutput;
            }
        }
        
        return Ok!(ubyte[], BuildError)(output[0 .. dstPos].dup);
    }
}

/// RAII wrapper for zstd compression context (single-shot)
struct ZstdContext
{
    private ZSTD_CCtx* cctx;
    private ZSTD_DCtx* dctx;
    
    @disable this(this);
    
    static ZstdContext create() @trusted
    {
        ZstdContext ctx;
        ctx.cctx = ZSTD_createCCtx();
        ctx.dctx = ZSTD_createDCtx();
        return ctx;
    }
    
    ~this() @trusted
    {
        if (cctx) ZSTD_freeCCtx(cctx);
        if (dctx) ZSTD_freeDCtx(dctx);
    }
    
    /// Compress with reusable context (more efficient than simple API)
    BuildResult!(ubyte[]) compress(const(ubyte)[] src, int level = 3) @trusted
    {
        if (!cctx || src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Invalid context or empty data").build());
        
        auto dstCapacity = ZSTD_compressBound(src.length);
        auto output = new ubyte[](dstCapacity);
        
        auto written = ZSTD_compressCCtx(cctx, output.ptr, output.length, src.ptr, src.length, level);
        if (ZSTD_isError(written))
            return Err!(ubyte[], BuildError)(Errors.cache("Compression failed", Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
    }
    
    /// Decompress with reusable context
    BuildResult!(ubyte[]) decompress(const(ubyte)[] src) @trusted
    {
        if (!dctx || src.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Invalid context or empty data").build());
        
        auto frameSize = ZSTD_getFrameContentSize(src.ptr, src.length);
        size_t dstCapacity = (frameSize != ZSTD_CONTENTSIZE_UNKNOWN && frameSize != ZSTD_CONTENTSIZE_ERROR)
            ? cast(size_t)frameSize
            : src.length * 4;
        
        auto output = new ubyte[](dstCapacity);
        auto written = ZSTD_decompressDCtx(dctx, output.ptr, output.length, src.ptr, src.length);
        
        if (ZSTD_isError(written))
            return Err!(ubyte[], BuildError)(Errors.cache("Decompression failed", Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
    }
    
    bool valid() const @safe nothrow @nogc => cctx !is null && dctx !is null;
}

/// Thread-local compression context pool for high throughput
struct ContextPool
{
    private static ZstdContext*[] _pool;
    private static size_t _poolSize;
    
    enum MAX_POOL_SIZE = 16;
    
    /// Borrow context from pool (creates if needed)
    static ZstdContext* borrow() @trusted
    {
        if (_poolSize > 0)
        {
            _poolSize--;
            return _pool[_poolSize];
        }
        
        auto ctx = new ZstdContext();
        *ctx = ZstdContext.create();
        return ctx;
    }
    
    /// Return context to pool
    static void release(ZstdContext* ctx) @trusted
    {
        if (ctx is null) return;
        
        if (_poolSize < MAX_POOL_SIZE)
        {
            if (_pool.length <= _poolSize)
                _pool.length = _poolSize + 1;
            _pool[_poolSize++] = ctx;
        }
        // else: context destroyed when GC collects
    }
}

/// Simple one-shot compression (uses pooled context)
BuildResult!(ubyte[]) zstdCompress(const(ubyte)[] data, int level = 3) @trusted
{
    auto ctx = ContextPool.borrow();
    scope(exit) ContextPool.release(ctx);
    return ctx.compress(data, level);
}

/// Simple one-shot decompression (uses pooled context)
BuildResult!(ubyte[]) zstdDecompress(const(ubyte)[] data) @trusted
{
    auto ctx = ContextPool.borrow();
    scope(exit) ContextPool.release(ctx);
    return ctx.decompress(data);
}

/// Simple one-shot LZ4 compression
BuildResult!(ubyte[]) lz4Compress(const(ubyte)[] data, int level = 0) @trusted
{
    if (data.length == 0)
        return Err!(ubyte[], BuildError)(Errors.generic("Cannot compress empty data").build());
    
    auto bound = LZ4_compressBound(cast(int)data.length);
    auto output = new ubyte[](bound);
    
    int written = level > 0
        ? LZ4_compress_HC(cast(char*)data.ptr, cast(char*)output.ptr, cast(int)data.length, bound, level)
        : LZ4_compress_default(cast(char*)data.ptr, cast(char*)output.ptr, cast(int)data.length, bound);
    
    if (written <= 0)
        return Err!(ubyte[], BuildError)(Errors.cache("LZ4 compression failed", Cache.CompressionFailed).build());
    
    return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
}

/// Simple one-shot LZ4 decompression (needs original size)
BuildResult!(ubyte[]) lz4Decompress(const(ubyte)[] data, size_t originalSize) @trusted
{
    if (data.length == 0)
        return Err!(ubyte[], BuildError)(Errors.generic("Cannot decompress empty data").build());
    
    auto output = new ubyte[](originalSize);
    auto written = LZ4_decompress_safe(cast(char*)data.ptr, cast(char*)output.ptr, 
                                       cast(int)data.length, cast(int)originalSize);
    
    if (written < 0)
        return Err!(ubyte[], BuildError)(Errors.cache("LZ4 decompression failed", Cache.CompressionFailed).build());
    
    return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
}

// Helper to get null-terminated string length
private size_t strLen(const(char)* s) @trusted nothrow @nogc
{
    if (s is null) return 0;
    size_t len = 0;
    while (s[len] != '\0') len++;
    return len;
}


