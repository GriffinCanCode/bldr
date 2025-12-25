module infrastructure.utils.compression.compress;

import std.file : exists, read, write;
import std.path : buildPath;
import std.algorithm : min;
import std.conv : to;
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

/// Compression service
final class Compressor
{
    private CompressionAlgorithm _algorithm;
    private CompressionLevel _level;
    
    /// Constructor
    this(CompressionAlgorithm algo = CompressionAlgorithm.Zstd, CompressionLevel level = StandardLevel.Default) @safe
    {
        _algorithm = algo;
        _level = level;
    }
    
    /// Compress data
    BuildResult!CompressionResult compress(const(ubyte)[] data) @trusted
    {
        if (data.length == 0)
        {
            return Err!(CompressionResult, BuildError)(
                Errors.generic("Cannot compress empty data")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        final switch (_algorithm)
        {
            case CompressionAlgorithm.None:
                return compressNone(data);
            case CompressionAlgorithm.Zstd:
                return compressZstd(data);
            case CompressionAlgorithm.Lz4:
                return compressLz4(data);
        }
    }
    
    /// Decompress data
    BuildResult!DecompressionResult decompress(const(ubyte)[] data, CompressionAlgorithm algo) @trusted
    {
        if (data.length == 0)
        {
            return Err!(DecompressionResult, BuildError)(
                Errors.generic("Cannot decompress empty data")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        final switch (algo)
        {
            case CompressionAlgorithm.None:
                return decompressNone(data);
            case CompressionAlgorithm.Zstd:
                return decompressZstd(data);
            case CompressionAlgorithm.Lz4:
                return decompressLz4(data);
        }
    }
    
    /// Check if compression is beneficial (>5% reduction)
    static bool shouldCompress(size_t originalSize, size_t compressedSize) pure @safe nothrow
    {
        if (originalSize == 0)
            return false;
        
        immutable ratio = cast(float)compressedSize / cast(float)originalSize;
        return ratio < 0.95;
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
        // Use external zstd command-line tool for simplicity
        // In production, you'd use zstd D bindings or FFI
        
        try
        {
            import std.process : execute, Config;
            import std.uuid : randomUUID;
            import std.file : tempDir, remove;
            
            // Write input to temp file
            immutable inputPath = buildPath(tempDir(), randomUUID().toString() ~ ".in");
            immutable outputPath = buildPath(tempDir(), randomUUID().toString() ~ ".zst");
            
            scope(exit)
            {
                if (exists(inputPath))
                    remove(inputPath);
                if (exists(outputPath))
                    remove(outputPath);
            }
            
            write(inputPath, data);
            
            // Run zstd
            auto result = execute([
                "zstd",
                "-" ~ _level.to!string,
                "-q",           // Quiet mode
                "-f",           // Force overwrite
                "-o", outputPath,
                inputPath
            ], null, Config.none);
            
            if (result.status != 0)
            {
                // Fallback to no compression
                return compressNone(data);
            }
            
            if (!exists(outputPath))
            {
                return compressNone(data);
            }
            
            auto compressed = cast(ubyte[])read(outputPath);
            
            CompressionResult compResult;
            compResult.data = compressed;
            compResult.originalSize = data.length;
            compResult.compressedSize = compressed.length;
            compResult.ratio = cast(float)compressed.length / cast(float)data.length;
            compResult.algo = CompressionAlgorithm.Zstd;
            
            return Ok!(CompressionResult, BuildError)(compResult);
        }
        catch (Exception e)
        {
            // Fallback to no compression on error
            return compressNone(data);
        }
    }
    
    private BuildResult!CompressionResult compressLz4(const(ubyte)[] data) @trusted
    {
        // Use external lz4 command-line tool
        
        try
        {
            import std.process : execute, Config;
            import std.uuid : randomUUID;
            import std.file : tempDir, remove;
            import std.conv : to;
            
            immutable inputPath = buildPath(tempDir(), randomUUID().toString() ~ ".in");
            immutable outputPath = buildPath(tempDir(), randomUUID().toString() ~ ".lz4");
            
            scope(exit)
            {
                if (exists(inputPath))
                    remove(inputPath);
                if (exists(outputPath))
                    remove(outputPath);
            }
            
            write(inputPath, data);
            
            // Run lz4
            auto result = execute([
                "lz4",
                "-" ~ _level.to!string,
                "-q",
                inputPath,
                outputPath
            ], null, Config.none);
            
            if (result.status != 0 || !exists(outputPath))
            {
                return compressNone(data);
            }
            
            auto compressed = cast(ubyte[])read(outputPath);
            
            CompressionResult compResult;
            compResult.data = compressed;
            compResult.originalSize = data.length;
            compResult.compressedSize = compressed.length;
            compResult.ratio = cast(float)compressed.length / cast(float)data.length;
            compResult.algo = CompressionAlgorithm.Lz4;
            
            return Ok!(CompressionResult, BuildError)(compResult);
        }
        catch (Exception e)
        {
            return compressNone(data);
        }
    }
    
    private BuildResult!DecompressionResult decompressNone(const(ubyte)[] data) pure @trusted
    {
        return Ok!(DecompressionResult, BuildError)(data.dup);
    }
    
    private BuildResult!DecompressionResult decompressZstd(const(ubyte)[] data) @trusted
    {
        try
        {
            import std.process : execute, Config;
            import std.uuid : randomUUID;
            import std.file : tempDir, remove;
            
            immutable inputPath = buildPath(tempDir(), randomUUID().toString() ~ ".zst");
            immutable outputPath = buildPath(tempDir(), randomUUID().toString() ~ ".out");
            
            scope(exit)
            {
                if (exists(inputPath))
                    remove(inputPath);
                if (exists(outputPath))
                    remove(outputPath);
            }
            
            write(inputPath, data);
            
            // Run zstd decompress
            auto result = execute([
                "zstd",
                "-d",           // Decompress
                "-q",
                "-f",
                "-o", outputPath,
                inputPath
            ], null, Config.none);
            
            if (result.status != 0 || !exists(outputPath))
            {
                return Err!(DecompressionResult, BuildError)(
                    Errors.generic("Zstd decompression failed")
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            auto decompressed = cast(ubyte[])read(outputPath);
            return Ok!(DecompressionResult, BuildError)(decompressed);
        }
        catch (Exception e)
        {
            return Err!(DecompressionResult, BuildError)(
                Errors.generic("Zstd decompression failed: " ~ e.msg)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    private BuildResult!DecompressionResult decompressLz4(const(ubyte)[] data) @trusted
    {
        try
        {
            import std.process : execute, Config;
            import std.uuid : randomUUID;
            import std.file : tempDir, remove;
            
            immutable inputPath = buildPath(tempDir(), randomUUID().toString() ~ ".lz4");
            immutable outputPath = buildPath(tempDir(), randomUUID().toString() ~ ".out");
            
            scope(exit)
            {
                if (exists(inputPath))
                    remove(inputPath);
                if (exists(outputPath))
                    remove(outputPath);
            }
            
            write(inputPath, data);
            
            // Run lz4 decompress
            auto result = execute([
                "lz4",
                "-d",
                "-q",
                inputPath,
                outputPath
            ], null, Config.none);
            
            if (result.status != 0 || !exists(outputPath))
            {
                return Err!(DecompressionResult, BuildError)(
                    Errors.generic("LZ4 decompression failed")
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            auto decompressed = cast(ubyte[])read(outputPath);
            return Ok!(DecompressionResult, BuildError)(decompressed);
        }
        catch (Exception e)
        {
            return Err!(DecompressionResult, BuildError)(
                Errors.generic("LZ4 decompression failed: " ~ e.msg)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
}

/// Utility functions for quick compression/decompression
struct CompressUtil
{
    /// Quick compress with default settings
    static BuildResult!(ubyte[]) compress(const(ubyte)[] data) @trusted
    {
        auto compressor = new Compressor();
        auto result = compressor.compress(data);
        
        if (result.isErr)
            return Err!(ubyte[], BuildError)(result.unwrapErr());
        
        return Ok!(ubyte[], BuildError)(result.unwrap().data);
    }
    
    /// Quick decompress
    static BuildResult!(ubyte[]) decompress(const(ubyte)[] data, CompressionAlgorithm algo) @trusted
    {
        auto compressor = new Compressor();
        return compressor.decompress(data, algo);
    }
}


