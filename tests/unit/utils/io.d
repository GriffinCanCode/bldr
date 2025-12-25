module tests.unit.utils.io;

import std.conv : to;
import std.file : tempDir, write, remove, exists;
import std.path : buildPath;
import std.datetime.stopwatch : StopWatch;
import std.stdio : writeln, writefln;

/// Unit tests for async I/O infrastructure

@("async-io-backend-selection")
@system unittest
{
    import infrastructure.utils.io : AsyncIO, AsyncIOCapability;
    
    auto io = AsyncIO.create();
    assert(io.initialized);
    
    // Should select best available backend
    auto cap = io.capability;
    assert(cap == AsyncIOCapability.IoUring || 
           cap == AsyncIOCapability.ThreadPool ||
           cap == AsyncIOCapability.Sync);
    
    writeln("[TEST] AsyncIO backend: ", cap);
    
    io.shutdown();
}

@("batch-hasher-creation")
@system unittest
{
    import infrastructure.utils.io : BatchHasher;
    
    auto hasher = new BatchHasher();
    assert(hasher !is null);
    
    writeln("[TEST] BatchHasher capability: ", hasher.capability);
    
    hasher.shutdown();
}

@("batch-hash-files")
@system unittest
{
    import infrastructure.utils.io : hashFilesAsync, BatchHasher;
    
    // Create temp test files
    immutable testDir = tempDir();
    string[] testFiles;
    
    scope(exit)
    {
        foreach (f; testFiles)
            if (exists(f)) remove(f);
    }
    
    foreach (i; 0 .. 10)
    {
        immutable path = buildPath(testDir, "async_test_" ~ i.to!string ~ ".bin");
        write(path, "test content for file " ~ i.to!string);
        testFiles ~= path;
    }
    
    // Hash files
    auto hashes = hashFilesAsync(testFiles);
    
    assert(hashes.length == testFiles.length);
    foreach (i, h; hashes)
    {
        assert(h.length == 64, "Expected 64-char hex hash, got " ~ h.length.to!string);
    }
    
    writeln("[TEST] Batch hashed ", testFiles.length, " files");
}

@("batch-hasher-stats")
@system unittest
{
    import infrastructure.utils.io : BatchHasher;
    
    auto hasher = new BatchHasher();
    scope(exit) hasher.shutdown();
    
    // Create test files
    immutable testDir = tempDir();
    string[] testFiles;
    
    scope(exit)
    {
        foreach (f; testFiles)
            if (exists(f)) remove(f);
    }
    
    foreach (i; 0 .. 5)
    {
        immutable path = buildPath(testDir, "stats_test_" ~ i.to!string ~ ".bin");
        write(path, "test data " ~ i.to!string);
        testFiles ~= path;
    }
    
    auto _ = hasher.hashFiles(testFiles);
    
    auto stats = hasher.stats;
    assert(stats.filesHashed == 5);
    assert(stats.bytesHashed > 0);
    
    writefln("[TEST] Stats: %d files, %d bytes, %.1f files/batch",
             stats.filesHashed, stats.bytesHashed, stats.avgFilesPerBatch);
}

@("fasthash-async-integration")
@system unittest
{
    import infrastructure.utils.files.hash : FastHash;
    
    // Create test files
    immutable testDir = tempDir();
    string[] testFiles;
    
    scope(exit)
    {
        foreach (f; testFiles)
            if (exists(f)) remove(f);
    }
    
    foreach (i; 0 .. 3)
    {
        immutable path = buildPath(testDir, "fasthash_async_" ~ i.to!string ~ ".bin");
        write(path, "content " ~ i.to!string);
        testFiles ~= path;
    }
    
    // Use FastHash.hashFilesAsync
    auto hashes = FastHash.hashFilesAsync(testFiles);
    
    assert(hashes.length == 3);
    foreach (h; hashes)
        assert(h.length == 64);
    
    writeln("[TEST] FastHash.hashFilesAsync: ", hashes.length, " hashes");
}

@("async-io-missing-files")
@system unittest
{
    import infrastructure.utils.io : hashFilesAsync;
    
    // Hash non-existent files (should return path hashes)
    string[] fakePaths = ["/nonexistent/file1.txt", "/nonexistent/file2.txt"];
    
    auto hashes = hashFilesAsync(fakePaths);
    
    assert(hashes.length == 2);
    foreach (h; hashes)
        assert(h.length == 64);  // Path hash
    
    writeln("[TEST] Missing files hashed as paths");
}

version(linux)
{
    @("uring-availability")
    @system unittest
    {
        import infrastructure.utils.io.uring : isIoUringAvailable;
        
        bool available = isIoUringAvailable();
        writeln("[TEST] io_uring available: ", available);
    }
    
    @("uring-ring-creation")
    @system unittest
    {
        import infrastructure.utils.io.uring : IoUring, isIoUringAvailable;
        
        if (!isIoUringAvailable())
        {
            writeln("[TEST] Skipping io_uring ring test (not available)");
            return;
        }
        
        string err;
        auto ring = IoUring.create(64, 0, &err);
        
        assert(ring !is null, "Failed to create ring: " ~ err);
        assert(ring.valid);
        
        ring.cleanup();
        assert(!ring.valid);
        
        writeln("[TEST] io_uring ring created and cleaned up");
    }
}

