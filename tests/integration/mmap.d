module tests.integration.mmap;

import infrastructure.utils.memory.mmap;
import infrastructure.utils.files.hash : FastHash;
import std.file : tempDir, write, read, remove, exists, mkdirRecurse, rmdirRecurse, getSize;
import std.path : buildPath;
import std.conv : to;
import std.algorithm : all, map, equal;
import std.range : iota;
import std.array : array;

/// Integration test: CAS blob store with mmap
@system unittest
{
    import engine.caching.storage.cas : ContentAddressableStorage;
    
    immutable testDir = buildPath(tempDir(), "mmap_cas_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    
    // Test small blob (should NOT use mmap)
    ubyte[1024] smallData;
    foreach (i, ref b; smallData) b = cast(ubyte)(i & 0xFF);
    
    auto smallResult = cas.putBlob(smallData);
    assert(smallResult.isOk, "Failed to store small blob");
    auto smallHash = smallResult.unwrap();
    
    auto smallGet = cas.getBlob(smallHash);
    assert(smallGet.isOk, "Failed to get small blob");
    assert(smallGet.unwrap() == smallData[], "Small blob data mismatch");
    
    // Test large blob (should use mmap internally)
    enum largeSize = 512 * 1024;  // 512 KB (above 256 KB threshold)
    ubyte[] largeData = new ubyte[largeSize];
    foreach (i, ref b; largeData) b = cast(ubyte)(i & 0xFF);
    
    auto largeResult = cas.putBlob(largeData);
    assert(largeResult.isOk, "Failed to store large blob");
    auto largeHash = largeResult.unwrap();
    
    auto largeGet = cas.getBlob(largeHash);
    assert(largeGet.isOk, "Failed to get large blob");
    assert(largeGet.unwrap() == largeData[], "Large blob data mismatch");
    
    // Test deduplication
    auto dupeResult = cas.putBlob(largeData);
    assert(dupeResult.isOk);
    assert(dupeResult.unwrap() == largeHash, "Deduplication should return same hash");
}

/// Integration test: LocalArtifactStore with mmap
@system unittest
{
    import engine.distributed.storage.store : LocalArtifactStore;
    import engine.distributed.protocol.protocol : ArtifactId;
    
    immutable testDir = buildPath(tempDir(), "mmap_artifact_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new LocalArtifactStore(testDir, 100 * 1024 * 1024);  // 100 MB max
    
    // Test small artifact (should NOT use mmap)
    ubyte[4096] smallData;
    foreach (i, ref b; smallData) b = cast(ubyte)(i * 7 & 0xFF);
    
    auto smallPut = store.put(smallData);
    assert(smallPut.isOk, "Failed to store small artifact");
    auto smallId = smallPut.unwrap();
    
    auto smallGet = store.get(smallId);
    assert(smallGet.isOk, "Failed to get small artifact");
    assert(smallGet.unwrap() == smallData[], "Small artifact data mismatch");
    
    // Test large artifact (should use mmap internally)
    enum largeSize = 512 * 1024;  // 512 KB (above threshold)
    ubyte[] largeData = new ubyte[largeSize];
    foreach (i, ref b; largeData) b = cast(ubyte)(i * 13 & 0xFF);
    
    auto largePut = store.put(largeData);
    assert(largePut.isOk, "Failed to store large artifact");
    auto largeId = largePut.unwrap();
    
    auto largeGet = store.get(largeId);
    assert(largeGet.isOk, "Failed to get large artifact");
    assert(largeGet.unwrap() == largeData[], "Large artifact data mismatch");
}

/// Integration test: MappedBlobStore zero-copy access
@system unittest
{
    import engine.caching.storage.mapped : MappedBlobStore, MappedBlob;
    
    immutable testDir = buildPath(tempDir(), "mmap_mapped_blob_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new MappedBlobStore(testDir);
    
    // Create large test blob
    enum size = 1024 * 1024;  // 1 MB
    ubyte[] testData = new ubyte[size];
    foreach (i, ref b; testData) b = cast(ubyte)(i & 0xFF);
    
    auto putResult = store.putBlob(testData);
    assert(putResult.isOk, "Failed to store blob");
    auto hash = putResult.unwrap();
    
    // Get mapped blob (true zero-copy)
    auto mappedResult = store.getMappedBlob(hash);
    assert(mappedResult.isOk, "Failed to get mapped blob");
    
    auto blob = mappedResult.unwrap();
    assert(blob.valid, "MappedBlob should be valid");
    assert(blob.length == size, "MappedBlob length mismatch");
    assert(blob.hash == hash, "MappedBlob hash mismatch");
    
    // Verify data through mapping
    auto data = blob.data();
    assert(data.length == size);
    assert(data[0] == 0);
    assert(data[255] == 255);
    assert(data[size - 1] == ((size - 1) & 0xFF));
    
    // Test access hints
    blob.sequential();
    blob.random();
    
    // Get statistics
    auto s = store.stats();
    assert(s.blobsWritten >= 1);
    assert(s.bytesWritten >= size);
}

/// Integration test: Mmap with FastHash
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_fasthash_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create large test file
    enum size = 2 * 1024 * 1024;  // 2 MB
    ubyte[] testData = new ubyte[size];
    foreach (i, ref b; testData) b = cast(ubyte)(i & 0xFF);
    write(testPath, testData);
    
    // Hash via FastHash (uses mmap internally for large files)
    auto fileHash = FastHash.hashFile(testPath);
    assert(fileHash.length > 0, "Hash should not be empty");
    
    // Hash the same data directly for comparison
    auto directHash = FastHash.hashBytes(testData);
    
    // Large file uses sampling, so hashes may differ
    // Just verify both produce valid hashes
    assert(fileHash.length == directHash.length, "Hash lengths should match");
}

/// Integration test: Multiple concurrent mappings
@system unittest
{
    immutable testDir = buildPath(tempDir(), "mmap_concurrent_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    
    // Create multiple test files
    string[] paths;
    foreach (i; 0 .. 4)
    {
        auto path = buildPath(testDir, "file" ~ i.to!string ~ ".bin");
        ubyte[] data = new ubyte[64 * 1024];  // 64 KB each
        foreach (j, ref b; data) b = cast(ubyte)((i + j) & 0xFF);
        write(path, data);
        paths ~= path;
    }
    
    // Map all files simultaneously
    MmapRegion[] regions;
    scope(exit) foreach (r; regions) if (r !is null) r.unmap();
    
    foreach (path; paths)
    {
        auto region = MmapRegion.map(path, MapMode.ReadOnly);
        assert(region !is null, "Failed to map: " ~ path);
        regions ~= region;
    }
    
    // Verify all mappings are valid and correct
    foreach (i, region; regions)
    {
        assert(region.valid);
        assert(region.length == 64 * 1024);
        
        auto data = region[];
        assert(data[0] == cast(ubyte)(i & 0xFF));
        assert(data[1] == cast(ubyte)((i + 1) & 0xFF));
    }
}

/// Integration test: Large file streaming via mmap
@system unittest
{
    import engine.caching.storage.mapped : MappedBlobStream;
    
    immutable testPath = buildPath(tempDir(), "mmap_stream_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create large file
    enum size = 1024 * 1024;  // 1 MB
    ubyte[] testData = new ubyte[size];
    foreach (i, ref b; testData) b = cast(ubyte)(i & 0xFF);
    write(testPath, testData);
    
    // Stream through file
    auto streamResult = MappedBlobStream.open(testPath, 64 * 1024);  // 64 KB window
    assert(streamResult.isOk, "Failed to open stream");
    auto stream = streamResult.unwrap();
    
    assert(!stream.eof);
    assert(stream.size == size);
    assert(stream.position == 0);
    
    // Read first chunk (window-based, returns up to window size)
    auto chunk1 = stream.read();
    assert(chunk1.length > 0);
    assert(chunk1[0] == 0);
    assert(chunk1.length >= 256 || chunk1[255] == 255);
    
    // Continue reading until end
    size_t totalRead = chunk1.length;
    while (!stream.eof)
    {
        auto chunk = stream.read();
        if (chunk !is null)
            totalRead += chunk.length;
    }
    assert(totalRead == size);
    assert(stream.eof);
    
    // Reset and verify
    stream.reset();
    assert(stream.position == 0);
    assert(!stream.eof);
}

/// Integration test: Memory efficiency - verify no excessive allocations
@system unittest
{
    import core.memory : GC;
    
    immutable testPath = buildPath(tempDir(), "mmap_memory_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create 4 MB file
    enum size = 4 * 1024 * 1024;
    ubyte[] testData = new ubyte[size];
    foreach (i, ref b; testData) b = cast(ubyte)(i & 0xFF);
    write(testPath, testData);
    
    // Clear test data from memory
    testData = null;
    GC.collect();
    
    // Get baseline memory
    auto baselineUsed = GC.stats().usedSize;
    
    // Map file (should not allocate 4 MB)
    auto region = MmapRegion.map(testPath, MapMode.ReadOnly);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    // Access data through mapping
    auto data = region[];
    assert(data.length == size);
    
    // Spot check data (triggers page faults, not allocations)
    assert(data[0] == 0);
    assert(data[size / 2] == ((size / 2) & 0xFF));
    assert(data[size - 1] == ((size - 1) & 0xFF));
    
    // Memory should not have increased by 4 MB
    auto currentUsed = GC.stats().usedSize;
    auto delta = currentUsed > baselineUsed ? currentUsed - baselineUsed : 0;
    
    // Should be much less than 4 MB (allowing some overhead for test infrastructure)
    assert(delta < 1024 * 1024, "Memory usage increased by " ~ delta.to!string ~ " bytes - mmap may not be working");
}

/// Integration test: Error handling
@system unittest
{
    import engine.caching.storage.cas : ContentAddressableStorage;
    
    immutable testDir = buildPath(tempDir(), "mmap_error_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    
    // Get non-existent blob
    auto result = cas.getBlob("nonexistent_hash_value");
    assert(result.isErr, "Should fail for non-existent blob");
    
    // Verify error message
    auto error = result.unwrapErr();
    assert(error.message().length > 0, "Error message should not be empty");
}

