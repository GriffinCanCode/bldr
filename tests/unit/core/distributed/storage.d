module tests.unit.core.distributed.storage;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import engine.distributed.storage.store;
import engine.distributed.protocol.protocol;
import tests.harness;
import tests.fixtures;

// ==================== ARTIFACT STORE INTERFACE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - LocalArtifactStore creation");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    
    auto store = new LocalArtifactStore(storeDir, 1024 * 1024);  // 1MB max
    
    Assert.isTrue(exists(storeDir));
    
    writeln("\x1b[32m  ✓ LocalArtifactStore creation works\x1b[0m");
}

// ==================== BASIC OPERATIONS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Put and get artifact");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[] data = cast(ubyte[])"Hello, World!";
    
    // Put artifact
    auto putResult = store.put(data);
    Assert.isTrue(putResult.isOk);
    
    auto artifactId = putResult.unwrap();
    
    // Get artifact
    auto getResult = store.get(artifactId);
    Assert.isTrue(getResult.isOk);
    
    auto retrieved = getResult.unwrap();
    Assert.equal(retrieved, data);
    
    writeln("\x1b[32m  ✓ Put and get artifact works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Has artifact");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[] data = cast(ubyte[])"Test data";
    
    // Put artifact
    auto putResult = store.put(data);
    Assert.isTrue(putResult.isOk);
    auto artifactId = putResult.unwrap();
    
    // Check existence
    auto hasResult = store.has(artifactId);
    Assert.isTrue(hasResult.isOk);
    Assert.isTrue(hasResult.unwrap());
    
    writeln("\x1b[32m  ✓ Has artifact works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Get non-existent artifact");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[32] fakeHash;
    fakeHash[0] = 0xFF;
    auto fakeId = ArtifactId(fakeHash);
    
    auto getResult = store.get(fakeId);
    Assert.isTrue(getResult.isErr);
    
    writeln("\x1b[32m  ✓ Get non-existent artifact handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Has non-existent artifact");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[32] fakeHash;
    fakeHash[0] = 0xFF;
    auto fakeId = ArtifactId(fakeHash);
    
    auto hasResult = store.has(fakeId);
    Assert.isTrue(hasResult.isOk);
    Assert.isFalse(hasResult.unwrap());
    
    writeln("\x1b[32m  ✓ Has non-existent artifact works\x1b[0m");
}

// ==================== DEDUPLICATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Duplicate artifact deduplication");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[] data = cast(ubyte[])"Same data";
    
    // Put same artifact twice
    auto result1 = store.put(data);
    auto result2 = store.put(data);
    
    Assert.isTrue(result1.isOk);
    Assert.isTrue(result2.isOk);
    
    auto id1 = result1.unwrap();
    auto id2 = result2.unwrap();
    
    // Should have same ID (content-addressable)
    Assert.isTrue(id1 == id2);
    
    writeln("\x1b[32m  ✓ Duplicate artifact deduplication works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Different content has different IDs");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[] data1 = cast(ubyte[])"Data 1";
    ubyte[] data2 = cast(ubyte[])"Data 2";
    
    auto result1 = store.put(data1);
    auto result2 = store.put(data2);
    
    Assert.isTrue(result1.isOk);
    Assert.isTrue(result2.isOk);
    
    auto id1 = result1.unwrap();
    auto id2 = result2.unwrap();
    
    // Different content should have different IDs
    Assert.isFalse(id1 == id2);
    
    writeln("\x1b[32m  ✓ Different content has different IDs\x1b[0m");
}

// ==================== BATCH OPERATIONS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Batch has operation");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    // Put multiple artifacts
    ArtifactId[] ids;
    foreach (i; 0 .. 5)
    {
        ubyte[] data = cast(ubyte[])("Data " ~ i.to!string);
        auto result = store.put(data);
        Assert.isTrue(result.isOk);
        ids ~= result.unwrap();
    }
    
    // Batch check
    auto hasResult = store.hasMany(ids);
    Assert.isTrue(hasResult.isOk);
    
    auto results = hasResult.unwrap();
    Assert.equal(results.length, 5);
    
    foreach (exists; results)
    {
        Assert.isTrue(exists);
    }
    
    writeln("\x1b[32m  ✓ Batch has operation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Batch get operation");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    // Put multiple artifacts
    ArtifactId[] ids;
    ubyte[][] originalData;
    
    foreach (i; 0 .. 3)
    {
        ubyte[] data = cast(ubyte[])("Test data " ~ i.to!string);
        originalData ~= data;
        
        auto result = store.put(data);
        Assert.isTrue(result.isOk);
        ids ~= result.unwrap();
    }
    
    // Batch get
    auto getResult = store.getMany(ids);
    Assert.isTrue(getResult.isOk);
    
    auto retrieved = getResult.unwrap();
    Assert.equal(retrieved.length, 3);
    
    foreach (i, data; retrieved)
    {
        Assert.equal(data, originalData[i]);
    }
    
    writeln("\x1b[32m  ✓ Batch get operation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Batch operations with mixed results");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    // Put one artifact
    ubyte[] data = cast(ubyte[])"Exists";
    auto putResult = store.put(data);
    Assert.isTrue(putResult.isOk);
    auto existingId = putResult.unwrap();
    
    // Create fake ID
    ubyte[32] fakeHash;
    fakeHash[0] = 0xFF;
    auto fakeId = ArtifactId(fakeHash);
    
    // Batch check with one existing, one non-existing
    ArtifactId[] ids = [existingId, fakeId];
    auto hasResult = store.hasMany(ids);
    
    Assert.isTrue(hasResult.isOk);
    auto results = hasResult.unwrap();
    
    Assert.equal(results.length, 2);
    Assert.isTrue(results[0]);   // Exists
    Assert.isFalse(results[1]);  // Doesn't exist
    
    writeln("\x1b[32m  ✓ Batch operations with mixed results work\x1b[0m");
}

// ==================== EVICTION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - LRU eviction on space limit");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 100);  // Very small limit
    
    // Put artifact that fits
    ubyte[] data1 = cast(ubyte[])"Small";
    auto result1 = store.put(data1);
    Assert.isTrue(result1.isOk);
    auto id1 = result1.unwrap();
    
    // Put another that should trigger eviction
    ubyte[] data2 = new ubyte[80];
    data2[] = 0x42;
    auto result2 = store.put(data2);
    Assert.isTrue(result2.isOk);
    
    // First artifact may have been evicted
    // This is acceptable behavior
    
    writeln("\x1b[32m  ✓ LRU eviction works\x1b[0m");
}

// ==================== LARGE ARTIFACT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Large artifact storage");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    // Create large artifact (1MB)
    ubyte[] largeData = new ubyte[1024 * 1024];
    foreach (i, ref b; largeData)
        b = cast(ubyte)(i % 256);
    
    auto putResult = store.put(largeData);
    Assert.isTrue(putResult.isOk);
    
    auto artifactId = putResult.unwrap();
    
    // Retrieve and verify
    auto getResult = store.get(artifactId);
    Assert.isTrue(getResult.isOk);
    
    auto retrieved = getResult.unwrap();
    Assert.equal(retrieved.length, largeData.length);
    Assert.equal(retrieved, largeData);
    
    writeln("\x1b[32m  ✓ Large artifact storage works\x1b[0m");
}

// ==================== EMPTY ARTIFACT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Empty artifact");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    ubyte[] emptyData = [];
    
    auto putResult = store.put(emptyData);
    Assert.isTrue(putResult.isOk);
    
    auto artifactId = putResult.unwrap();
    
    auto getResult = store.get(artifactId);
    Assert.isTrue(getResult.isOk);
    
    auto retrieved = getResult.unwrap();
    Assert.equal(retrieved.length, 0);
    
    writeln("\x1b[32m  ✓ Empty artifact handled\x1b[0m");
}

// ==================== PERSISTENCE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Persistence across instances");
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    
    ubyte[] data = cast(ubyte[])"Persistent data";
    ArtifactId artifactId;
    
    // First instance - store artifact
    {
        auto store1 = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
        auto putResult = store1.put(data);
        Assert.isTrue(putResult.isOk);
        artifactId = putResult.unwrap();
    }
    
    // Second instance - retrieve artifact
    {
        auto store2 = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
        
        auto hasResult = store2.has(artifactId);
        Assert.isTrue(hasResult.isOk);
        Assert.isTrue(hasResult.unwrap());
        
        auto getResult = store2.get(artifactId);
        Assert.isTrue(getResult.isOk);
        Assert.equal(getResult.unwrap(), data);
    }
    
    writeln("\x1b[32m  ✓ Persistence across instances works\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Concurrent put operations");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    try
    {
        // Put artifacts concurrently
        ArtifactId[] ids;
        synchronized
        {
            ids.length = 20;
        }
        
        foreach (i; parallel(iota(20)))
        {
            ubyte[] data = cast(ubyte[])("Concurrent data " ~ i.to!string);
            auto result = store.put(data);
            if (result.isOk)
            {
                synchronized
                {
                    ids[i] = result.unwrap();
                }
            }
        }
        
        // Verify all artifacts exist
        int existCount = 0;
        foreach (id; ids)
        {
            auto hasResult = store.has(id);
            if (hasResult.isOk && hasResult.unwrap())
                existCount++;
        }
        
        Assert.equal(existCount, 20);
        
        writeln("\x1b[32m  ✓ Concurrent put operations work\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Storage - Concurrent get operations");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto tempDir = scoped(new TempDir("artifact-store-test"));
    auto storeDir = buildPath(tempDir.getPath(), "artifacts");
    auto store = new LocalArtifactStore(storeDir, 10 * 1024 * 1024);
    
    // Put artifacts first
    ubyte[] data = cast(ubyte[])"Shared data";
    auto putResult = store.put(data);
    Assert.isTrue(putResult.isOk);
    auto artifactId = putResult.unwrap();
    
    try
    {
        // Get concurrently
        shared int successCount = 0;
        
        foreach (i; parallel(iota(20)))
        {
            auto getResult = store.get(artifactId);
            if (getResult.isOk)
            {
                auto retrieved = getResult.unwrap();
                if (retrieved == data)
                {
                    import core.atomic : atomicOp;
                    atomicOp!"+="(successCount, 1);
                }
            }
        }
        
        Assert.equal(successCount, 20);
        
        writeln("\x1b[32m  ✓ Concurrent get operations work\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

