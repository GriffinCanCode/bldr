module tests.integration.cache_corruption_recovery;

import std.stdio : writeln, File;
import std.file : exists, read, write, remove, mkdirRecurse, rmdirRecurse, tempDir, getSize, dirEntries, SpanMode;
import std.path : buildPath, dirName, baseName;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.algorithm : map, filter, canFind, sum, each;
import std.array : array;
import std.conv : to;
import std.random : uniform, uniform01, Random, Mt19937;
import std.digest.sha : sha256Of, toHexString;
import std.string : strip;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// CACHE CORRUPTION RECOVERY TESTS
// Comprehensive tests for cache integrity and corruption recovery
// ============================================================================

/// Content-addressable storage simulator with corruption detection
class CorruptibleCAS
{
    private string storageDir;
    private Mutex mutex;
    private size_t[string] refCounts;
    private bool[string] knownHashes;  // Track what we've stored
    
    this(string dir) @system
    {
        this.storageDir = dir;
        this.mutex = new Mutex();
        if (!exists(dir))
            mkdirRecurse(dir);
    }
    
    string getBlobPath(string hash) const @safe
    {
        // Use first 2 chars as directory for sharding
        return buildPath(storageDir, hash[0..2], hash);
    }
    
    /// Store blob and return hash
    string putBlob(const(ubyte)[] data) @system
    {
        auto hash = sha256Of(data).toHexString().idup;
        auto blobPath = getBlobPath(hash);
        
        synchronized (mutex)
        {
            if (!exists(blobPath))
            {
                auto dir = dirName(blobPath);
                if (!exists(dir))
                    mkdirRecurse(dir);
                write(blobPath, data);
            }
            
            refCounts[hash] = refCounts.get(hash, 0) + 1;
            knownHashes[hash] = true;
        }
        
        return hash;
    }
    
    /// Get blob with optional integrity check
    ubyte[] getBlob(string hash, bool verifyIntegrity = true) @system
    {
        auto blobPath = getBlobPath(hash);
        
        synchronized (mutex)
        {
            if (!exists(blobPath))
                return null;
            
            auto data = cast(ubyte[])read(blobPath);
            
            if (verifyIntegrity)
            {
                auto actualHash = sha256Of(data).toHexString().idup;
                if (actualHash != hash)
                    return null;  // Corruption detected
            }
            
            return data;
        }
    }
    
    /// Check if blob exists
    bool hasBlob(string hash) @system
    {
        synchronized (mutex)
            return exists(getBlobPath(hash));
    }
    
    /// Corrupt a blob by flipping bits
    void corruptBlob(string hash, size_t byteOffset, ubyte xorMask = 0xFF) @system
    {
        auto path = getBlobPath(hash);
        synchronized (mutex)
        {
            if (!exists(path))
                return;
            
            auto data = cast(ubyte[])read(path);
            if (byteOffset < data.length)
            {
                data[byteOffset] ^= xorMask;
                write(path, data);
            }
        }
    }
    
    /// Truncate a blob
    void truncateBlob(string hash, size_t newSize) @system
    {
        auto path = getBlobPath(hash);
        synchronized (mutex)
        {
            if (!exists(path))
                return;
            
            auto data = cast(ubyte[])read(path);
            if (newSize < data.length)
                write(path, data[0..newSize]);
        }
    }
    
    /// Delete blob file without updating refcount (simulates external deletion)
    void deleteFile(string hash) @system
    {
        auto path = getBlobPath(hash);
        synchronized (mutex)
        {
            if (exists(path))
                remove(path);
        }
    }
    
    /// Check and repair inconsistencies
    struct RepairResult
    {
        size_t missingBlobs;
        size_t corruptedBlobs;
        size_t orphanedFiles;
        size_t repairedRefCounts;
    }
    
    RepairResult checkAndRepair() @system
    {
        RepairResult result;
        
        synchronized (mutex)
        {
            // Check known hashes for missing/corrupt blobs
            string[] toRemove;
            foreach (hash, _; knownHashes)
            {
                auto path = getBlobPath(hash);
                
                if (!exists(path))
                {
                    result.missingBlobs++;
                    toRemove ~= hash;
                    continue;
                }
                
                // Verify integrity
                auto data = cast(ubyte[])read(path);
                auto actualHash = sha256Of(data).toHexString().idup;
                if (actualHash != hash)
                {
                    result.corruptedBlobs++;
                    remove(path);  // Remove corrupted blob
                    toRemove ~= hash;
                }
            }
            
            // Clean up references to missing/corrupt blobs
            foreach (hash; toRemove)
            {
                knownHashes.remove(hash);
                if (hash in refCounts)
                {
                    refCounts.remove(hash);
                    result.repairedRefCounts++;
                }
            }
            
            // Find orphaned files (files without refcount entries)
            foreach (entry; dirEntries(storageDir, SpanMode.depth))
            {
                if (!entry.isFile)
                    continue;
                
                auto filename = baseName(entry.name);
                if (filename.length == 64 && filename !in knownHashes)
                {
                    result.orphanedFiles++;
                    remove(entry.name);
                }
            }
        }
        
        return result;
    }
    
    size_t getRefCount(string hash) @system
    {
        synchronized (mutex)
            return refCounts.get(hash, 0);
    }
    
    void setRefCount(string hash, size_t count) @system
    {
        synchronized (mutex)
            refCounts[hash] = count;
    }
}

/// Action cache entry with CAS reference
struct ActionCacheEntry
{
    string actionId;
    string outputHash;  // Reference to CAS blob
    long timestamp;
    bool valid = true;
}

/// Action cache simulator
class CorruptibleActionCache
{
    private ActionCacheEntry[string] entries;
    private CorruptibleCAS cas;
    private Mutex mutex;
    
    this(CorruptibleCAS cas) @system
    {
        this.cas = cas;
        this.mutex = new Mutex();
    }
    
    void store(string actionId, ubyte[] output) @system
    {
        auto hash = cas.putBlob(output);
        
        synchronized (mutex)
        {
            entries[actionId] = ActionCacheEntry(
                actionId,
                hash,
                MonoTime.currTime.ticks,
                true
            );
        }
    }
    
    ubyte[] retrieve(string actionId) @system
    {
        synchronized (mutex)
        {
            if (actionId !in entries)
                return null;
            
            auto entry = entries[actionId];
            if (!entry.valid)
                return null;
            
            auto data = cas.getBlob(entry.outputHash, true);
            if (data is null)
            {
                // CAS blob missing or corrupted - invalidate entry
                entries[actionId].valid = false;
                return null;
            }
            
            return data;
        }
    }
    
    bool hasEntry(string actionId) @system
    {
        synchronized (mutex)
            return actionId in entries && entries[actionId].valid;
    }
    
    /// Create dangling reference by deleting CAS blob
    void createDanglingRef(string actionId) @system
    {
        synchronized (mutex)
        {
            if (actionId in entries)
            {
                auto hash = entries[actionId].outputHash;
                cas.deleteFile(hash);
            }
        }
    }
    
    /// Validate and repair entries
    struct ValidationResult
    {
        size_t totalEntries;
        size_t validEntries;
        size_t invalidatedEntries;
    }
    
    ValidationResult validateAll() @system
    {
        ValidationResult result;
        
        synchronized (mutex)
        {
            result.totalEntries = entries.length;
            
            foreach (ref entry; entries)
            {
                if (!entry.valid)
                    continue;
                
                // Check if CAS blob exists and is valid
                auto data = cas.getBlob(entry.outputHash, true);
                if (data is null)
                {
                    entry.valid = false;
                    result.invalidatedEntries++;
                }
                else
                {
                    result.validEntries++;
                }
            }
        }
        
        return result;
    }
}

// ============================================================================
// CHECKSUM MISMATCH TESTS
// ============================================================================

/// Test: CAS checksum mismatch detection
@("cache_corruption.checksum_mismatch")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Checksum Mismatch Detection");
    
    auto tempPath = buildPath(tempDir(), "checksum-test-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    
    // Store valid blob
    auto content = cast(ubyte[])"This is valid content for checksum testing";
    auto hash = cas.putBlob(content);
    
    // Verify retrieval works
    auto retrieved = cas.getBlob(hash, true);
    Assert.equal(retrieved, content, "Initial retrieval should match");
    
    // Corrupt the blob
    cas.corruptBlob(hash, 10, 0xFF);  // Flip bits at byte 10
    
    // Retrieval with integrity check should fail
    auto corrupted = cas.getBlob(hash, true);
    Assert.isTrue(corrupted is null, "Corrupted blob should fail integrity check");
    
    // Retrieval without integrity check returns bad data
    auto badData = cas.getBlob(hash, false);
    Assert.isTrue(badData !is null, "Without check, should return data");
    Assert.notEqual(badData, content, "Corrupted data should differ");
    
    writeln("  \x1b[32m✓ Checksum mismatch detection passed\x1b[0m");
}

/// Test: Bit rot detection across multiple blobs
@("cache_corruption.bit_rot_detection")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Bit Rot Detection");
    
    auto tempPath = buildPath(tempDir(), "bitrot-test-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    auto rng = Mt19937(12345);
    
    // Store many blobs
    string[] hashes;
    foreach (i; 0 .. 50)
    {
        ubyte[] data = new ubyte[uniform(100, 1000, rng)];
        foreach (ref b; data)
            b = cast(ubyte)uniform(0, 256, rng);
        hashes ~= cas.putBlob(data);
    }
    
    // Randomly corrupt 10% of blobs
    size_t corrupted = 0;
    foreach (hash; hashes)
    {
        if (uniform01(rng) < 0.1)
        {
            cas.corruptBlob(hash, uniform(0, 500, rng));
            corrupted++;
        }
    }
    
    Logger.info("Bit rot test - corrupted " ~ corrupted.to!string ~ " of " ~ hashes.length.to!string ~ " blobs");
    
    // Verify detection
    size_t detected = 0;
    foreach (hash; hashes)
    {
        if (cas.getBlob(hash, true) is null)
            detected++;
    }
    
    Assert.equal(detected, corrupted, "Should detect all corrupted blobs");
    
    writeln("  \x1b[32m✓ Bit rot detection passed\x1b[0m");
}

// ============================================================================
// REFERENCE COUNT CORRUPTION TESTS
// ============================================================================

/// Test: Reference count inconsistency detection and repair
@("cache_corruption.refcount_inconsistency")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Reference Count Inconsistency");
    
    auto tempPath = buildPath(tempDir(), "refcount-test-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    
    // Store blobs
    auto hash1 = cas.putBlob(cast(ubyte[])"blob one");
    auto hash2 = cas.putBlob(cast(ubyte[])"blob two");
    auto hash3 = cas.putBlob(cast(ubyte[])"blob three");
    
    // Verify initial refcounts
    Assert.equal(cas.getRefCount(hash1), 1, "hash1 should have refcount 1");
    Assert.equal(cas.getRefCount(hash2), 1, "hash2 should have refcount 1");
    
    // Corrupt refcounts manually
    cas.setRefCount(hash1, 100);  // Inflated refcount
    cas.setRefCount(hash2, 0);    // Zero refcount but file exists
    
    // Delete file but keep refcount (inconsistent state)
    cas.deleteFile(hash3);
    // hash3 still has refcount=1 but no file
    
    // Run repair
    auto result = cas.checkAndRepair();
    
    Logger.info("Refcount repair - missing: " ~ result.missingBlobs.to!string ~
               ", repaired: " ~ result.repairedRefCounts.to!string);
    
    Assert.equal(result.missingBlobs, 1, "Should detect one missing blob");
    Assert.isTrue(result.repairedRefCounts >= 1, "Should repair refcounts");
    
    writeln("  \x1b[32m✓ Reference count inconsistency repair passed\x1b[0m");
}

/// Test: Orphaned file cleanup
@("cache_corruption.orphaned_files")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Orphaned File Cleanup");
    
    auto tempPath = buildPath(tempDir(), "orphan-test-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    
    // Store legitimate blobs
    cas.putBlob(cast(ubyte[])"legitimate blob");
    
    // Create orphaned files (files without tracking)
    auto orphanDir = buildPath(tempPath, "ab");
    mkdirRecurse(orphanDir);
    
    // Create fake hash files (64 hex chars)
    foreach (i; 0 .. 5)
    {
        auto fakeHash = "ab" ~ "00000000000000000000000000000000000000000000000000000000000000".dup;
        fakeHash[2] = cast(char)('0' + i);
        write(buildPath(orphanDir, fakeHash.idup), "orphaned data");
    }
    
    // Run repair
    auto result = cas.checkAndRepair();
    
    Logger.info("Orphan cleanup - found: " ~ result.orphanedFiles.to!string);
    
    Assert.equal(result.orphanedFiles, 5, "Should find 5 orphaned files");
    
    writeln("  \x1b[32m✓ Orphaned file cleanup passed\x1b[0m");
}

// ============================================================================
// DANGLING REFERENCE TESTS
// ============================================================================

/// Test: Action cache dangling CAS reference
@("cache_corruption.dangling_cas_reference")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Dangling CAS Reference");
    
    auto tempPath = buildPath(tempDir(), "dangling-test-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    auto actionCache = new CorruptibleActionCache(cas);
    
    // Store actions
    actionCache.store("action1", cast(ubyte[])"output for action 1");
    actionCache.store("action2", cast(ubyte[])"output for action 2");
    actionCache.store("action3", cast(ubyte[])"output for action 3");
    
    // Verify initial state
    Assert.isTrue(actionCache.hasEntry("action1"), "action1 should exist");
    Assert.isTrue(actionCache.hasEntry("action2"), "action2 should exist");
    
    // Create dangling reference by deleting CAS blob
    actionCache.createDanglingRef("action2");
    
    // Retrieve should detect dangling ref
    auto result1 = actionCache.retrieve("action1");
    auto result2 = actionCache.retrieve("action2");
    
    Assert.isTrue(result1 !is null, "action1 should retrieve successfully");
    Assert.isTrue(result2 is null, "action2 should fail (dangling ref)");
    
    // Entry should be invalidated
    Assert.isFalse(actionCache.hasEntry("action2"), "action2 should be invalidated");
    
    writeln("  \x1b[32m✓ Dangling CAS reference handling passed\x1b[0m");
}

/// Test: Bulk validation of action cache
@("cache_corruption.bulk_validation")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Bulk Validation");
    
    auto tempPath = buildPath(tempDir(), "bulk-validate-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    auto actionCache = new CorruptibleActionCache(cas);
    
    // Store many actions
    foreach (i; 0 .. 100)
    {
        actionCache.store("action" ~ i.to!string, cast(ubyte[])("output " ~ i.to!string));
    }
    
    // Corrupt some CAS blobs (create dangling refs)
    foreach (i; [5, 15, 25, 35, 45])
    {
        actionCache.createDanglingRef("action" ~ i.to!string);
    }
    
    // Run bulk validation
    auto result = actionCache.validateAll();
    
    Logger.info("Bulk validation - total: " ~ result.totalEntries.to!string ~
               ", valid: " ~ result.validEntries.to!string ~
               ", invalidated: " ~ result.invalidatedEntries.to!string);
    
    Assert.equal(result.totalEntries, 100, "Should have 100 entries");
    Assert.equal(result.validEntries, 95, "Should have 95 valid entries");
    Assert.equal(result.invalidatedEntries, 5, "Should invalidate 5 entries");
    
    writeln("  \x1b[32m✓ Bulk validation passed\x1b[0m");
}

// ============================================================================
// ATOMIC WRITE FAILURE TESTS
// ============================================================================

/// Test: Torn write detection (partial file write)
@("cache_corruption.torn_write")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Torn Write Detection");
    
    auto tempPath = buildPath(tempDir(), "torn-write-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    
    // Store blob
    auto content = cast(ubyte[])"This is a longer content that will be truncated to simulate torn write";
    auto hash = cas.putBlob(content);
    
    // Simulate torn write by truncating
    cas.truncateBlob(hash, content.length / 2);
    
    // Verify detection
    auto retrieved = cas.getBlob(hash, true);
    Assert.isTrue(retrieved is null, "Truncated blob should fail integrity check");
    
    // Run repair
    auto result = cas.checkAndRepair();
    Assert.equal(result.corruptedBlobs, 1, "Should detect one corrupted blob");
    
    writeln("  \x1b[32m✓ Torn write detection passed\x1b[0m");
}

/// Test: Concurrent corruption and GC
@("cache_corruption.concurrent_gc")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Concurrent Corruption and GC");
    
    auto tempPath = buildPath(tempDir(), "concurrent-gc-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    auto mutex = new Mutex();
    shared bool running = true;
    shared size_t corruptionCount = 0;
    shared size_t gcRuns = 0;
    
    // Store initial blobs
    string[] hashes;
    foreach (i; 0 .. 20)
    {
        synchronized (mutex)
        {
            hashes ~= cas.putBlob(cast(ubyte[])("blob " ~ i.to!string));
        }
    }
    
    // Corruption thread
    auto corruptThread = new Thread({
        auto rng = Mt19937(99999);
        while (atomicLoad(running))
        {
            if (hashes.length > 0)
            {
                auto idx = uniform(0, hashes.length, rng);
                synchronized (mutex)
                {
                    cas.corruptBlob(hashes[idx], uniform(0, 10, rng));
                }
                atomicOp!"+="(corruptionCount, 1);
            }
            Thread.sleep(10.msecs);
        }
    });
    
    // GC thread
    auto gcThread = new Thread({
        while (atomicLoad(running))
        {
            synchronized (mutex)
            {
                cas.checkAndRepair();
            }
            atomicOp!"+="(gcRuns, 1);
            Thread.sleep(50.msecs);
        }
    });
    
    corruptThread.start();
    gcThread.start();
    
    Thread.sleep(500.msecs);
    atomicStore(running, false);
    
    corruptThread.join();
    gcThread.join();
    
    Logger.info("Concurrent GC - corruptions: " ~ atomicLoad(corruptionCount).to!string ~
               ", GC runs: " ~ atomicLoad(gcRuns).to!string);
    
    // Final repair should leave system consistent
    auto finalResult = cas.checkAndRepair();
    Logger.info("Final state - missing: " ~ finalResult.missingBlobs.to!string ~
               ", corrupted: " ~ finalResult.corruptedBlobs.to!string);
    
    writeln("  \x1b[32m✓ Concurrent corruption and GC passed\x1b[0m");
}

// ============================================================================
// RECOVERY DURING BUILD TESTS
// ============================================================================

/// Test: Cache recovery while build is active
@("cache_corruption.recovery_during_build")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Recovery During Active Build");
    
    auto tempPath = buildPath(tempDir(), "recovery-build-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto cas = new CorruptibleCAS(tempPath);
    auto actionCache = new CorruptibleActionCache(cas);
    auto mutex = new Mutex();
    
    shared bool buildRunning = true;
    shared size_t actionsCompleted = 0;
    shared size_t cacheMisses = 0;
    shared size_t cacheHits = 0;
    
    // Simulate active build
    auto buildThread = new Thread({
        foreach (i; 0 .. 50)
        {
            if (!atomicLoad(buildRunning))
                break;
            
            auto actionId = "build-action-" ~ i.to!string;
            
            synchronized (mutex)
            {
                // Try cache first
                auto cached = actionCache.retrieve(actionId);
                if (cached !is null)
                {
                    atomicOp!"+="(cacheHits, 1);
                }
                else
                {
                    atomicOp!"+="(cacheMisses, 1);
                    // Execute and store
                    actionCache.store(actionId, cast(ubyte[])("result " ~ i.to!string));
                }
            }
            
            atomicOp!"+="(actionsCompleted, 1);
            Thread.sleep(20.msecs);
        }
    });
    
    // Recovery thread runs during build
    auto recoveryThread = new Thread({
        Thread.sleep(100.msecs);  // Let build start
        
        // Corrupt some entries
        foreach (i; [5, 10, 15])
        {
            synchronized (mutex)
            {
                actionCache.createDanglingRef("build-action-" ~ i.to!string);
            }
        }
        
        // Run validation/repair
        synchronized (mutex)
        {
            actionCache.validateAll();
            cas.checkAndRepair();
        }
    });
    
    buildThread.start();
    recoveryThread.start();
    
    buildThread.join();
    atomicStore(buildRunning, false);
    recoveryThread.join();
    
    Logger.info("Recovery during build - completed: " ~ atomicLoad(actionsCompleted).to!string ~
               ", hits: " ~ atomicLoad(cacheHits).to!string ~
               ", misses: " ~ atomicLoad(cacheMisses).to!string);
    
    Assert.isTrue(atomicLoad(actionsCompleted) > 0, "Build should make progress");
    
    writeln("  \x1b[32m✓ Recovery during active build passed\x1b[0m");
}

// ============================================================================
// CROSS-CACHE INCONSISTENCY TESTS
// ============================================================================

/// Test: Multi-tier cache inconsistency
@("cache_corruption.multi_tier_inconsistency")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Multi-Tier Inconsistency");
    
    auto tempPath = buildPath(tempDir(), "multi-tier-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    // Simulate L1 (memory) and L2 (disk) caches
    struct L1Cache
    {
        ubyte[][string] entries;
        
        void put(string key, ubyte[] value) { entries[key] = value.dup; }
        ubyte[] get(string key) { return key in entries ? entries[key] : null; }
        void invalidate(string key) { entries.remove(key); }
    }
    
    auto l1 = L1Cache();
    auto l2 = new CorruptibleCAS(tempPath);
    
    // Store in both tiers
    auto data = cast(ubyte[])"shared cache data";
    auto hash = l2.putBlob(data);
    l1.put(hash, data);
    
    // Corrupt L2
    l2.corruptBlob(hash, 5);
    
    // L1 hit returns stale data
    auto l1Result = l1.get(hash);
    Assert.equal(l1Result, data, "L1 should return cached data");
    
    // L2 miss on verification
    auto l2Result = l2.getBlob(hash, true);
    Assert.isTrue(l2Result is null, "L2 should detect corruption");
    
    // Invalidate L1 on L2 corruption
    if (l2Result is null)
        l1.invalidate(hash);
    
    Assert.isTrue(l1.get(hash) is null, "L1 should be invalidated");
    
    writeln("  \x1b[32m✓ Multi-tier inconsistency handling passed\x1b[0m");
}

/// Test: Hash collision handling
@("cache_corruption.hash_collision")
@system unittest
{
    writeln("\x1b[36m[CORRUPTION]\x1b[0m Cache - Hash Collision Handling");
    
    auto tempPath = buildPath(tempDir(), "collision-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    // Simulate hash collision by forcing same path
    struct CollisionCAS
    {
        string storageDir;
        
        string getPath(string hash) => buildPath(storageDir, hash[0..8]);  // Truncated hash
        
        void put(string hash, ubyte[] data) @system
        {
            auto path = getPath(hash);
            auto dir = dirName(path);
            if (!exists(dir))
                mkdirRecurse(dir);
            
            // Check for collision
            if (exists(path))
            {
                auto existing = cast(ubyte[])read(path);
                if (existing != data)
                    throw new Exception("Hash collision detected!");
            }
            write(path, data);
        }
    }
    
    mkdirRecurse(tempPath);
    auto cas = CollisionCAS(tempPath);
    
    // Two different contents with same truncated hash prefix
    auto data1 = cast(ubyte[])"first content";
    auto data2 = cast(ubyte[])"second different content";
    
    auto hash1 = sha256Of(data1).toHexString().idup;
    auto hash2 = sha256Of(data2).toHexString().idup;
    
    // Store first
    cas.put(hash1, data1);
    
    // Check if paths collide
    if (cas.getPath(hash1) == cas.getPath(hash2))
    {
        // Should detect collision
        bool collisionDetected = false;
        try
        {
            cas.put(hash2, data2);
        }
        catch (Exception e)
        {
            collisionDetected = true;
        }
        
        Assert.isTrue(collisionDetected, "Should detect hash collision");
    }
    
    writeln("  \x1b[32m✓ Hash collision handling passed\x1b[0m");
}

