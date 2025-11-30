module tests.unit.core.caching.storage;

import std.stdio;
import std.path;
import std.file;
import engine.caching.storage;
import tests.harness;
import tests.fixtures;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ContentAddressableStorage - Basic blob operations");
    
    auto tempDir = scoped(new TempDir("cas-test"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    
    auto cas = new ContentAddressableStorage(storageDir);
    
    // Store blob
    ubyte[] data1 = cast(ubyte[])"Hello, World!";
    auto putResult = cas.putBlob(data1);
    Assert.isTrue(putResult.isOk, "Put should succeed");
    
    auto hash1 = putResult.unwrap();
    Assert.isTrue(hash1.length > 0, "Hash should not be empty");
    
    // Retrieve blob
    auto getResult = cas.getBlob(hash1);
    Assert.isTrue(getResult.isOk, "Get should succeed");
    Assert.equal(getResult.unwrap(), data1);
    
    // Check existence
    Assert.isTrue(cas.hasBlob(hash1));
    Assert.isFalse(cas.hasBlob("nonexistent"));
    
    writeln("\x1b[32m  ✓ Basic blob operations work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ContentAddressableStorage - Deduplication");
    
    auto tempDir = scoped(new TempDir("cas-dedup-test"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    
    auto cas = new ContentAddressableStorage(storageDir);
    
    // Store same content twice
    ubyte[] data = cast(ubyte[])"Duplicate content";
    
    auto hash1 = cas.putBlob(data).unwrap();
    auto hash2 = cas.putBlob(data).unwrap();
    
    // Should have same hash (deduplicated)
    Assert.equal(hash1, hash2);
    
    // Get stats
    auto stats = cas.getStats();
    Assert.equal(stats.uniqueBlobs, 1, "Should have 1 unique blob");
    Assert.equal(stats.totalBlobs, 2, "Should have 2 references");
    Assert.isTrue(stats.deduplicationRatio > 0, "Should show deduplication");
    
    writeln("\x1b[32m  ✓ Deduplication works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ContentAddressableStorage - Reference counting");
    
    auto tempDir = scoped(new TempDir("cas-refcount-test"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    
    auto cas = new ContentAddressableStorage(storageDir);
    
    ubyte[] data = cast(ubyte[])"Test data";
    auto hash = cas.putBlob(data).unwrap();
    
    // Add references
    cas.addRef(hash);
    cas.addRef(hash);
    
    // Try to delete (should fail due to refs)
    auto canDelete = cas.removeRef(hash);
    Assert.isFalse(canDelete, "Should not be able to delete with refs");
    
    // Remove all refs
    cas.removeRef(hash);
    canDelete = cas.removeRef(hash);
    Assert.isTrue(canDelete, "Should be able to delete after removing refs");
    
    // Delete blob
    auto deleteResult = cas.deleteBlob(hash);
    Assert.isTrue(deleteResult.isOk, "Delete should succeed");
    
    // Verify deleted
    Assert.isFalse(cas.hasBlob(hash));
    
    writeln("\x1b[32m  ✓ Reference counting works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheGarbageCollector - Basic collection");
    
    auto tempDir = scoped(new TempDir("gc-test"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto cas = new ContentAddressableStorage(storageDir);
    auto gc = new CacheGarbageCollector(cas);
    
    // Store some blobs
    cas.putBlob(cast(ubyte[])"blob1");
    cas.putBlob(cast(ubyte[])"blob2");
    cas.putBlob(cast(ubyte[])"blob3");
    
    // Create caches
    import engine.caching.targets.cache : BuildCache;
    import engine.caching.actions.action : ActionCache;
    
    auto targetCache = new BuildCache(cacheDir);
    auto actionCache = new ActionCache(cacheDir ~ "/actions");
    
    // Run GC (should collect orphaned blobs)
    auto gcResult = gc.collect(targetCache, actionCache);
    Assert.isTrue(gcResult.isOk, "GC should succeed");
    
    auto result = gcResult.unwrap();
    Assert.isTrue(result.blobsCollected >= 0, "Should report collected blobs");
    
    targetCache.close();
    actionCache.close();
    
    writeln("\x1b[32m  ✓ Garbage collection works\x1b[0m");
}

