module tests.unit.dedup;

import engine.caching.dedup;
import engine.caching.storage.cas : ContentAddressableStorage;
import std.file : exists, mkdirRecurse, rmdirRecurse;

/// Test BlobRef creation from data
unittest
{
    auto data = cast(ubyte[])"test content";
    auto ref_ = BlobRef.fromData(data, "test.txt", true);
    
    assert(ref_.isValid);
    assert(ref_.size == data.length);
    assert(ref_.path == "test.txt");
    assert(ref_.executable);
    assert(ref_.hash.length > 0);
}

/// Test BlobRef nil sentinel
unittest
{
    auto nil = BlobRef.nil;
    assert(!nil.isValid);
    assert(nil.hash.length == 0);
}

/// Test dedup engine stores and retrieves blobs
unittest
{
    // Setup temp directory
    immutable testDir = ".test-dedup-engine";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    auto engine = new DedupEngine(cas);
    
    auto data = cast(ubyte[])"hello world";
    
    // Store blob
    auto storeResult = engine.store(data, "hello.txt");
    assert(storeResult.isOk);
    
    auto ref_ = storeResult.unwrap();
    assert(ref_.isValid);
    assert(ref_.size == data.length);
    
    // Fetch blob
    auto fetchResult = engine.fetch(ref_);
    assert(fetchResult.isOk);
    assert(fetchResult.unwrap() == data);
}

/// Test deduplication detection
unittest
{
    immutable testDir = ".test-dedup-detect";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    auto engine = new DedupEngine(cas);
    
    auto data = cast(ubyte[])"duplicate content";
    
    // Store same content twice
    auto ref1 = engine.store(data).unwrap();
    auto ref2 = engine.store(data).unwrap();
    
    // Should have same hash
    assert(ref1.hash == ref2.hash);
    
    // Stats should show deduplication
    auto stats = engine.getStats();
    assert(stats.uniqueBlobs == 1);
    assert(stats.duplicateRefs == 1);
    assert(stats.savedBytes == data.length);
}

/// Test manifest creation
unittest
{
    immutable testDir = ".test-manifest";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    auto engine = new DedupEngine(cas);
    
    auto outputs = [
        cast(ubyte[])"file 1 content",
        cast(ubyte[])"file 2 content"
    ];
    auto paths = ["out/file1.o", "out/file2.o"];
    
    auto result = buildManifest(engine, "action:test", outputs, paths, "inputs-hash");
    assert(result.isOk);
    
    auto manifest = result.unwrap();
    assert(manifest.actionId == "action:test");
    assert(manifest.outputCount == 2);
    assert(manifest.inputsHash == "inputs-hash");
    assert(manifest.success);
}

/// Test manifest serialization roundtrip
unittest
{
    ActionManifest manifest;
    manifest.actionId = "test:123";
    manifest.outputs = [
        ManifestEntry("hash1", 100, "file1.o", false, ""),
        ManifestEntry("hash2", 200, "file2.o", true, "")
    ];
    manifest.inputsHash = "inputs";
    manifest.success = true;
    
    // Serialize
    auto data = ManifestStorage.serialize(manifest);
    assert(data.length > 0);
    
    // Deserialize
    auto result = ManifestStorage.deserialize(data);
    assert(result.isOk);
    
    auto loaded = result.unwrap();
    assert(loaded.actionId == manifest.actionId);
    assert(loaded.outputCount == 2);
    assert(loaded.outputs[0].blobHash == "hash1");
    assert(loaded.outputs[1].executable);
}

/// Test DedupStore put and get
unittest
{
    immutable testDir = ".test-dedup-store";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new DedupStore(testDir);
    
    auto outputs = [
        cast(ubyte[])"output content 1",
        cast(ubyte[])"output content 2"
    ];
    auto paths = ["lib/foo.a", "lib/bar.a"];
    
    // Store action result
    auto putResult = store.put("action:build:abc123", outputs, paths, "inputs-hash");
    assert(putResult.isOk);
    
    // Check existence
    assert(store.has("action:build:abc123"));
    assert(!store.has("action:nonexistent"));
    
    // Retrieve manifest
    auto getResult = store.get("action:build:abc123");
    assert(getResult.isOk);
    
    auto manifest = getResult.unwrap();
    assert(manifest.actionId == "action:build:abc123");
    assert(manifest.outputCount == 2);
}

/// Test DedupStore materialization
unittest
{
    immutable testDir = ".test-dedup-materialize";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new DedupStore(testDir);
    
    auto content1 = cast(ubyte[])"content one";
    auto content2 = cast(ubyte[])"content two";
    auto outputs = [content1, content2];
    auto paths = ["file1.txt", "file2.txt"];
    
    store.put("action:test", outputs, paths, "hash");
    
    // Materialize
    auto result = store.materialize("action:test");
    assert(result.isOk);
    
    auto files = result.unwrap();
    assert(files.length == 2);
    assert(files[0].path == "file1.txt");
    assert(files[0].data == content1);
    assert(files[1].path == "file2.txt");
    assert(files[1].data == content2);
}

/// Test deduplication across actions
unittest
{
    immutable testDir = ".test-dedup-multi";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new DedupStore(testDir);
    
    // Same content, different actions
    auto sharedContent = cast(ubyte[])"shared library content";
    
    store.put("action:1", [sharedContent], ["lib.a"], "h1");
    store.put("action:2", [sharedContent], ["lib.a"], "h2");
    store.put("action:3", [sharedContent], ["lib.a"], "h3");
    
    // Should have 3 manifests but only 1 unique blob
    auto stats = store.getStats();
    assert(stats.manifestCount == 3);
    assert(stats.dedup.uniqueBlobs == 1);
    assert(stats.dedup.duplicateRefs == 2);
}

/// Test blob integrity verification
unittest
{
    immutable testDir = ".test-dedup-verify";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto cas = new ContentAddressableStorage(testDir);
    auto engine = new DedupEngine(cas);
    
    auto data = cast(ubyte[])"verify me";
    auto ref_ = engine.store(data).unwrap();
    
    // Verification should pass
    auto result = verifyBlob(engine, ref_);
    assert(result.isOk);
    assert(result.unwrap());
}

/// Test store statistics
unittest
{
    immutable testDir = ".test-dedup-stats";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new DedupStore(testDir);
    
    // Store some content
    auto large = new ubyte[1024];
    large[] = 0x42;
    
    store.put("action:a", [large], ["big.bin"], "h");
    store.put("action:b", [large], ["big.bin"], "h");  // Duplicate
    
    auto stats = store.getStats();
    assert(stats.manifestCount == 2);
    assert(stats.dedup.efficiency > 0);  // Should show savings
}

/// Test action removal and reference cleanup
unittest
{
    immutable testDir = ".test-dedup-remove";
    if (exists(testDir)) rmdirRecurse(testDir);
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new DedupStore(testDir);
    
    auto data = cast(ubyte[])"removable";
    store.put("action:remove", [data], ["file"], "h");
    
    assert(store.has("action:remove"));
    
    // Remove
    auto result = store.remove_("action:remove");
    assert(result.isOk);
    assert(!store.has("action:remove"));
}

/// Test collectBlobHashes helper
unittest
{
    ActionManifest manifest;
    manifest.outputs = [
        ManifestEntry("aaa", 10, "f1", false, ""),
        ManifestEntry("bbb", 20, "f2", false, ""),
        ManifestEntry("ccc", 30, "f3", false, "")
    ];
    
    auto hashes = collectBlobHashes(manifest);
    assert(hashes.length == 3);
    assert(hashes[0] == "aaa");
    assert(hashes[1] == "bbb");
    assert(hashes[2] == "ccc");
}

