module infrastructure.utils.compression.zstd;

/// Low-level C bindings for Zstandard (zstd)
/// Based on zstd.h: https://github.com/facebook/zstd
/// Link with: -lzstd

extern(C) @system nothrow @nogc:

// Version
enum ZSTD_VERSION_MAJOR = 1;
enum ZSTD_VERSION_MINOR = 5;
enum ZSTD_VERSION_RELEASE = 5;
uint ZSTD_versionNumber();
const(char)* ZSTD_versionString();

// Error handling
alias ZSTD_ErrorCode = int;
uint ZSTD_isError(size_t code);
const(char)* ZSTD_getErrorName(size_t code);
int ZSTD_minCLevel();
int ZSTD_maxCLevel();
int ZSTD_defaultCLevel();

// =============================================================================
// Simple API (single-shot compression/decompression)
// =============================================================================

/// Compress src into dst; returns compressed size or error code
size_t ZSTD_compress(void* dst, size_t dstCapacity, 
                     const(void)* src, size_t srcSize, 
                     int compressionLevel);

/// Decompress src into dst; returns decompressed size or error code
size_t ZSTD_decompress(void* dst, size_t dstCapacity,
                       const(void)* src, size_t compressedSize);

/// Upper bound for compressed size (use for allocation)
size_t ZSTD_compressBound(size_t srcSize);

/// Get decompressed size from frame header (0 if unknown)
ulong ZSTD_getFrameContentSize(const(void)* src, size_t srcSize);

enum ZSTD_CONTENTSIZE_UNKNOWN = cast(ulong)-1;
enum ZSTD_CONTENTSIZE_ERROR = cast(ulong)-2;

// =============================================================================
// Streaming Compression Context
// =============================================================================

struct ZSTD_CCtx;
struct ZSTD_DCtx;

/// Create/free compression context (reusable, thread-local recommended)
ZSTD_CCtx* ZSTD_createCCtx();
size_t ZSTD_freeCCtx(ZSTD_CCtx* cctx);

/// Create/free decompression context
ZSTD_DCtx* ZSTD_createDCtx();
size_t ZSTD_freeDCtx(ZSTD_DCtx* dctx);

/// Compress with reusable context
size_t ZSTD_compressCCtx(ZSTD_CCtx* cctx, 
                         void* dst, size_t dstCapacity,
                         const(void)* src, size_t srcSize, 
                         int compressionLevel);

/// Decompress with reusable context
size_t ZSTD_decompressDCtx(ZSTD_DCtx* dctx,
                           void* dst, size_t dstCapacity,
                           const(void)* src, size_t srcSize);

// =============================================================================
// Streaming API
// =============================================================================

struct ZSTD_CStream;
struct ZSTD_DStream;

/// Create/free streaming contexts
ZSTD_CStream* ZSTD_createCStream();
size_t ZSTD_freeCStream(ZSTD_CStream* zcs);
ZSTD_DStream* ZSTD_createDStream();
size_t ZSTD_freeDStream(ZSTD_DStream* zds);

/// Initialize streaming compression
size_t ZSTD_initCStream(ZSTD_CStream* zcs, int compressionLevel);
size_t ZSTD_initDStream(ZSTD_DStream* zds);

/// Recommended buffer sizes for streaming
size_t ZSTD_CStreamInSize();
size_t ZSTD_CStreamOutSize();
size_t ZSTD_DStreamInSize();
size_t ZSTD_DStreamOutSize();

/// Streaming I/O buffers
struct ZSTD_inBuffer {
    const(void)* src;  /// Start of input buffer
    size_t size;       /// Size of input buffer
    size_t pos;        /// Position where reading stopped (updated by zstd)
}

struct ZSTD_outBuffer {
    void* dst;         /// Start of output buffer
    size_t size;       /// Size of output buffer
    size_t pos;        /// Position where writing stopped (updated by zstd)
}

/// Streaming compression - returns hint for next input size
size_t ZSTD_compressStream(ZSTD_CStream* zcs, 
                           ZSTD_outBuffer* output, 
                           ZSTD_inBuffer* input);

/// Flush any remaining data in internal buffer
size_t ZSTD_flushStream(ZSTD_CStream* zcs, ZSTD_outBuffer* output);

/// End stream and flush final frame
size_t ZSTD_endStream(ZSTD_CStream* zcs, ZSTD_outBuffer* output);

/// Streaming decompression - returns hint for next input size
size_t ZSTD_decompressStream(ZSTD_DStream* zds,
                             ZSTD_outBuffer* output,
                             ZSTD_inBuffer* input);

// =============================================================================
// Dictionary API
// =============================================================================

struct ZSTD_CDict;
struct ZSTD_DDict;

/// Create compiled dictionary for compression (thread-safe once created)
ZSTD_CDict* ZSTD_createCDict(const(void)* dictBuffer, size_t dictSize, int compressionLevel);
size_t ZSTD_freeCDict(ZSTD_CDict* cdict);

/// Create compiled dictionary for decompression
ZSTD_DDict* ZSTD_createDDict(const(void)* dictBuffer, size_t dictSize);
size_t ZSTD_freeDDict(ZSTD_DDict* ddict);

/// Compress with dictionary
size_t ZSTD_compress_usingCDict(ZSTD_CCtx* cctx,
                                void* dst, size_t dstCapacity,
                                const(void)* src, size_t srcSize,
                                const(ZSTD_CDict)* cdict);

/// Decompress with dictionary
size_t ZSTD_decompress_usingDDict(ZSTD_DCtx* dctx,
                                  void* dst, size_t dstCapacity,
                                  const(void)* src, size_t srcSize,
                                  const(ZSTD_DDict)* ddict);

/// Get dictionary ID from frame
uint ZSTD_getDictID_fromFrame(const(void)* src, size_t srcSize);
uint ZSTD_getDictID_fromDict(const(void)* dict, size_t dictSize);
uint ZSTD_getDictID_fromDDict(const(ZSTD_DDict)* ddict);

// =============================================================================
// Advanced Streaming with Dictionary
// =============================================================================

/// Initialize streaming with dictionary
size_t ZSTD_initCStream_usingCDict(ZSTD_CStream* zcs, const(ZSTD_CDict)* cdict);
size_t ZSTD_initDStream_usingDDict(ZSTD_DStream* zds, const(ZSTD_DDict)* ddict);

// =============================================================================
// Frame inspection
// =============================================================================

/// Get decompressed size if stored in frame
ulong ZSTD_findDecompressedSize(const(void)* src, size_t srcSize);

/// Find frame boundaries in concatenated frames
size_t ZSTD_findFrameCompressedSize(const(void)* src, size_t srcSize);

// =============================================================================
// Dictionary Training (advanced)
// =============================================================================

/// Train dictionary from samples
/// Returns dictionary size written to dictBuffer, or error code
size_t ZDICT_trainFromBuffer(void* dictBuffer, size_t dictBufferCapacity,
                             const(void)* samplesBuffer, const(size_t)* samplesSizes,
                             uint nbSamples);

/// Finalize dictionary with optimized parameters
size_t ZDICT_finalizeDictionary(void* dstDictBuffer, size_t maxDictSize,
                                const(void)* dictContent, size_t dictContentSize,
                                const(void)* samplesBuffer, const(size_t)* samplesSizes,
                                uint nbSamples, 
                                void* parameters);  // ZDICT_params_t*

/// Check if result is an error
uint ZDICT_isError(size_t errorCode);
const(char)* ZDICT_getErrorName(size_t errorCode);


