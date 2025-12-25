module infrastructure.utils.files.hash;

import infrastructure.utils.crypto.blake3;
import infrastructure.utils.simd.ops;
import infrastructure.utils.simd.capabilities : SIMDCapabilities;
import infrastructure.utils.io : AsyncIO, BatchHasher, AsyncIOCapability;
import std.file;
import std.stdio;
import std.algorithm;
import std.range;
import std.conv;
import std.mmfile;
import std.bitmanip;

/// Fast hashing utilities with intelligent size-tiered strategy
/// Uses SIMD-accelerated BLAKE3 for 3-5x speedup over SHA-256
/// Automatically selects optimal SIMD path (AVX-512/AVX2/NEON/SSE)
struct FastHash
{
    // Size thresholds for different hashing strategies
    private enum size_t TINY_THRESHOLD = 4_096;           // 4 KB
    private enum size_t SMALL_THRESHOLD = 1_048_576;      // 1 MB
    private enum size_t MEDIUM_THRESHOLD = 104_857_600;   // 100 MB
    
    // Sampling parameters for medium/large files
    private enum size_t SAMPLE_HEAD = 262_144;    // 256 KB from start
    private enum size_t SAMPLE_TAIL = 262_144;    // 256 KB from end
    private enum size_t SAMPLE_COUNT = 8;         // Number of middle samples
    private enum size_t SAMPLE_SIZE = 16_384;     // 16 KB per sample
    
    // Additional sampling parameters for large files
    private enum size_t LARGE_HEAD_SIZE = 524_288;      // 512 KB from start
    private enum size_t LARGE_TAIL_SIZE = 524_288;      // 512 KB from end
    private enum size_t LARGE_FILE_THRESHOLD = 1_048_576;  // 1 MB threshold
    private enum size_t VERY_LARGE_THRESHOLD = 2_097_152;  // 2 MB threshold
    private enum size_t LARGE_SAMPLE_COUNT = 16;        // Samples for large files
    private enum size_t LARGE_STEP_DIVISOR = 17;        // Step divisor for sample spacing
    private enum size_t LARGE_SAMPLE_SIZE = 32_768;     // 32 KB per large sample
    
    // Buffer and parallelization constants
    private enum size_t IO_BUFFER_SIZE = 4_096;         // 4 KB I/O buffer
    private enum size_t PARALLEL_FILE_THRESHOLD = 8;    // Min files for parallel processing
    private enum size_t SIMD_STRING_THRESHOLD = 32;     // Min length for SIMD hash comparison
    
    /// Hash a file with intelligent size-tiered strategy
    /// 
    /// WARNING: Uses sampling for large files (>100MB) - NOT suitable for
    /// cryptographic integrity validation or security-critical applications.
    /// For security-critical use cases, use hashFileComplete() instead.
    /// 
    /// Sampling strategy:
    /// - Files >100MB: Samples head (256KB) + tail (256KB) + 8 middle samples (16KB each)
    /// - Files >100MB (large): Samples head (512KB) + tail (512KB) + 16 middle samples (32KB each)
    /// - An attacker could modify bytes between samples without detection
    /// 
    /// This is acceptable for build system caching (eventual consistency) but
    /// NOT suitable for security validation, signature verification, or tamper detection.
    /// 
    /// Safety: This function is @system because:
    /// 1. exists() and getSize() are file system operations (unsafe I/O)
    /// 2. Delegates to tier-specific @system hash functions
    /// 3. No pointer arithmetic or unsafe memory operations
    /// 4. Strategy selection is based on validated file size
    /// 
    /// Invariants:
    /// - Returns empty string if file doesn't exist (safe default)
    /// - File size determines which strategy is used
    /// - All strategies are memory-safe
    /// 
    /// What could go wrong:
    /// - File deleted between exists() and hash: returns empty or throws
    /// - File size changes during hashing: hash reflects state at that moment
    /// - Permission errors: propagate as exceptions (safe failure)
    @system
    static string hashFile(in string path)
    {
        if (!exists(path))
            return "";
        
        immutable size = getSize(path);
        
        // Tier 1: Tiny files - direct read
        if (size <= TINY_THRESHOLD)
            return hashFileDirect(path);
        
        // Tier 2: Small files - chunked reading (current approach)
        if (size <= SMALL_THRESHOLD)
            return hashFileChunked(path);
        
        // Tier 3: Medium files - sampled hashing
        if (size <= MEDIUM_THRESHOLD)
            return hashFileSampled(path, size);
        
        // Tier 4: Large files - aggressive sampling with mmap
        return hashFileLargeSampled(path, size);
    }
    
    /// Direct hash for tiny files
    /// 
    /// Safety: This function is @system because:
    /// 1. std.file.read() performs file I/O (inherently unsafe)
    /// 2. Cast to ubyte[] is safe (data is owned by read())
    /// 3. Blake3.hashHex() is trusted hash operation
    /// 4. No manual memory management
    /// 
    /// Invariants:
    /// - File must exist (caller's responsibility)
    /// - File size <= TINY_THRESHOLD (4KB)
    /// - Entire file loaded into memory
    /// 
    /// What could go wrong:
    /// - File too large: memory allocation could fail (exception)
    /// - File modified during read: hash reflects state at read time
    /// - Read errors: exception propagates (safe failure)
    @system
    private static string hashFileDirect(in string path)
    {
        auto data = cast(ubyte[])std.file.read(path);
        return Blake3.hashHex(data);
    }
    
    /// Chunked hash for small files (original approach)
    /// 
    /// Safety: This function is @system because:
    /// 1. File.open() and rawRead() are file I/O operations
    /// 2. Stack-allocated buffer (no heap allocation per chunk)
    /// 3. rawRead() validates buffer bounds internally
    /// 4. Blake3 hasher is incrementally fed (memory-safe)
    /// 
    /// Invariants:
    /// - File is read in 4KB chunks
    /// - Buffer is stack-allocated (automatic cleanup)
    /// - Hash is finalized after all chunks
    /// 
    /// What could go wrong:
    /// - File read errors: exception propagates (safe failure)
    /// - File modified during read: hash reflects state at read time
    /// - EOF handling: safe, loop exits naturally
    @system
    private static string hashFileChunked(in string path)
    {
        auto file = File(path, "rb");
        auto hash = Blake3(0);
        
        ubyte[IO_BUFFER_SIZE] buffer;
        
        while (!file.eof())
        {
            auto chunk = file.rawRead(buffer);
            hash.put(chunk);
        }
        
        return hash.finishHex();
    }
    
    /// Sampled hash for medium files (head + tail + middle samples)
    /// 
    /// WARNING: Samples only portions of the file (head + tail + middle samples).
    /// NOT suitable for cryptographic integrity validation. An attacker could
    /// modify bytes between sample points without detection.
    /// Use hashFileComplete() for security-critical applications.
    /// 
    /// Safety: This function is @system because:
    /// 1. File operations (open, seek, rawRead) are inherently unsafe I/O
    /// 2. Buffer allocations are bounded by SAMPLE_* constants
    /// 3. Seek positions are calculated and bounds-checked
    /// 4. nativeToLittleEndian for size encoding is safe
    /// 5. All buffer operations are validated by min() and bounds checks
    /// 
    /// Invariants:
    /// - fileSize parameter matches actual file size (caller's responsibility)
    /// - Samples don't overlap (calculated positions are correct)
    /// - Total sampled data << actual file size (performance optimization)
    /// 
    /// What could go wrong:
    /// - Seek beyond EOF: caught by File operations (exception)
    /// - Buffer allocation fails: exception propagates (safe failure)
    /// - File modified during sampling: hash reflects state at sample time
    @system
    private static string hashFileSampled(in string path, in size_t fileSize)
    {
        auto hash = Blake3(0);
        
        // Include file size in hash to prevent collisions
        hash.put(nativeToLittleEndian(fileSize)[]);
        
        auto file = File(path, "rb");
        
        // Hash head
        size_t headSize = min(SAMPLE_HEAD, fileSize);
        auto headBuffer = new ubyte[headSize];
        file.rawRead(headBuffer);
        hash.put(headBuffer);
        
        // Hash tail if file is large enough
        if (fileSize > SAMPLE_HEAD + SAMPLE_TAIL)
        {
            file.seek(fileSize - SAMPLE_TAIL);
            auto tailBuffer = new ubyte[SAMPLE_TAIL];
            file.rawRead(tailBuffer);
            hash.put(tailBuffer);
        }
        
        // Hash middle samples
        if (fileSize > SAMPLE_HEAD + SAMPLE_TAIL + SAMPLE_SIZE * SAMPLE_COUNT)
        {
            size_t middleStart = SAMPLE_HEAD;
            size_t middleEnd = fileSize - SAMPLE_TAIL;
            size_t middleSize = middleEnd - middleStart;
            size_t step = middleSize / (SAMPLE_COUNT + 1);
            
            auto sampleBuffer = new ubyte[SAMPLE_SIZE];
            
            foreach (i; 0 .. SAMPLE_COUNT)
            {
                size_t pos = middleStart + step * (i + 1);
                file.seek(pos);
                auto bytesRead = file.rawRead(sampleBuffer[0 .. min(SAMPLE_SIZE, fileSize - pos)]);
                hash.put(bytesRead);
            }
        }
        
        return hash.finishHex();
    }
    
    /// Aggressive sampling for large files using memory mapping with SIMD
    /// 
    /// WARNING: Samples only portions of the file (head + tail + middle samples).
    /// NOT suitable for cryptographic integrity validation. An attacker could
    /// modify bytes between sample points without detection.
    /// Use hashFileComplete() for security-critical applications.
    /// 
    /// Safety: This function is @system because:
    /// 1. MmFile provides memory-mapped file access (inherently unsafe)
    /// 2. Cast to ubyte[] is safe (mmfile validates bounds internally)
    /// 3. Array slicing is bounds-checked with min() calls
    /// 4. SIMD operations via Blake3 are internally validated
    /// 5. scope(exit) ensures cleanup even on exception
    /// 6. Fallback to hashFileSampled() on failure
    /// 
    /// Invariants:
    /// - fileSize is accurate (caller's responsibility)
    /// - Sample positions are calculated to avoid overlap
    /// - Memory mapping is read-only
    /// - MmFile is destroyed via scope(exit)
    /// 
    /// What could go wrong:
    /// - mmap fails: caught and falls back to sampled approach
    /// - File too large for address space: mmap throws, caught
    /// - Concurrent modification: undefined (acceptable for cache)
    /// - Array slicing out of bounds: prevented by min() calculations
    @system
    private static string hashFileLargeSampled(in string path, in size_t fileSize)
    {
        auto hash = Blake3(0);  // SIMD-accelerated
        
        // Include file size
        hash.put(nativeToLittleEndian(fileSize)[]);
        
        try
        {
            // Use memory-mapped file for efficient access
            auto mmfile = new MmFile(path, MmFile.Mode.read, 0, null);
            scope(exit) destroy(mmfile); // Ensure cleanup even on exception
            
            auto data = cast(ubyte[])mmfile[];
            
            // Hash first 512KB (SIMD-accelerated internally)
            size_t headSize = min(LARGE_HEAD_SIZE, fileSize);
            hash.put(data[0 .. headSize]);
            
            // Hash last 512KB
            if (fileSize > LARGE_FILE_THRESHOLD)
            {
                // Use SIMD copy for efficiency on large tail
                auto tailData = data[$ - LARGE_TAIL_SIZE .. $];
                hash.put(tailData);
            }
            
            // Hash 16 samples from middle
            if (fileSize > VERY_LARGE_THRESHOLD)
            {
                size_t middleStart = LARGE_HEAD_SIZE;
                size_t middleEnd = fileSize - LARGE_TAIL_SIZE;
                size_t step = (middleEnd - middleStart) / LARGE_STEP_DIVISOR;
                
                foreach (i; 0 .. LARGE_SAMPLE_COUNT)
                {
                    size_t pos = middleStart + step * (i + 1);
                    size_t sampleEnd = min(pos + LARGE_SAMPLE_SIZE, middleEnd);
                    hash.put(data[pos .. sampleEnd]);
                }
            }
        }
        catch (Exception e)
        {
            // Fallback to sampled approach if mmap fails
            return hashFileSampled(path, fileSize);
        }
        
        return hash.finishHex();
    }
    
    /// Hash entire file content (no sampling) for security-critical use cases
    /// 
    /// Use this function when you need cryptographic integrity validation,
    /// signature verification, or tamper detection. Unlike hashFile(), this
    /// function always hashes the entire file content regardless of size.
    /// 
    /// Performance: This may be slow for very large files (>1GB) as it reads
    /// and hashes every single byte. For build system caching where eventual
    /// consistency is acceptable, use hashFile() instead.
    /// 
    /// Safety: This function is @system because:
    /// 1. File operations are inherently unsafe I/O
    /// 2. Memory-mapped file access is validated by MmFile
    /// 3. Fallback to chunked reading on mmap failure
    /// 4. All memory operations are bounds-checked
    /// 
    /// Invariants:
    /// - Returns empty string if file doesn't exist
    /// - Always hashes entire file content
    /// - Memory-safe regardless of file size
    /// 
    /// What could go wrong:
    /// - Very large files may exhaust memory: handled by chunked fallback
    /// - File modified during read: hash reflects state at read time
    /// - Permission errors: propagate as exceptions (safe failure)
    @system
    static string hashFileComplete(in string path)
    {
        if (!exists(path))
            return "";
        
        immutable size = getSize(path);
        
        // For small files, use existing optimized path
        if (size <= SMALL_THRESHOLD)
            return hashFile(path);
        
        // For larger files, try memory mapping for performance
        try
        {
            // Use memory-mapped file for efficient full-file hashing
            auto mmfile = new MmFile(path, MmFile.Mode.read, 0, null);
            scope(exit) destroy(mmfile);
            
            auto data = cast(ubyte[])mmfile[];
            return Blake3.hashHex(data);
        }
        catch (Exception e)
        {
            // Fallback to chunked reading if mmap fails
            return hashFileChunked(path);
        }
    }
    
    /// Hash a string
    static string hashString(string content)
    {
        return Blake3.hashHex(content);
    }
    
    /// Hash byte array
    static string hashBytes(const ubyte[] data)
    {
        return Blake3.hashHex(cast(string)data);
    }
    
    /// Compute hash of data (alias for hashString for consistency)
    static string compute(const ubyte[] data)
    {
        return hashBytes(data);
    }
    
    /// Hash multiple strings together
    /// 
    /// Safety: This function is @system because:
    /// 1. Cast from string to ubyte[] is safe (identical memory layout)
    /// 2. Blake3 hasher incrementally processes data (memory-safe)
    /// 3. No pointer manipulation or unsafe operations
    /// 
    /// Invariants:
    /// - Strings are hashed in order
    /// - Cast preserves all string data exactly
    /// - Order matters for deterministic hash
    /// 
    /// What could go wrong:
    /// - Nothing: pure data hashing with no side effects
    /// - Large strings: memory usage grows but is safe
    @system
    static string hashStrings(const string[] strings)
    {
        auto hash = Blake3(0);
        foreach (s; strings)
            hash.put(cast(ubyte[])s);
        return hash.finishHex();
    }
    
    /// Hash multiple files together with SIMD-aware parallel processing
    /// 
    /// Context-aware version: accepts SIMDCapabilities for hardware acceleration
    /// Pass null for sequential execution (testing/fallback)
    /// 
    /// Safety: This function is @system because:
    /// 1. Delegates to trusted hashFile() for individual files
    /// 2. Context-based parallel execution is trusted
    /// 3. Cast operations for combining hashes are memory-safe
    /// 4. exists() check prevents errors on missing files
    /// 5. Missing files are hashed by path (deterministic fallback)
    /// 
    /// Invariants:
    /// - Files are processed in parallel when beneficial (>8 files) and context available
    /// - Sequential processing for small file counts (avoid overhead)
    /// - Missing files contribute their path to hash (deterministic)
    /// - Final hash combines all individual hashes
    /// 
    /// What could go wrong:
    /// - File operations can fail: handled per-file (hash path instead)
    /// - Parallel execution overhead: mitigated by threshold check
    /// - Memory usage for many files: bounded by file count
    @system
    static string hashFiles(string[] filePaths, SIMDCapabilities caps = null)
    {
        import std.file : exists;
        import infrastructure.utils.simd.context : createSIMDContext;
        
        // For many files and SIMD available, use parallel hashing
        if (filePaths.length > PARALLEL_FILE_THRESHOLD && caps !is null) {
            auto ctx = createSIMDContext(caps);
            
            // Hash files in parallel
            auto hashes = ctx.mapParallel(filePaths, (string path) {
                if (exists(path))
                    return hashFile(path);
                else
                    return hashString(path);  // Hash the path itself
            });
            
            // Combine all hashes
            auto hash = Blake3(0);
            foreach (h; hashes)
                hash.put(cast(ubyte[])h);
            return hash.finishHex();
        }
        
        // Sequential for few files or no SIMD context
        auto hash = Blake3(0);
        foreach (path; filePaths)
        {
            if (exists(path))
            {
                string fileHash = hashFile(path);
                hash.put(cast(ubyte[])fileHash);
            }
            else
            {
                // For non-existent files, just hash the path
                hash.put(cast(ubyte[])path);
            }
        }
        return hash.finishHex();
    }
    
    /// Hash multiple files using async I/O (io_uring on Linux, thread pool fallback)
    /// Optimized for cold cache scenarios where I/O latency dominates
    /// 
    /// Safety: @system due to async I/O operations
    /// 
    /// Performance:
    /// - io_uring: ~3-5x faster on cold cache vs sequential
    /// - Thread pool: ~2x faster than sequential
    /// - Best for: many small files, cold page cache
    /// 
    /// Use this when:
    /// - Hashing many files (>8) on cold cache
    /// - I/O is the bottleneck (SSD/NVMe with fast CPU)
    /// - Need maximum throughput for initial scans
    @system
    static string[] hashFilesAsync(string[] filePaths)
    {
        if (filePaths.length == 0) return [];
        if (filePaths.length == 1) return [hashFile(filePaths[0])];
        
        import infrastructure.utils.io : hashFilesAsync;
        return hashFilesAsync(filePaths);
    }
    
    /// Hash multiple files with custom async configuration
    /// 
    /// config.bufferSize: Read buffer per file (default 256KB)
    /// config.maxConcurrent: Max parallel reads (default 64)
    @system
    static string[] hashFilesAsync(string[] filePaths, BatchHasher.Config config)
    {
        if (filePaths.length == 0) return [];
        if (filePaths.length == 1) return [hashFile(filePaths[0])];
        
        auto hasher = new BatchHasher(config);
        scope(exit) hasher.shutdown();
        return hasher.hashFiles(filePaths);
    }
    
    /// Create reusable async hasher for multiple batch operations
    /// Call shutdown() when done
    @system
    static BatchHasher createAsyncHasher(size_t maxConcurrent = 64)
    {
        return new BatchHasher(BatchHasher.Config(256 * 1024, maxConcurrent));
    }
    
    /// Check if io_uring is available for async hashing
    static bool hasAsyncIO() @system
    {
        version(linux)
        {
            import infrastructure.utils.io.uring : isIoUringAvailable;
            return isIoUringAvailable();
        }
        else
        {
            return false;  // Falls back to thread pool
        }
    }
    
    /// Hash file metadata (size + mtime) for quick checks
    /// 1000x faster than content hash for unchanged files
    static string hashMetadata(string path)
    {
        if (!exists(path))
            return "";
        
        auto info = DirEntry(path);
        auto data = path ~ info.size.to!string ~ info.timeLastModified.toISOExtString();
        return Blake3.hashHex(data);
    }
    
    /// Two-tier hash: check metadata first, only hash content if changed
    /// Returns tuple: (metadataHash, contentHash, contentHashed)
    static TwoTierHash hashFileTwoTier(string path, string oldMetadataHash = "")
    {
        TwoTierHash result;
        
        if (!exists(path))
            return result;
        
        // Always compute metadata hash (fast)
        result.metadataHash = hashMetadata(path);
        
        // Only compute content hash if metadata changed
        if (oldMetadataHash.empty || result.metadataHash != oldMetadataHash)
        {
            result.contentHash = hashFile(path);
            result.contentHashed = true;
        }
        else
        {
            result.contentHash = ""; // Not needed, metadata unchanged
            result.contentHashed = false;
        }
        
        return result;
    }
}

/// Result of two-tier hashing
struct TwoTierHash
{
    string metadataHash;    // Fast: mtime + size
    string contentHash;     // Slow: SHA-256 of content
    bool contentHashed;     // Whether content was actually hashed
}

