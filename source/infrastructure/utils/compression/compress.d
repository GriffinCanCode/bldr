module infrastructure.utils.compression.compress;

import infrastructure.utils.compression.streaming;
import infrastructure.utils.compression.zstd;
import infrastructure.utils.compression.lz4;
import infrastructure.errors;

/// Compression algorithm
enum CompressionAlgorithm
{
    None,      // No compression
    Zstd,      // Zstandard (best ratio, fast)
    Lz4        // LZ4 (fastest, lower ratio)
}

/// Compression level (1-22 for zstd, 1-12 for lz4)
alias CompressionLevel = int;

/// Standard compression levels
enum StandardLevel : CompressionLevel
{
    Fastest = 1,
    Fast = 3,
    Default = 5,
    Better = 9,
    Best = 15
}

/// Compression result
struct CompressionResult
{
    ubyte[] data;              // Compressed data
    size_t originalSize;       // Original size
    size_t compressedSize;     // Compressed size
    float ratio;               // Compression ratio
    CompressionAlgorithm algo; // Algorithm used
}

/// Decompression result
alias DecompressionResult = ubyte[];

/// Compression service using FFI bindings (no subprocess)
final class Compressor
{
    private CompressionAlgorithm _algorithm;
    private CompressionLevel _level;
    private ZstdStream _zstdStream;
    private Lz4Stream _lz4Stream;
    
    /// Constructor
    this(CompressionAlgorithm algo = CompressionAlgorithm.Zstd, CompressionLevel level = StandardLevel.Default) @trusted
    {
        _algorithm = algo;
        _level = level;
        
        // Lazy init streams only when needed
    }
    
    /// Compress data
    BuildResult!CompressionResult compress(const(ubyte)[] data) @trusted
    {
        if (data.length == 0)
            return Err!(CompressionResult, BuildError)(
                Errors.generic("Cannot compress empty data")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        
        final switch (_algorithm)
        {
            case CompressionAlgorithm.None:  return compressNone(data);
            case CompressionAlgorithm.Zstd:  return compressZstd(data);
            case CompressionAlgorithm.Lz4:   return compressLz4(data);
        }
    }
    
    /// Decompress data
    BuildResult!DecompressionResult decompress(const(ubyte)[] data, CompressionAlgorithm algo) @trusted
    {
        if (data.length == 0)
            return Err!(DecompressionResult, BuildError)(
                Errors.generic("Cannot decompress empty data")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        
        final switch (algo)
        {
            case CompressionAlgorithm.None:  return decompressNone(data);
            case CompressionAlgorithm.Zstd:  return decompressZstd(data);
            case CompressionAlgorithm.Lz4:   return decompressLz4(data);
        }
    }
    
    /// Check if compression is beneficial (>5% reduction)
    static bool shouldCompress(size_t originalSize, size_t compressedSize) pure @safe nothrow
    {
        if (originalSize == 0) return false;
        return cast(float)compressedSize / cast(float)originalSize < 0.95;
    }
    
    private BuildResult!CompressionResult compressNone(const(ubyte)[] data) pure @trusted
    {
        CompressionResult result;
        result.data = data.dup;
        result.originalSize = data.length;
        result.compressedSize = data.length;
        result.ratio = 1.0;
        result.algo = CompressionAlgorithm.None;
        return Ok!(CompressionResult, BuildError)(result);
    }
    
    private BuildResult!CompressionResult compressZstd(const(ubyte)[] data) @trusted
    {
        auto compResult = zstdCompress(data, _level);
        if (compResult.isErr)
            return compressNone(data);  // Fallback
        
        auto compressed = compResult.unwrap();
        CompressionResult result;
        result.data = compressed;
        result.originalSize = data.length;
        result.compressedSize = compressed.length;
        result.ratio = cast(float)compressed.length / cast(float)data.length;
        result.algo = CompressionAlgorithm.Zstd;
        return Ok!(CompressionResult, BuildError)(result);
    }
    
    private BuildResult!CompressionResult compressLz4(const(ubyte)[] data) @trusted
    {
        auto compResult = lz4Compress(data, _level > 3 ? _level : 0);
        if (compResult.isErr)
            return compressNone(data);  // Fallback
        
        auto compressed = compResult.unwrap();
        CompressionResult result;
        result.data = compressed;
        result.originalSize = data.length;
        result.compressedSize = compressed.length;
        result.ratio = cast(float)compressed.length / cast(float)data.length;
        result.algo = CompressionAlgorithm.Lz4;
        return Ok!(CompressionResult, BuildError)(result);
    }
    
    private BuildResult!DecompressionResult decompressNone(const(ubyte)[] data) pure @trusted
    {
        return Ok!(DecompressionResult, BuildError)(data.dup);
    }
    
    private BuildResult!DecompressionResult decompressZstd(const(ubyte)[] data) @trusted
    {
        return zstdDecompress(data);
    }
    
    private BuildResult!DecompressionResult decompressLz4(const(ubyte)[] data) @trusted
    {
        // LZ4 frame format includes size info, use streaming API
        auto stream = new Lz4Stream();
        return stream.decompress(data);
    }
}

/// Utility functions for quick compression/decompression
struct CompressUtil
{
    /// Quick compress with default settings
    static BuildResult!(ubyte[]) compress(const(ubyte)[] data) @trusted
    {
        auto result = zstdCompress(data, StandardLevel.Default);
        if (result.isErr)
            return Err!(ubyte[], BuildError)(result.unwrapErr());
        return Ok!(ubyte[], BuildError)(result.unwrap());
    }
    
    /// Quick decompress (auto-detects zstd)
    static BuildResult!(ubyte[]) decompress(const(ubyte)[] data, CompressionAlgorithm algo) @trusted
    {
        if (algo == CompressionAlgorithm.None)
            return Ok!(ubyte[], BuildError)(cast(ubyte[])data.dup);
        
        if (algo == CompressionAlgorithm.Zstd)
            return zstdDecompress(data);
        
        // LZ4 frame format
        auto stream = new Lz4Stream();
        return stream.decompress(data);
    }
}

