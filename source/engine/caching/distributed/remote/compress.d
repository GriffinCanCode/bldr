module engine.caching.distributed.remote.compress;

import std.algorithm : min;
import infrastructure.utils.compression.compress;
import infrastructure.errors;

/// Compression strategy for remote cache artifacts
enum CompressionStrategy
{
    None,       // No compression
    Fast,       // LZ4 - fastest, lower ratio
    Balanced,   // Zstd level 3 - good balance
    Best        // Zstd level 9 - best ratio
}

/// Streaming compression for artifacts
/// Uses heuristic to detect if compression is beneficial
final class ArtifactCompressor
{
    private CompressionStrategy strategy;
    private CompressionAlgorithm algorithm;
    private CompressionLevel level;
    
    /// Constructor
    this(CompressionStrategy strategy = CompressionStrategy.Balanced) @safe
    {
        this.strategy = strategy;
        
        final switch (strategy)
        {
            case CompressionStrategy.None:
                this.algorithm = CompressionAlgorithm.None;
                this.level = 0;
                break;
            case CompressionStrategy.Fast:
                this.algorithm = CompressionAlgorithm.Lz4;
                this.level = StandardLevel.Fast;
                break;
            case CompressionStrategy.Balanced:
                this.algorithm = CompressionAlgorithm.Zstd;
                this.level = StandardLevel.Default;
                break;
            case CompressionStrategy.Best:
                this.algorithm = CompressionAlgorithm.Zstd;
                this.level = StandardLevel.Better;
                break;
        }
    }
    
    /// Compress artifact with automatic compressibility detection
    BuildResult!CompressedArtifact compress(const(ubyte)[] data) @trusted
    {
        if (strategy == CompressionStrategy.None || data.length == 0)
        {
            CompressedArtifact artifact;
            artifact.data = cast(ubyte[])data;
            artifact.originalSize = data.length;
            artifact.compressedSize = data.length;
            artifact.compressed = false;
            artifact.algorithm = CompressionAlgorithm.None;
            
            return Ok!(CompressedArtifact, BuildError)(artifact);
        }
        
        // Check if data is likely compressible
        if (!isCompressible(data))
        {
            CompressedArtifact artifact;
            artifact.data = cast(ubyte[])data;
            artifact.originalSize = data.length;
            artifact.compressedSize = data.length;
            artifact.compressed = false;
            artifact.algorithm = CompressionAlgorithm.None;
            
            return Ok!(CompressedArtifact, BuildError)(artifact);
        }
        
        // Attempt compression
        auto compressor = new Compressor(algorithm, level);
        auto result = compressor.compress(data);
        
        if (result.isErr)
        {
            // Fall back to uncompressed
            CompressedArtifact artifact;
            artifact.data = cast(ubyte[])data;
            artifact.originalSize = data.length;
            artifact.compressedSize = data.length;
            artifact.compressed = false;
            artifact.algorithm = CompressionAlgorithm.None;
            
            return Ok!(CompressedArtifact, BuildError)(artifact);
        }
        
        auto compResult = result.unwrap();
        
        // Only use compression if beneficial (>5% reduction)
        if (!Compressor.shouldCompress(compResult.originalSize, compResult.compressedSize))
        {
            CompressedArtifact artifact;
            artifact.data = cast(ubyte[])data;
            artifact.originalSize = data.length;
            artifact.compressedSize = data.length;
            artifact.compressed = false;
            artifact.algorithm = CompressionAlgorithm.None;
            
            return Ok!(CompressedArtifact, BuildError)(artifact);
        }
        
        // Use compressed version
        CompressedArtifact artifact;
        artifact.data = compResult.data;
        artifact.originalSize = compResult.originalSize;
        artifact.compressedSize = compResult.compressedSize;
        artifact.compressed = true;
        artifact.algorithm = compResult.algo;
        
        return Ok!(CompressedArtifact, BuildError)(artifact);
    }
    
    /// Decompress artifact
    BuildResult!(ubyte[]) decompress(const(ubyte)[] data, CompressionAlgorithm algo) @trusted
    {
        if (algo == CompressionAlgorithm.None)
            return Ok!(ubyte[], BuildError)(cast(ubyte[])data);
        
        auto compressor = new Compressor();
        return compressor.decompress(data, algo);
    }
    
    /// Detect compression algorithm from magic bytes
    static CompressionAlgorithm detectAlgorithm(const(ubyte)[] data) pure @safe nothrow @nogc
    {
        if (data.length < 4)
            return CompressionAlgorithm.None;
        
        // Zstd magic number: 0x28 0xB5 0x2F 0xFD
        if (data[0] == 0x28 && data[1] == 0xB5 && data[2] == 0x2F && data[3] == 0xFD)
            return CompressionAlgorithm.Zstd;
        
        // LZ4 magic number: 0x04 0x22 0x4D 0x18
        if (data[0] == 0x04 && data[1] == 0x22 && data[2] == 0x4D && data[3] == 0x18)
            return CompressionAlgorithm.Lz4;
        
        return CompressionAlgorithm.None;
    }
    
    /// Check if data is likely compressible using entropy heuristic
    private static bool isCompressible(const(ubyte)[] data) pure @safe nothrow @nogc
    {
        // Sample first 4KB to detect patterns
        immutable sampleSize = min(data.length, 4096);
        
        // Count byte frequency
        size_t[256] histogram;
        foreach (b; data[0 .. sampleSize])
            histogram[b]++;
        
        // Calculate Shannon entropy
        float entropy = 0.0;
        foreach (count; histogram)
        {
            if (count == 0)
                continue;
            
            immutable p = cast(float)count / cast(float)sampleSize;
            import std.math : log2;
            entropy -= p * log2(p);
        }
        
        // High entropy (>7.0) suggests already compressed or random data
        // Low entropy (<6.0) suggests compressible text/binary
        return entropy < 7.0;
    }
}

/// Compressed artifact result
struct CompressedArtifact
{
    ubyte[] data;
    size_t originalSize;
    size_t compressedSize;
    bool compressed;
    CompressionAlgorithm algorithm;
    
    /// Get compression ratio
    float ratio() const pure @safe nothrow @nogc
    {
        if (originalSize == 0)
            return 1.0;
        
        return cast(float)compressedSize / cast(float)originalSize;
    }
    
    /// Get bytes saved
    size_t bytesSaved() const pure @safe nothrow @nogc
    {
        if (compressedSize >= originalSize)
            return 0;
        
        return originalSize - compressedSize;
    }
}

