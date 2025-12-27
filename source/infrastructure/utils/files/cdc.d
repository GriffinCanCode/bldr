module infrastructure.utils.files.cdc;

import std.algorithm : min, max;
import std.array : appender;
import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.file : exists, getSize, read;
import std.stdio : File;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;
import infrastructure.errors : Result, Ok, Err, BuildResult, BuildError, VoidBuildResult;

/// FastCDC - Content-Defined Chunking using Gear rolling hash
/// 2-3x faster than Rabin fingerprinting with comparable deduplication
/// 
/// Key features:
/// - Gear-based rolling hash (single multiply + XOR per byte)
/// - Normalized chunking for consistent boundaries
/// - Configurable size parameters for different workloads
/// - BLAKE3 chunk hashing for integrity
struct FastCDC
{
    /// Chunk size configuration for different workloads
    struct Config
    {
        size_t minSize;   // Minimum chunk size
        size_t avgSize;   // Target average chunk size
        size_t maxSize;   // Maximum chunk size
        
        /// Default for build artifacts (2KB-16KB-64KB)
        static Config artifact() pure @safe => Config(2048, 16384, 65536);
        
        /// Large binaries (8KB-64KB-256KB) - better for 100MB+ files
        static Config large() pure @safe => Config(8192, 65536, 262144);
        
        /// Small files (1KB-4KB-16KB) - finer granularity
        static Config small() pure @safe => Config(1024, 4096, 16384);
        
        /// Compute mask bits from average size (log2)
        uint maskBits() const pure @safe nothrow @nogc
        {
            uint bits = 0;
            size_t v = avgSize;
            while (v > 1) { v >>= 1; bits++; }
            return bits;
        }
    }
    
    /// Content-defined chunk with metadata
    struct Chunk
    {
        size_t offset;   // Byte offset in source
        size_t length;   // Chunk length in bytes
        ubyte[32] hash;  // BLAKE3 hash (256-bit)
        
        /// Hash as hex string
        string hashHex() const @system => toHexString(hash[]);
        
        /// Equality based on content hash
        bool opEquals(ref const Chunk other) const pure @safe => hash == other.hash;
    }
    
    /// Chunking result with manifest
    struct ChunkResult
    {
        Chunk[] chunks;           // All chunks
        ubyte[32] combinedHash;   // Merkle-style root hash
        size_t totalSize;         // Total bytes chunked
        
        /// Combined hash as hex string
        string combinedHashHex() const @system => toHexString(combinedHash[]);
        
        /// Average chunk size
        size_t avgChunkSize() const pure @safe nothrow @nogc
            => chunks.length > 0 ? totalSize / chunks.length : 0;
        
        /// Find indices of chunks not in other result (for delta transfer)
        size_t[] findMissing(ref const ChunkResult other) const pure @safe
        {
            // Build hash set of other chunks
            bool[ubyte[32]] otherHashes;
            foreach (ref c; other.chunks) otherHashes[c.hash] = true;
            
            size_t[] missing;
            foreach (i, ref c; chunks)
                if (c.hash !in otherHashes) missing ~= i;
            return missing;
        }
    }
    
    private Config config;
    private ulong[] gearTable;
    private ulong mask;
    private ulong maskS;  // Small mask for minimum boundary
    private ulong maskL;  // Large mask for normalized chunking
    
    /// Initialize with configuration
    @system
    this(Config cfg)
    {
        config = cfg;
        gearTable = buildGearTable();
        
        // Gear mask for boundary detection
        immutable bits = cfg.maskBits();
        mask = (1UL << bits) - 1;
        maskS = (1UL << (bits + 2)) - 1;  // Stricter for small chunks
        maskL = (1UL << (bits - 2)) - 1;  // Relaxed for large chunks
    }
    
    /// Default constructor with artifact config
    @system
    static FastCDC create() => FastCDC(Config.artifact());
    
    /// Chunk file using FastCDC algorithm
    @system
    ChunkResult chunkFile(string path)
    {
        ChunkResult result;
        
        if (!exists(path)) return result;
        
        immutable fileSize = getSize(path);
        if (fileSize == 0) return result;
        
        result.totalSize = fileSize;
        auto file = File(path, "rb");
        auto chunks = appender!(Chunk[])();
        auto combinedHasher = Blake3(0);
        
        size_t offset = 0;
        ubyte[] buffer = new ubyte[config.maxSize];
        
        while (offset < fileSize)
        {
            immutable remaining = fileSize - offset;
            immutable toRead = min(config.maxSize, remaining);
            auto data = file.rawRead(buffer[0 .. toRead]);
            
            if (data.length == 0) break;
            
            // Find chunk boundary using gear hash
            immutable chunkLen = findBoundary(data, remaining);
            
            // Hash the chunk
            auto hasher = Blake3(0);
            hasher.put(data[0 .. chunkLen]);
            
            Chunk chunk;
            chunk.offset = offset;
            chunk.length = chunkLen;
            chunk.hash = hasher.finish(32)[0 .. 32];
            
            chunks ~= chunk;
            combinedHasher.put(chunk.hash[]);
            
            // Seek to next chunk start
            offset += chunkLen;
            if (chunkLen < data.length)
                file.seek(offset);
        }
        
        result.chunks = chunks[];
        result.combinedHash = combinedHasher.finish(32)[0 .. 32];
        return result;
    }
    
    /// Chunk in-memory data
    @system
    ChunkResult chunkData(const(ubyte)[] data)
    {
        ChunkResult result;
        
        if (data.length == 0) return result;
        
        result.totalSize = data.length;
        auto chunks = appender!(Chunk[])();
        auto combinedHasher = Blake3(0);
        
        size_t offset = 0;
        while (offset < data.length)
        {
            immutable remaining = data.length - offset;
            auto slice = data[offset .. min(offset + config.maxSize, data.length)];
            immutable chunkLen = findBoundary(slice, remaining);
            
            auto hasher = Blake3(0);
            hasher.put(data[offset .. offset + chunkLen]);
            
            Chunk chunk;
            chunk.offset = offset;
            chunk.length = chunkLen;
            chunk.hash = hasher.finish(32)[0 .. 32];
            
            chunks ~= chunk;
            combinedHasher.put(chunk.hash[]);
            offset += chunkLen;
        }
        
        result.chunks = chunks[];
        result.combinedHash = combinedHasher.finish(32)[0 .. 32];
        return result;
    }
    
    /// Find chunk boundary using normalized chunking
    /// Returns chunk length
    private size_t findBoundary(const(ubyte)[] data, size_t remaining) const pure @safe nothrow @nogc
    {
        immutable dataLen = data.length;
        
        // Handle edge cases
        if (dataLen <= config.minSize) return dataLen;
        if (remaining <= config.maxSize) return min(dataLen, remaining);
        
        // Normalized chunking: use different masks based on position
        // This improves chunk size distribution
        immutable center = config.avgSize;
        
        ulong fingerprint = 0;
        size_t i = config.minSize;
        
        // Phase 1: Up to average size, use stricter mask (fewer boundaries)
        while (i < min(center, dataLen))
        {
            fingerprint = (fingerprint << 1) + gearTable[data[i]];
            if ((fingerprint & maskS) == 0) return i + 1;
            i++;
        }
        
        // Phase 2: Average to max, use relaxed mask (more boundaries)
        while (i < min(config.maxSize, dataLen))
        {
            fingerprint = (fingerprint << 1) + gearTable[data[i]];
            if ((fingerprint & maskL) == 0) return i + 1;
            i++;
        }
        
        // Phase 3: Force boundary at max size
        return min(config.maxSize, dataLen);
    }
    
    /// Build gear hash lookup table (256 pseudo-random 64-bit values)
    private static ulong[] buildGearTable() pure @safe
    {
        // Deterministic PRNG seeded for reproducibility
        // Uses SplitMix64 algorithm
        ulong[] table = new ulong[256];
        ulong state = 0x5851F42D4C957F2D;  // Golden ratio seed
        
        foreach (ref t; table)
        {
            state += 0x9E3779B97F4A7C15;
            ulong z = state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
            t = z ^ (z >> 31);
        }
        
        return table;
    }
}

/// Chunk manifest for storage and transfer
/// Stores metadata about chunked blob without chunk contents
struct ChunkManifest
{
    ubyte[32] blobHash;    // Original blob hash
    ubyte[32] rootHash;    // Merkle root of chunks
    size_t totalSize;      // Original size
    size_t chunkCount;     // Number of chunks
    ChunkRef[] refs;       // Chunk references
    
    /// Chunk reference (metadata only)
    struct ChunkRef
    {
        size_t offset;
        size_t length;
        ubyte[32] hash;
    }
    
    /// Create from ChunkResult
    static ChunkManifest fromResult(ref const FastCDC.ChunkResult result, const(ubyte)[] blobHash) @safe
    {
        ChunkManifest m;
        m.rootHash = result.combinedHash;
        m.totalSize = result.totalSize;
        m.chunkCount = result.chunks.length;
        m.blobHash = blobHash[0 .. 32];
        
        m.refs = new ChunkRef[result.chunks.length];
        foreach (i, ref c; result.chunks)
        {
            m.refs[i].offset = c.offset;
            m.refs[i].length = c.length;
            m.refs[i].hash = c.hash;
        }
        return m;
    }
    
    /// Serialize manifest to bytes
    @system
    ubyte[] serialize() const
    {
        auto buf = appender!(ubyte[])();
        
        // Header
        buf ~= blobHash[];
        buf ~= rootHash[];
        buf ~= nativeToBigEndian(cast(ulong)totalSize)[];
        buf ~= nativeToBigEndian(cast(uint)chunkCount)[];
        
        // Chunk refs
        foreach (ref r; refs)
        {
            buf ~= nativeToBigEndian(cast(ulong)r.offset)[];
            buf ~= nativeToBigEndian(cast(ulong)r.length)[];
            buf ~= r.hash[];
        }
        
        return buf[];
    }
    
    /// Deserialize from bytes
    @system
    static Result!(ChunkManifest, string) deserialize(const(ubyte)[] data)
    {
        if (data.length < 76) // 32 + 32 + 8 + 4 = 76 bytes header
            return Err!(ChunkManifest, string)("Manifest too short");
        
        ChunkManifest m;
        size_t pos = 0;
        
        m.blobHash = data[pos .. pos + 32][0 .. 32]; pos += 32;
        m.rootHash = data[pos .. pos + 32][0 .. 32]; pos += 32;
        m.totalSize = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
        m.chunkCount = bigEndianToNative!uint(data[pos .. pos + 4][0 .. 4]); pos += 4;
        
        // Each ref is 8 + 8 + 32 = 48 bytes
        if (data.length < pos + m.chunkCount * 48)
            return Err!(ChunkManifest, string)("Truncated chunk refs");
        
        m.refs = new ChunkManifest.ChunkRef[m.chunkCount];
        foreach (ref r; m.refs)
        {
            r.offset = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
            r.length = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
            r.hash = data[pos .. pos + 32][0 .. 32]; pos += 32;
        }
        
        return Ok!(ChunkManifest, string)(m);
    }
    
    /// Calculate transfer savings given known chunks
    DeltaStats calculateDelta(const(ubyte[32])[] knownChunks) const pure @safe
    {
        // Build known hash set
        bool[ubyte[32]] known;
        foreach (h; knownChunks) known[h] = true;
        
        DeltaStats stats;
        stats.totalChunks = refs.length;
        stats.totalBytes = totalSize;
        
        foreach (ref r; refs)
        {
            if (r.hash in known)
            {
                stats.reusedChunks++;
                stats.reusedBytes += r.length;
            }
            else
            {
                stats.newChunks++;
                stats.newBytes += r.length;
            }
        }
        
        return stats;
    }
}

/// Delta transfer statistics
struct DeltaStats
{
    size_t totalChunks;
    size_t totalBytes;
    size_t reusedChunks;
    size_t reusedBytes;
    size_t newChunks;
    size_t newBytes;
    
    /// Percentage of bytes saved
    double savingsPercent() const pure @safe nothrow @nogc
        => totalBytes > 0 ? 100.0 * reusedBytes / totalBytes : 0.0;
    
    /// Percentage of chunks reused
    double reusePercent() const pure @safe nothrow @nogc
        => totalChunks > 0 ? 100.0 * reusedChunks / totalChunks : 0.0;
}

/// Threshold for automatic chunking (100 MB)
enum size_t LARGE_ARTIFACT_THRESHOLD = 100 * 1024 * 1024;

/// Check if data should use chunked storage
bool shouldChunk(size_t size) pure @safe nothrow @nogc => size >= LARGE_ARTIFACT_THRESHOLD;

