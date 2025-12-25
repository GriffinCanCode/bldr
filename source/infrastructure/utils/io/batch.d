module infrastructure.utils.io.batch;

import infrastructure.utils.io.async;
import infrastructure.utils.crypto.blake3;
import infrastructure.utils.memory.mmap : pageAlign;
import core.atomic;
import std.algorithm : min, map, filter;
import std.array : array;
import std.conv : to;
import std.file : exists, getSize;
import std.range : enumerate;

/// Batch file hasher using async I/O
/// Optimized for cold cache scenarios where I/O is the bottleneck
/// 
/// Design:
/// - Prefetch multiple files in parallel via io_uring
/// - Streaming hash: read + hash overlap
/// - Intelligent batching based on file sizes
/// - Automatic fallback to mmap for large files
final class BatchHasher
{
    private
    {
        AsyncIO _asyncIO;
        ubyte[][] _buffers;
        size_t _bufferSize;
        size_t _maxConcurrent;
        BatchHashStats _stats;
        bool _ownAsyncIO;
    }
    
    /// Configuration for batch hashing
    struct Config
    {
        size_t bufferSize = 256 * 1024;  // 256 KB per buffer
        size_t maxConcurrent = 64;        // Max concurrent reads
        size_t smallFileThreshold = 1024 * 1024;  // 1 MB
        bool useFixedBuffers = true;      // Use registered buffers (zero-copy)
    }
    
    /// Create batch hasher with existing async I/O service
    this(AsyncIO asyncIO, Config config = Config.init) @system
    {
        _asyncIO = asyncIO;
        _bufferSize = config.bufferSize;
        _maxConcurrent = config.maxConcurrent;
        _ownAsyncIO = false;
        
        allocateBuffers(config.maxConcurrent);
    }
    
    /// Create batch hasher with default async I/O
    this(Config config = Config.init) @system
    {
        _asyncIO = AsyncIO.create(cast(uint)config.maxConcurrent);
        _bufferSize = config.bufferSize;
        _maxConcurrent = config.maxConcurrent;
        _ownAsyncIO = true;
        
        allocateBuffers(config.maxConcurrent);
    }
    
    ~this() @system
    {
        shutdown();
    }
    
    /// Shutdown and release resources
    void shutdown() @system
    {
        if (_ownAsyncIO && _asyncIO !is null)
        {
            _asyncIO.shutdown();
            _asyncIO = null;
        }
        
        _buffers = null;
    }
    
    /// Hash multiple files in batch
    /// Returns: array of hashes (empty string for failed reads)
    string[] hashFiles(string[] paths) @system
    {
        if (paths.length == 0) return [];
        
        string[] results;
        results.length = paths.length;
        
        // Filter existing files and collect sizes
        auto validFiles = paths
            .enumerate
            .filter!(p => exists(p[1]))
            .map!(p => FileInfo(p[0], p[1], getSize(p[1])))
            .array;
        
        if (validFiles.length == 0)
        {
            // All files missing - hash their paths
            foreach (i, path; paths)
                results[i] = Blake3.hashHex(path);
            return results;
        }
        
        // Sort by size for better batching (small files first)
        import std.algorithm : sort;
        sort!((a, b) => a.size < b.size)(validFiles);
        
        // Process in batches
        size_t processed = 0;
        while (processed < validFiles.length)
        {
            size_t batchEnd = min(processed + _maxConcurrent, validFiles.length);
            auto batch = validFiles[processed .. batchEnd];
            
            hashBatch(batch, results);
            processed = batchEnd;
            
            _stats.batchesProcessed++;
        }
        
        // Hash paths for missing files
        foreach (i, path; paths)
        {
            if (results[i].length == 0)
                results[i] = Blake3.hashHex(path);
        }
        
        return results;
    }
    
    /// Hash single file with async I/O (for large files)
    string hashFile(string path) @system
    {
        if (!exists(path)) return "";
        
        auto size = getSize(path);
        
        // Small files: use direct hashing
        if (size <= _bufferSize)
        {
            return hashSmallFile(path, size);
        }
        
        // Large files: streaming hash with async prefetch
        return hashLargeFile(path, size);
    }
    
    /// Get statistics
    const(BatchHashStats) stats() const @safe nothrow => _stats;
    
    /// Reset statistics
    void resetStats() @safe nothrow @nogc { _stats = BatchHashStats.init; }
    
    /// Get current async I/O capability
    AsyncIOCapability capability() const @safe nothrow =>
        _asyncIO !is null ? _asyncIO.capability : AsyncIOCapability.Sync;
    
    private:
    
    struct FileInfo
    {
        size_t originalIndex;
        string path;
        size_t size;
    }
    
    void allocateBuffers(size_t count) @system
    {
        _buffers.length = count;
        foreach (ref buf; _buffers)
            buf = new ubyte[_bufferSize];
    }
    
    void hashBatch(FileInfo[] batch, ref string[] results) @system
    {
        if (batch.length == 0) return;
        
        // Prepare read requests
        auto requests = new ReadRequest[batch.length];
        foreach (i, ref file; batch)
        {
            requests[i] = ReadRequest(
                file.path,
                0,  // offset
                cast(uint)min(file.size, _bufferSize),
                file.originalIndex  // userData = original index
            );
        }
        
        // Use appropriate buffers
        auto buffers = _buffers[0 .. batch.length];
        
        // Submit batch reads
        size_t submitted = _asyncIO.submitReads(requests, buffers);
        _stats.filesSubmitted += submitted;
        
        if (submitted == 0) return;
        
        // Wait for completions
        auto completions = _asyncIO.waitCompletions(cast(uint)submitted);
        
        // Process completions and hash
        foreach (ref comp; completions)
        {
            if (!comp.success) continue;
            
            size_t idx = cast(size_t)comp.id;
            size_t originalIdx = batch[idx].originalIndex;
            size_t fileSize = batch[idx].size;
            
            if (comp.result > 0)
            {
                auto data = buffers[idx][0 .. comp.result];
                
                // For complete files, hash directly
                if (fileSize <= _bufferSize)
                {
                    results[originalIdx] = Blake3.hashHex(cast(string)data);
                    _stats.bytesHashed += comp.result;
                    _stats.filesHashed++;
                }
                else
                {
                    // Large file - need streaming hash
                    results[originalIdx] = hashLargeFileWithPrefetch(
                        batch[idx].path, fileSize, data);
                }
            }
        }
    }
    
    string hashSmallFile(string path, size_t size) @system
    {
        import std.file : read;
        
        auto data = cast(ubyte[])read(path);
        _stats.bytesHashed += data.length;
        _stats.filesHashed++;
        
        return Blake3.hashHex(cast(string)data);
    }
    
    string hashLargeFile(string path, size_t size) @system
    {
        import std.stdio : File;
        
        auto hash = Blake3(0);
        auto file = File(path, "rb");
        auto buffer = _buffers[0];
        
        while (!file.eof)
        {
            auto chunk = file.rawRead(buffer);
            if (chunk.length == 0) break;
            
            hash.put(chunk);
            _stats.bytesHashed += chunk.length;
        }
        
        _stats.filesHashed++;
        return hash.finishHex();
    }
    
    string hashLargeFileWithPrefetch(string path, size_t size, const(ubyte)[] prefetched) @system
    {
        import std.stdio : File;
        
        auto hash = Blake3(0);
        
        // Hash prefetched data
        hash.put(prefetched);
        _stats.bytesHashed += prefetched.length;
        
        // Continue reading rest of file
        if (prefetched.length < size)
        {
            auto file = File(path, "rb");
            file.seek(prefetched.length);
            
            auto buffer = _buffers[0];
            while (!file.eof)
            {
                auto chunk = file.rawRead(buffer);
                if (chunk.length == 0) break;
                
                hash.put(chunk);
                _stats.bytesHashed += chunk.length;
            }
        }
        
        _stats.filesHashed++;
        return hash.finishHex();
    }
}

/// Statistics for batch hashing operations
struct BatchHashStats
{
    size_t filesSubmitted;
    size_t filesHashed;
    size_t bytesHashed;
    size_t batchesProcessed;
    
    double avgFilesPerBatch() const pure nothrow @nogc =>
        batchesProcessed > 0 ? cast(double)filesHashed / batchesProcessed : 0.0;
    
    double throughputMBps(double elapsedSecs) const pure nothrow @nogc =>
        elapsedSecs > 0 ? (bytesHashed / (1024.0 * 1024.0)) / elapsedSecs : 0.0;
}

/// Convenience function: hash multiple files with async I/O
/// Uses optimal settings for the platform
string[] hashFilesAsync(string[] paths) @system
{
    auto hasher = new BatchHasher();
    scope(exit) hasher.shutdown();
    
    return hasher.hashFiles(paths);
}

/// Convenience function: hash multiple files with specific config
string[] hashFilesAsync(string[] paths, BatchHasher.Config config) @system
{
    auto hasher = new BatchHasher(config);
    scope(exit) hasher.shutdown();
    
    return hasher.hashFiles(paths);
}

unittest
{
    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    
    // Create test files
    immutable testDir = tempDir();
    string[] testFiles;
    scope(exit) foreach (f; testFiles) if (exists(f)) remove(f);
    
    foreach (i; 0 .. 3)
    {
        immutable path = buildPath(testDir, "batch_test_" ~ i.to!string ~ ".bin");
        write(path, "test content " ~ i.to!string);
        testFiles ~= path;
    }
    
    // Test batch hashing
    auto hashes = hashFilesAsync(testFiles);
    assert(hashes.length == testFiles.length);
    
    foreach (h; hashes)
        assert(h.length == 64);  // 256-bit hash as hex
}

