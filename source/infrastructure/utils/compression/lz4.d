module infrastructure.utils.compression.lz4;

/// Low-level C bindings for LZ4
/// Based on lz4.h and lz4frame.h: https://github.com/lz4/lz4
/// Link with: -llz4

extern(C) @system nothrow @nogc:

// =============================================================================
// Version
// =============================================================================

enum LZ4_VERSION_MAJOR = 1;
enum LZ4_VERSION_MINOR = 9;
enum LZ4_VERSION_RELEASE = 4;

int LZ4_versionNumber();
const(char)* LZ4_versionString();

// =============================================================================
// Simple Block API
// =============================================================================

/// Compress src into dst; returns compressed size or 0 on failure
int LZ4_compress_default(const(char)* src, char* dst, int srcSize, int dstCapacity);

/// Fast compression with acceleration (1=fastest, higher=better ratio)
int LZ4_compress_fast(const(char)* src, char* dst, int srcSize, int dstCapacity, int acceleration);

/// Decompress src into dst; returns decompressed size or negative on error
int LZ4_decompress_safe(const(char)* src, char* dst, int compressedSize, int dstCapacity);

/// Upper bound for compressed size
int LZ4_compressBound(int inputSize);

// =============================================================================
// High Compression (LZ4HC)
// =============================================================================

/// HC compression levels
enum LZ4HC_CLEVEL_MIN = 3;
enum LZ4HC_CLEVEL_DEFAULT = 9;
enum LZ4HC_CLEVEL_OPT_MIN = 10;
enum LZ4HC_CLEVEL_MAX = 12;

/// High-compression mode
int LZ4_compress_HC(const(char)* src, char* dst, int srcSize, int dstCapacity, int compressionLevel);

// =============================================================================
// Streaming Block Compression State
// =============================================================================

struct LZ4_stream_t {
    align(8) uint[4096] table;
    uint currentOffset;
    bool dirty;
    uint tableType;
    const(ubyte)* dictionary;
    const(LZ4_stream_t)* dictCtx;
    uint dictSize;
}

struct LZ4_streamDecode_t {
    const(ubyte)* externalDict;
    size_t extDictSize;
    const(ubyte)* prefixEnd;
    size_t prefixSize;
}

/// Create/free streaming state
LZ4_stream_t* LZ4_createStream();
int LZ4_freeStream(LZ4_stream_t* streamPtr);

/// Reset stream for new compression
void LZ4_resetStream_fast(LZ4_stream_t* streamPtr);

/// Load dictionary into stream
int LZ4_loadDict(LZ4_stream_t* streamPtr, const(char)* dictionary, int dictSize);

/// Compress block with streaming context
int LZ4_compress_fast_continue(LZ4_stream_t* streamPtr, 
                               const(char)* src, char* dst,
                               int srcSize, int dstCapacity, 
                               int acceleration);

/// Save dictionary from stream
int LZ4_saveDict(LZ4_stream_t* streamPtr, char* safeBuffer, int maxDictSize);

/// Create/free decode state
LZ4_streamDecode_t* LZ4_createStreamDecode();
int LZ4_freeStreamDecode(LZ4_streamDecode_t* LZ4_stream);

/// Set dictionary for decode
int LZ4_setStreamDecode(LZ4_streamDecode_t* LZ4_streamDecode,
                        const(char)* dictionary, int dictSize);

/// Decompress with streaming context
int LZ4_decompress_safe_continue(LZ4_streamDecode_t* LZ4_streamDecode,
                                 const(char)* src, char* dst,
                                 int srcSize, int dstCapacity);

// =============================================================================
// Frame API (recommended for files/streams)
// =============================================================================

/// Frame error codes
alias LZ4F_errorCode_t = size_t;

uint LZ4F_isError(LZ4F_errorCode_t code);
const(char)* LZ4F_getErrorName(LZ4F_errorCode_t code);

/// Frame block sizes
enum LZ4F_blockSizeID_t {
    LZ4F_default = 0,
    LZ4F_max64KB = 4,
    LZ4F_max256KB = 5,
    LZ4F_max1MB = 6,
    LZ4F_max4MB = 7
}

/// Block mode
enum LZ4F_blockMode_t {
    LZ4F_blockLinked = 0,
    LZ4F_blockIndependent = 1
}

/// Content checksum
enum LZ4F_contentChecksum_t {
    LZ4F_noContentChecksum = 0,
    LZ4F_contentChecksumEnabled = 1
}

/// Block checksum
enum LZ4F_blockChecksum_t {
    LZ4F_noBlockChecksum = 0,
    LZ4F_blockChecksumEnabled = 1
}

/// Frame type
enum LZ4F_frameType_t {
    LZ4F_frame = 0,
    LZ4F_skippableFrame = 1
}

/// Frame info (read from header)
struct LZ4F_frameInfo_t {
    LZ4F_blockSizeID_t blockSizeID;
    LZ4F_blockMode_t blockMode;
    LZ4F_contentChecksum_t contentChecksumFlag;
    LZ4F_frameType_t frameType;
    ulong contentSize;
    uint dictID;
    LZ4F_blockChecksum_t blockChecksumFlag;
}

/// Frame preferences (for compression)
struct LZ4F_preferences_t {
    LZ4F_frameInfo_t frameInfo;
    int compressionLevel;        /// 0=default (fast), 1-12 for HC levels
    uint autoFlush;              /// 1 = always flush
    uint favorDecSpeed;          /// 1 = favor decompression speed
    uint[3] reserved;
}

/// Compression context
struct LZ4F_cctx;
alias LZ4F_compressionContext_t = LZ4F_cctx*;

/// Decompression context  
struct LZ4F_dctx;
alias LZ4F_decompressionContext_t = LZ4F_dctx*;

// =============================================================================
// Frame Compression
// =============================================================================

/// Get required buffer size for compression
size_t LZ4F_compressFrameBound(size_t srcSize, const(LZ4F_preferences_t)* preferencesPtr);

/// Simple one-shot frame compression
size_t LZ4F_compressFrame(void* dstBuffer, size_t dstCapacity,
                          const(void)* srcBuffer, size_t srcSize,
                          const(LZ4F_preferences_t)* preferencesPtr);

/// Create/free compression context
LZ4F_errorCode_t LZ4F_createCompressionContext(LZ4F_compressionContext_t* cctxPtr, uint version_);
LZ4F_errorCode_t LZ4F_freeCompressionContext(LZ4F_compressionContext_t cctx);

/// Begin frame - write header
size_t LZ4F_compressBegin(LZ4F_compressionContext_t cctx,
                          void* dstBuffer, size_t dstCapacity,
                          const(LZ4F_preferences_t)* prefsPtr);

/// Get required buffer size for update
size_t LZ4F_compressBound(size_t srcSize, const(LZ4F_preferences_t)* prefsPtr);

/// Compress a chunk
size_t LZ4F_compressUpdate(LZ4F_compressionContext_t cctx,
                           void* dstBuffer, size_t dstCapacity,
                           const(void)* srcBuffer, size_t srcSize,
                           const(void)* cOptPtr);  // LZ4F_compressOptions_t*

/// Flush output buffer
size_t LZ4F_flush(LZ4F_compressionContext_t cctx,
                  void* dstBuffer, size_t dstCapacity,
                  const(void)* cOptPtr);

/// End frame
size_t LZ4F_compressEnd(LZ4F_compressionContext_t cctx,
                        void* dstBuffer, size_t dstCapacity,
                        const(void)* cOptPtr);

// =============================================================================
// Frame Decompression
// =============================================================================

/// Create/free decompression context
LZ4F_errorCode_t LZ4F_createDecompressionContext(LZ4F_decompressionContext_t* dctxPtr, uint version_);
LZ4F_errorCode_t LZ4F_freeDecompressionContext(LZ4F_decompressionContext_t dctx);

/// Get frame info from header
size_t LZ4F_getFrameInfo(LZ4F_decompressionContext_t dctx,
                         LZ4F_frameInfo_t* frameInfoPtr,
                         const(void)* srcBuffer, size_t* srcSizePtr);

/// Decompress a chunk - returns hint for next srcSize
size_t LZ4F_decompress(LZ4F_decompressionContext_t dctx,
                       void* dstBuffer, size_t* dstSizePtr,
                       const(void)* srcBuffer, size_t* srcSizePtr,
                       const(void)* dOptPtr);  // LZ4F_decompressOptions_t*

/// Reset decompression context
void LZ4F_resetDecompressionContext(LZ4F_decompressionContext_t dctx);

/// LZ4F version constant for context creation
enum LZ4F_VERSION = 100;


