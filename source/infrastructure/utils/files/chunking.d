module infrastructure.utils.files.chunking;

import std.file;
import std.stdio;
import std.algorithm;
import std.range;
import std.conv;
import std.array : appender;
import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import infrastructure.utils.crypto.blake3;
import infrastructure.utils.simd.ops;
import infrastructure.errors : Result, Ok, Err;

/// Content-defined chunking for incremental hashing
/// Uses Rabin fingerprinting to identify chunk boundaries
/// Similar to rsync and git's approach
struct ContentChunker
{
    // Rabin fingerprint parameters
    private enum ulong POLYNOMIAL = 0x3DA3358B4DC173;
    private enum uint WINDOW_SIZE = 64;
    
    // Chunk size constraints
    enum size_t MIN_CHUNK = 2_048;      // 2 KB minimum
    enum size_t AVG_CHUNK = 16_384;     // 16 KB average
    enum size_t MAX_CHUNK = 65_536;     // 64 KB maximum
    
    // Boundary detection mask (determines average chunk size)
    private enum uint MASK_BITS = 14;           // Number of bits for mask
    private enum ulong MASK = (1UL << MASK_BITS) - 1;  // 14 bits = ~16KB average
    
    // Buffer size for chunk hashing
    private enum size_t HASH_BUFFER_SIZE = 4_096;  // 4 KB buffer for hashing chunks
    
    /// Chunk metadata for incremental updates
    struct Chunk
    {
        size_t offset;      // Byte offset in file
        size_t length;      // Chunk length
        string hash;        // BLAKE3 hash of chunk content (SIMD-accelerated)
    }
    
    /// Result of chunking operation
    struct ChunkResult
    {
        Chunk[] chunks;
        string combinedHash;  // Hash of all chunk hashes (file signature)
    }
    
    /// Chunk a file using content-defined boundaries
    @system // File I/O operations and hash computations
    static ChunkResult chunkFile(string path)
    {
        ChunkResult result;
        
        if (!exists(path))
            return result;
        
        auto size = getSize(path);
        if (size == 0)
            return result;
        
        auto file = File(path, "rb");
        
        size_t offset = 0;
        ubyte[MAX_CHUNK] buffer;
        ulong fingerprint = 0;
        size_t chunkStart = 0;
        
        auto combinedHasher = Blake3(0);  // SIMD-accelerated BLAKE3
        
        // Use SIMD rolling hash for window
        ubyte[WINDOW_SIZE] window;
        size_t windowPos = 0;
        
        while (!file.eof())
        {
            auto bytesRead = file.rawRead(buffer);
            if (bytesRead.empty)
                break;
            
            foreach (i, b; bytesRead)
            {
                // Update window for SIMD rolling hash
                window[windowPos] = b;
                windowPos = (windowPos + 1) % WINDOW_SIZE;
                
                // Use SIMD-accelerated rolling hash when window is full
                if (offset + i >= WINDOW_SIZE) {
                    fingerprint = SIMDOps.rollingHash(window, WINDOW_SIZE);
                } else {
                    // Fallback for initial bytes
                fingerprint = ((fingerprint << 1) | (fingerprint >> 63)) ^ b;
                }
                
                size_t currentPos = offset + i;
                size_t chunkLen = currentPos - chunkStart + 1;
                
                // Check for chunk boundary
                bool isBoundary = false;
                
                if (chunkLen >= MIN_CHUNK)
                {
                    // Check if fingerprint matches mask (content-defined boundary)
                    if ((fingerprint & MASK) == 0)
                        isBoundary = true;
                    
                    // Force boundary at max chunk size
                    if (chunkLen >= MAX_CHUNK)
                        isBoundary = true;
                }
                
                if (isBoundary)
                {
                    // Create chunk
                    Chunk chunk;
                    chunk.offset = chunkStart;
                    chunk.length = chunkLen;
                    chunk.hash = hashChunk(file, chunkStart, chunkLen);
                    
                    result.chunks ~= chunk;
                    combinedHasher.put(cast(ubyte[])chunk.hash);
                    
                    chunkStart = currentPos + 1;
                    fingerprint = 0;
                }
            }
            
            offset += bytesRead.length;
        }
        
        // Handle final chunk if there's remaining data
        if (chunkStart < offset)
        {
            Chunk chunk;
            chunk.offset = chunkStart;
            chunk.length = offset - chunkStart;
            chunk.hash = hashChunk(file, chunkStart, chunk.length);
            
            result.chunks ~= chunk;
            combinedHasher.put(cast(ubyte[])chunk.hash);
        }
        
        result.combinedHash = combinedHasher.finishHex();
        return result;
    }
    
    /// Hash a specific chunk of a file using SIMD-accelerated BLAKE3
    @system // File I/O and hashing operations
    private static string hashChunk(ref File file, size_t offset, size_t length)
    {
        file.seek(offset);
        
        auto hasher = Blake3(0);  // SIMD-accelerated BLAKE3
        ubyte[HASH_BUFFER_SIZE] buffer;
        size_t remaining = length;
        
        while (remaining > 0)
        {
            size_t toRead = min(buffer.length, remaining);
            auto chunk = file.rawRead(buffer[0 .. toRead]);
            hasher.put(chunk);
            remaining -= chunk.length;
        }
        
        return hasher.finishHex();
    }
    
    /// Compare two chunk results and identify changed chunks (SIMD-accelerated)
    static size_t[] findChangedChunks(ChunkResult oldChunks, ChunkResult newChunks)
    {
        size_t[] changedIndices;
        
        // Simple comparison - in practice you'd use a more sophisticated algorithm
        size_t maxLen = max(oldChunks.chunks.length, newChunks.chunks.length);
        
        foreach (i; 0 .. maxLen)
        {
            if (i >= oldChunks.chunks.length || i >= newChunks.chunks.length)
            {
                changedIndices ~= i;
            }
            else if (oldChunks.chunks[i].hash != newChunks.chunks[i].hash)
            {
                changedIndices ~= i;
            }
        }
        
        return changedIndices;
    }
    
    /// Serialize chunk metadata for caching
    @system // Array operations and casts
    static ubyte[] serialize(ChunkResult result)
    {
        auto buffer = appender!(ubyte[]);
        
        // Write number of chunks
        buffer.put(nativeToBigEndian(cast(uint)result.chunks.length)[]);
        
        // Write combined hash
        buffer.put(nativeToBigEndian(cast(uint)result.combinedHash.length)[]);
        buffer.put(cast(ubyte[])result.combinedHash);
        
        // Write each chunk
        foreach (chunk; result.chunks)
        {
            buffer.put(nativeToBigEndian(cast(ulong)chunk.offset)[]);
            buffer.put(nativeToBigEndian(cast(ulong)chunk.length)[]);
            buffer.put(nativeToBigEndian(cast(uint)chunk.hash.length)[]);
            buffer.put(cast(ubyte[])chunk.hash);
        }
        
        return buffer.data;
    }
    
    /// Deserialize chunk metadata
    @system // Array slicing and casts
    static ChunkResult deserialize(ubyte[] data)
    {
        ChunkResult result;
        size_t offset = 0;
        
        if (data.length < 4)
            return result;
        
        // Read number of chunks
        ubyte[4] countBytes = data[offset .. offset + 4][0 .. 4];
        auto count = bigEndianToNative!uint(countBytes);
        offset += 4;
        
        // Read combined hash
        ubyte[4] hashLenBytes = data[offset .. offset + 4][0 .. 4];
        auto hashLen = bigEndianToNative!uint(hashLenBytes);
        offset += 4;
        
        result.combinedHash = cast(string)data[offset .. offset + hashLen];
        offset += hashLen;
        
        // Read chunks
        foreach (_; 0 .. count)
        {
            Chunk chunk;
            
            ubyte[8] offsetBytes = data[offset .. offset + 8][0 .. 8];
            chunk.offset = bigEndianToNative!ulong(offsetBytes);
            offset += 8;
            
            ubyte[8] lengthBytes = data[offset .. offset + 8][0 .. 8];
            chunk.length = bigEndianToNative!ulong(lengthBytes);
            offset += 8;
            
            ubyte[4] chunkHashLenBytes = data[offset .. offset + 4][0 .. 4];
            auto chunkHashLen = bigEndianToNative!uint(chunkHashLenBytes);
            offset += 4;
            
            chunk.hash = cast(string)data[offset .. offset + chunkHashLen];
            offset += chunkHashLen;
            
            result.chunks ~= chunk;
        }
        
        return result;
    }
}

/// Chunk manifest for tracking remote chunks
struct ChunkManifest
{
    string fileHash;           // Hash of the entire file
    ContentChunker.Chunk[] chunks;            // List of chunks
    size_t totalSize;          // Total file size
    
    /// Check if two manifests have common chunks (for deduplication)
    size_t[] findCommonChunks(ref ChunkManifest other) const pure @safe
    {
        size_t[] commonIndices;
        
        foreach (i, chunk; chunks)
        {
            foreach (otherChunk; other.chunks)
            {
                if (chunk.hash == otherChunk.hash)
                {
                    commonIndices ~= i;
                    break;
                }
            }
        }
        
        return commonIndices;
    }
    
    /// Calculate how much data would be saved by chunk deduplication
    size_t calculateDedupSavings(ref ChunkManifest other) const pure @safe
    {
        size_t savings = 0;
        
        foreach (i, chunk; chunks)
        {
            foreach (otherChunk; other.chunks)
            {
                if (chunk.hash == otherChunk.hash)
                {
                    savings += chunk.length;
                    break;
                }
            }
        }
        
        return savings;
    }
}

/// Network transfer interface for chunk-based uploads/downloads
struct ChunkTransfer
{
    /// Upload only changed chunks to remote store
    /// Returns: Number of chunks uploaded, bytes transferred
    @system
    static Result!(TransferStats, string) uploadChangedChunks(
        string filePath,
        ChunkManifest localManifest,
        ChunkManifest remoteManifest,
        scope bool delegate(string chunkHash, const(ubyte)[] data) @trusted uploadChunk
    )
    {
        TransferStats stats;
        stats.totalChunks = localManifest.chunks.length;
        
        // Find chunks that differ
        auto changedIndices = ContentChunker.findChangedChunks(
            ContentChunker.ChunkResult(remoteManifest.chunks, remoteManifest.fileHash),
            ContentChunker.ChunkResult(localManifest.chunks, localManifest.fileHash)
        );
        
        stats.changedChunks = changedIndices.length;
        
        if (!exists(filePath))
            return Err!(TransferStats, string)("File not found: " ~ filePath);
        
        auto file = File(filePath, "rb");
        
        // Upload only changed chunks
        foreach (idx; changedIndices)
        {
            if (idx >= localManifest.chunks.length)
                continue;
            
            auto chunk = localManifest.chunks[idx];
            
            // Read chunk data
            file.seek(chunk.offset);
            ubyte[] chunkData = new ubyte[chunk.length];
            auto readData = file.rawRead(chunkData);
            
            if (readData.length != chunk.length)
            {
                return Err!(TransferStats, string)(
                    "Failed to read complete chunk at offset " ~ chunk.offset.to!string
                );
            }
            
            // Upload chunk
            if (!uploadChunk(chunk.hash, chunkData))
            {
                return Err!(TransferStats, string)(
                    "Failed to upload chunk: " ~ chunk.hash
                );
            }
            
            stats.bytesTransferred += chunk.length;
            stats.chunksTransferred++;
        }
        
        stats.bytesSaved = localManifest.totalSize - stats.bytesTransferred;
        
        return Ok!(TransferStats, string)(stats);
    }
    
    /// Download chunks and reconstruct file
    /// Returns: Number of chunks downloaded, bytes transferred
    @system
    static Result!(TransferStats, string) downloadChunks(
        string outputPath,
        ChunkManifest manifest,
        scope Result!(ubyte[], string) delegate(string chunkHash) @trusted downloadChunk
    )
    {
        TransferStats stats;
        stats.totalChunks = manifest.chunks.length;
        
        // Create output file
        auto file = File(outputPath, "wb");
        
        // Download and write each chunk
        foreach (chunk; manifest.chunks)
        {
            auto result = downloadChunk(chunk.hash);
            if (result.isErr)
            {
                return Err!(TransferStats, string)(
                    "Failed to download chunk: " ~ chunk.hash ~ " - " ~ result.unwrapErr()
                );
            }
            
            auto chunkData = result.unwrap();
            
            // Verify chunk size
            if (chunkData.length != chunk.length)
            {
                return Err!(TransferStats, string)(
                    "Chunk size mismatch: expected " ~ chunk.length.to!string ~
                    ", got " ~ chunkData.length.to!string
                );
            }
            
            // Verify chunk hash
            auto hasher = Blake3(0);
            hasher.put(chunkData);
            auto actualHash = hasher.finishHex();
            
            if (actualHash != chunk.hash)
            {
                return Err!(TransferStats, string)(
                    "Chunk hash mismatch: expected " ~ chunk.hash ~
                    ", got " ~ actualHash
                );
            }
            
            // Write chunk to file
            file.rawWrite(chunkData);
            
            stats.bytesTransferred += chunkData.length;
            stats.chunksTransferred++;
        }
        
        stats.totalChunks = manifest.chunks.length;
        stats.changedChunks = manifest.chunks.length;
        
        return Ok!(TransferStats, string)(stats);
    }
    
    /// Upload entire file using chunks (initial upload)
    /// Returns: Manifest for the uploaded file
    @system
    static Result!(ChunkManifest, string) uploadFileChunked(
        string filePath,
        scope bool delegate(string chunkHash, const(ubyte)[] data) @trusted uploadChunk
    )
    {
        // First, chunk the file
        auto chunkResult = ContentChunker.chunkFile(filePath);
        if (chunkResult.chunks.length == 0)
            return Err!(ChunkManifest, string)("Failed to chunk file: " ~ filePath);
        
        auto file = File(filePath, "rb");
        auto fileSize = getSize(filePath);
        
        // Upload all chunks
        foreach (chunk; chunkResult.chunks)
        {
            file.seek(chunk.offset);
            ubyte[] chunkData = new ubyte[chunk.length];
            auto readData = file.rawRead(chunkData);
            
            if (readData.length != chunk.length)
            {
                return Err!(ChunkManifest, string)(
                    "Failed to read chunk at offset " ~ chunk.offset.to!string
                );
            }
            
            if (!uploadChunk(chunk.hash, chunkData))
            {
                return Err!(ChunkManifest, string)(
                    "Failed to upload chunk: " ~ chunk.hash
                );
            }
        }
        
        // Build manifest
        ChunkManifest manifest;
        manifest.fileHash = chunkResult.combinedHash;
        manifest.chunks = chunkResult.chunks;
        manifest.totalSize = fileSize;
        
        return Ok!(ChunkManifest, string)(manifest);
    }
}

/// Transfer statistics
struct TransferStats
{
    size_t totalChunks;        // Total number of chunks
    size_t changedChunks;      // Number of changed chunks
    size_t chunksTransferred;  // Number of chunks actually transferred
    size_t bytesTransferred;   // Bytes transferred over network
    size_t bytesSaved;         // Bytes saved by deduplication
    
    /// Calculate transfer efficiency (0.0 to 1.0)
    double efficiency() const pure @safe nothrow
    {
        if (totalChunks == 0)
            return 1.0;
        
        return 1.0 - (cast(double)chunksTransferred / cast(double)totalChunks);
    }
    
    /// Get percentage of data saved
    double savingsPercent() const pure @safe nothrow
    {
        immutable total = bytesTransferred + bytesSaved;
        if (total == 0)
            return 0.0;
        
        return (cast(double)bytesSaved / cast(double)total) * 100.0;
    }
}

/// Rolling hash implementation (Rabin fingerprint variant)
struct RollingHash
{
    private ulong hash;
    private ulong polynomial;
    
    this(ulong poly)
    {
        this.polynomial = poly;
        this.hash = 0;
    }
    
    /// Update hash with new byte
    void update(ubyte b)
    {
        hash = ((hash << 1) | (hash >> 63)) ^ (b * polynomial);
    }
    
    /// Get current hash value
    ulong value() const
    {
        return hash;
    }
    
    /// Reset hash
    void reset()
    {
        hash = 0;
    }
}

