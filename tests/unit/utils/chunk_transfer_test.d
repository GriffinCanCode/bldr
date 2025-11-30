module tests.unit.utils.chunk_transfer_test;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.conv;
import infrastructure.utils.files.chunking;
import infrastructure.errors;

/// Test basic file chunking
unittest
{
    writeln("Testing: Basic file chunking");
    
    // Create test file with random data
    immutable testFile = "test_chunk_basic.bin";
    scope(exit) if (exists(testFile)) remove(testFile);
    
    ubyte[] data = new ubyte[100_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
    std.file.write(testFile, data);
    
    // Chunk the file
    auto result = ContentChunker.chunkFile(testFile);
    
    assert(result.chunks.length > 0, "Should create chunks");
    assert(result.combinedHash.length > 0, "Should have combined hash");
    
    // Verify chunks cover entire file
    size_t totalLength = 0;
    foreach (chunk; result.chunks)
    {
        assert(chunk.length >= ContentChunker.MIN_CHUNK || 
               chunk.length == data.length, "Chunk too small");
        assert(chunk.length <= ContentChunker.MAX_CHUNK, "Chunk too large");
        totalLength += chunk.length;
    }
    
    assert(totalLength == data.length, "Chunks should cover entire file");
    
    writeln("  ✓ Basic chunking works");
}

/// Test chunk change detection
unittest
{
    writeln("Testing: Chunk change detection");
    
    // Create test file with pseudo-random data to ensure natural chunk boundaries
    immutable testFile = "test_chunk_change.bin";
    scope(exit) if (exists(testFile)) remove(testFile);
    
    ubyte[] data = new ubyte[300_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345); // Fixed seed for determinism
    
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
        
    std.file.write(testFile, data);
    
    // Chunk original
    auto result1 = ContentChunker.chunkFile(testFile);
    
    // Modify file (change middle 5%)
    data[50_000 .. 55_000] = 0xFF;
    std.file.write(testFile, data);
    
    // Chunk modified
    auto result2 = ContentChunker.chunkFile(testFile);
    
    // Find changes
    auto changedIndices = ContentChunker.findChangedChunks(result1, result2);
    
    assert(changedIndices.length > 0, "Should detect changes");
    assert(changedIndices.length < result2.chunks.length, 
           "Not all chunks should change");
    
    // Most chunks should be unchanged
    immutable changeRate = cast(double)changedIndices.length / 
                          cast(double)result2.chunks.length;
    assert(changeRate < 0.4, "Too many chunks changed");
    
    writeln("  ✓ Change detection works (", 
            changedIndices.length, "/", result2.chunks.length, " chunks changed)");
}

/// Test chunk serialization
unittest
{
    writeln("Testing: Chunk serialization");
    
    // Create test file
    immutable testFile = "test_chunk_serialize.bin";
    scope(exit) if (exists(testFile)) remove(testFile);
    
    ubyte[] data = new ubyte[50_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
    std.file.write(testFile, data);
    
    // Chunk and serialize
    auto result = ContentChunker.chunkFile(testFile);
    auto serialized = ContentChunker.serialize(result);
    
    assert(serialized.length > 0, "Should serialize");
    
    // Deserialize
    auto deserialized = ContentChunker.deserialize(serialized);
    
    assert(deserialized.chunks.length == result.chunks.length, 
           "Should preserve chunk count");
    assert(deserialized.combinedHash == result.combinedHash, 
           "Should preserve combined hash");
    
    // Verify chunks match
    foreach (i, chunk; result.chunks)
    {
        assert(deserialized.chunks[i].offset == chunk.offset, 
               "Should preserve offset");
        assert(deserialized.chunks[i].length == chunk.length, 
               "Should preserve length");
        assert(deserialized.chunks[i].hash == chunk.hash, 
               "Should preserve hash");
    }
    
    writeln("  ✓ Serialization works");
}

/// Test chunk manifest operations
unittest
{
    writeln("Testing: Chunk manifest operations");
    
    // Create two test files
    immutable testFile1 = "test_manifest1.bin";
    immutable testFile2 = "test_manifest2.bin";
    scope(exit)
    {
        if (exists(testFile1)) remove(testFile1);
        if (exists(testFile2)) remove(testFile2);
    }
    
    ubyte[] data1 = new ubyte[300_000];
    ubyte[] data2 = new ubyte[300_000];
    
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    
    foreach (ref b; data1) {
        b = cast(ubyte)uniform(0, 256, rng);
        data2[&b - data1.ptr] = b; // Copy to data2
    }
    
    // Modify second file slightly
    data2[50_000 .. 55_000] = 0xFF;
    
    std.file.write(testFile1, data1);
    std.file.write(testFile2, data2);
    
    // Create manifests
    auto result1 = ContentChunker.chunkFile(testFile1);
    auto result2 = ContentChunker.chunkFile(testFile2);
    
    ChunkManifest manifest1;
    manifest1.fileHash = result1.combinedHash;
    manifest1.chunks = result1.chunks;
    manifest1.totalSize = data1.length;
    
    ChunkManifest manifest2;
    manifest2.fileHash = result2.combinedHash;
    manifest2.chunks = result2.chunks;
    manifest2.totalSize = data2.length;
    
    // Find common chunks
    auto commonIndices = manifest1.findCommonChunks(manifest2);
    assert(commonIndices.length > 0, "Should find common chunks");
    
    // Calculate savings
    auto savings = manifest1.calculateDedupSavings(manifest2);
    assert(savings > 0, "Should have dedup savings");
    assert(savings < manifest1.totalSize, "Savings should be partial");
    
    immutable savingsPercent = (cast(double)savings / 
                                cast(double)manifest1.totalSize) * 100.0;
    
    writeln("  ✓ Manifest operations work (", 
            savingsPercent, "% dedup savings)");
}

/// Test transfer statistics
unittest
{
    writeln("Testing: Transfer statistics");
    
    TransferStats stats;
    stats.totalChunks = 100;
    stats.changedChunks = 10;
    stats.chunksTransferred = 10;
    stats.bytesTransferred = 160_000;  // 10 chunks * 16KB
    stats.bytesSaved = 1_440_000;      // 90 chunks * 16KB
    
    // Test efficiency calculation
    immutable efficiency = stats.efficiency();
    assert(efficiency > 0.89 && efficiency < 0.91, "Efficiency should be ~90%");
    
    // Test savings calculation
    immutable savingsPercent = stats.savingsPercent();
    assert(savingsPercent > 89.0 && savingsPercent < 91.0, 
           "Savings should be ~90%");
    
    writeln("  ✓ Transfer statistics work (", 
            efficiency * 100.0, "% efficiency, ",
            savingsPercent, "% savings)");
}

/// Test chunk transfer with mock upload
unittest
{
    writeln("Testing: Chunk transfer with mock upload");
    
    // Create test file
    immutable testFile = "test_transfer.bin";
    scope(exit) if (exists(testFile)) remove(testFile);
    
    ubyte[] data = new ubyte[100_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
    std.file.write(testFile, data);
    
    // Mock upload function
    size_t uploadedChunks = 0;
    bool mockUpload(string chunkHash, const(ubyte)[] chunkData)
    {
        uploadedChunks++;
        return true;
    }
    
    // Upload file using chunks
    auto result = ChunkTransfer.uploadFileChunked(testFile, &mockUpload);
    
    assert(result.isOk, "Upload should succeed");
    
    auto manifest = result.unwrap();
    assert(manifest.chunks.length > 0, "Should create chunks");
    assert(uploadedChunks == manifest.chunks.length, 
           "Should upload all chunks");
    
    writeln("  ✓ Chunk transfer works (uploaded ", uploadedChunks, " chunks)");
}

/// Test incremental chunk upload
unittest
{
    writeln("Testing: Incremental chunk upload");
    
    // Create test file
    immutable testFile = "test_incremental.bin";
    scope(exit) if (exists(testFile)) remove(testFile);
    
    ubyte[] data = new ubyte[300_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
    std.file.write(testFile, data);
    
    // Chunk original
    auto originalResult = ContentChunker.chunkFile(testFile);
    ChunkManifest originalManifest;
    originalManifest.fileHash = originalResult.combinedHash;
    originalManifest.chunks = originalResult.chunks;
    originalManifest.totalSize = data.length;
    
    // Modify file
    data[50_000 .. 55_000] = 0xFF;
    std.file.write(testFile, data);
    
    // Chunk modified
    auto newResult = ContentChunker.chunkFile(testFile);
    ChunkManifest newManifest;
    newManifest.fileHash = newResult.combinedHash;
    newManifest.chunks = newResult.chunks;
    newManifest.totalSize = data.length;
    
    // Mock upload (tracks chunks)
    size_t uploadedChunks = 0;
    size_t uploadedBytes = 0;
    bool mockUpload(string chunkHash, const(ubyte)[] chunkData)
    {
        uploadedChunks++;
        uploadedBytes += chunkData.length;
        return true;
    }
    
    // Incremental upload
    auto result = ChunkTransfer.uploadChangedChunks(
        testFile,
        newManifest,
        originalManifest,
        &mockUpload
    );
    
    assert(result.isOk, "Incremental upload should succeed");
    
    auto stats = result.unwrap();
    assert(stats.chunksTransferred > 0, "Should upload changed chunks");
    assert(stats.chunksTransferred < newManifest.chunks.length, 
           "Should not upload all chunks");
    assert(stats.bytesSaved > 0, "Should save bandwidth");
    
    immutable savingsPercent = stats.savingsPercent();
    assert(savingsPercent > 50.0, "Should save >50% bandwidth");
    
    writeln("  ✓ Incremental upload works (saved ", 
            savingsPercent, "% bandwidth)");
}

/// Test chunk download
unittest
{
    writeln("Testing: Chunk download");
    
    // Create test file
    immutable testFile = "test_download_source.bin";
    immutable outputFile = "test_download_output.bin";
    scope(exit)
    {
        if (exists(testFile)) remove(testFile);
        if (exists(outputFile)) remove(outputFile);
    }
    
    ubyte[] data = new ubyte[100_000];
    import std.random : Xorshift32, uniform;
    auto rng = Xorshift32(12345);
    foreach (ref b; data)
        b = cast(ubyte)uniform(0, 256, rng);
    std.file.write(testFile, data);
    
    // Chunk the file
    auto chunkResult = ContentChunker.chunkFile(testFile);
    
    ChunkManifest manifest;
    manifest.fileHash = chunkResult.combinedHash;
    manifest.chunks = chunkResult.chunks;
    manifest.totalSize = data.length;
    
    // Mock download function (reads from original file)
    Result!(ubyte[], string) mockDownload(string chunkHash) @trusted
    {
        // Find matching chunk
        foreach (chunk; manifest.chunks)
        {
            if (chunk.hash == chunkHash)
            {
                auto file = File(testFile, "rb");
                file.seek(chunk.offset);
                ubyte[] chunkData = new ubyte[chunk.length];
                auto readData = file.rawRead(chunkData);
                return Ok!(ubyte[], string)(cast(ubyte[])readData);
            }
        }
        return Err!(ubyte[], string)("Chunk not found");
    }
    
    // Download and reconstruct
    auto result = ChunkTransfer.downloadChunks(
        outputFile,
        manifest,
        &mockDownload
    );
    
    assert(result.isOk, "Download should succeed");
    
    auto stats = result.unwrap();
    assert(stats.chunksTransferred == manifest.chunks.length, 
           "Should download all chunks");
    
    // Verify reconstructed file matches
    auto originalData = read(testFile);
    auto downloadedData = read(outputFile);
    assert(originalData == downloadedData, "Downloaded file should match");
    
    writeln("  ✓ Chunk download works (downloaded ", 
            stats.chunksTransferred, " chunks)");
}


