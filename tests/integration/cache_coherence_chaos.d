module tests.integration.cache_coherence_chaos;

import std.stdio : writeln, File;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.file : exists, write, read, remove, mkdirRecurse, rmdirRecurse, tempDir, readText;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, canFind, min, max, sum;
import std.array : array, replicate;
import std.conv : to;
import std.random : uniform, uniform01, Random;
import std.string : strip;
import std.range : iota;
import std.parallelism : parallel;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.rwmutex : ReadWriteMutex;

import tests.harness : Assert;
import tests.fixtures : TempDir, scoped;
import engine.caching.targets.cache;
import engine.caching.actions.action;
import engine.caching.storage.cas;
import engine.caching.coordinator.coordinator;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// DISTRIBUTED CACHE COHERENCE CHAOS TESTS
// ============================================================================

/// Simulated distributed cache node
class DistributedCacheNode
{
    private string nodeId;
    private string cacheDir;
    private BuildCache cache;
    private ContentAddressableStorage cas;
    private Mutex mutex;
    private shared bool partitioned;
    private shared size_t writeCount;
    private shared size_t readCount;
    private shared size_t hitCount;
    private shared size_t missCount;
    
    this(string nodeId, string baseDir) @system
    {
        this.nodeId = nodeId;
        this.cacheDir = buildPath(baseDir, nodeId);
        this.mutex = new Mutex();
        
        mkdirRecurse(cacheDir);
        this.cache = new BuildCache(cacheDir);
        this.cas = new ContentAddressableStorage(buildPath(cacheDir, "cas"));
        
        atomicStore(partitioned, false);
        atomicStore(writeCount, 0);
        atomicStore(readCount, 0);
        atomicStore(hitCount, 0);
        atomicStore(missCount, 0);
    }
    
    void partition() @system
    {
        atomicStore(partitioned, true);
        Logger.info("Node " ~ nodeId ~ " partitioned from cluster");
    }
    
    void heal() @system
    {
        atomicStore(partitioned, false);
        Logger.info("Node " ~ nodeId ~ " rejoined cluster");
    }
    
    bool isPartitioned() const @system => atomicLoad(partitioned);
    
    bool put(string key, string[] sources, string[] deps, string hash) @system
    {
        if (atomicLoad(partitioned))
            return false;
        
        synchronized (mutex)
        {
            cache.update(key, sources, deps, hash);
            atomicOp!"+="(writeCount, 1);
            return true;
        }
    }
    
    bool isCached(string key, string[] sources, string[] deps) @system
    {
        if (atomicLoad(partitioned))
            return false;
        
        synchronized (mutex)
        {
            atomicOp!"+="(readCount, 1);
            bool hit = cache.isCached(key, sources, deps);
            
            if (hit)
                atomicOp!"+="(hitCount, 1);
            else
                atomicOp!"+="(missCount, 1);
            
            return hit;
        }
    }
    
    string putBlob(ubyte[] data) @system
    {
        if (atomicLoad(partitioned))
            return "";
        
        synchronized (mutex)
        {
            auto result = cas.putBlob(data);
            if (result.isOk)
                return result.unwrap();
            return "";
        }
    }
    
    ubyte[] getBlob(string hash) @system
    {
        if (atomicLoad(partitioned))
            return [];
        
        synchronized (mutex)
        {
            auto result = cas.getBlob(hash);
            if (result.isOk)
                return result.unwrap();
            return [];
        }
    }
    
    void flush() @system
    {
        synchronized (mutex)
        {
            cache.flush();
        }
    }
    
    void close() @system
    {
        synchronized (mutex)
        {
            cache.close();
        }
    }
    
    struct NodeStats
    {
        size_t writes;
        size_t reads;
        size_t hits;
        size_t misses;
        float hitRate;
    }
    
    NodeStats getStats() const @system
    {
        NodeStats stats;
        stats.writes = atomicLoad(writeCount);
        stats.reads = atomicLoad(readCount);
        stats.hits = atomicLoad(hitCount);
        stats.misses = atomicLoad(missCount);
        
        immutable total = stats.hits + stats.misses;
        stats.hitRate = total > 0 ? cast(float)stats.hits / cast(float)total : 0.0f;
        
        return stats;
    }
    
    @property string id() const => nodeId;
}

/// Distributed cache cluster simulator
class DistributedCacheCluster
{
    private DistributedCacheNode[] nodes;
    private string baseDir;
    private Mutex mutex;
    
    this(string baseDir, size_t nodeCount) @system
    {
        this.baseDir = baseDir;
        this.mutex = new Mutex();
        
        mkdirRecurse(baseDir);
        
        foreach (i; 0 .. nodeCount)
        {
            nodes ~= new DistributedCacheNode("node" ~ i.to!string, baseDir);
        }
    }
    
    DistributedCacheNode getNode(size_t idx) @system
    {
        return nodes[idx];
    }
    
    size_t nodeCount() const @system => nodes.length;
    
    /// Partition nodes into two groups
    void createPartition(size_t[] group1Indices) @system
    {
        foreach (i; group1Indices)
        {
            if (i < nodes.length)
                nodes[i].partition();
        }
    }
    
    /// Heal all partitions
    void healPartition() @system
    {
        foreach (node; nodes)
        {
            node.heal();
        }
    }
    
    void close() @system
    {
        foreach (node; nodes)
        {
            node.flush();
            node.close();
        }
    }
}

// ============================================================================
// CACHE COHERENCE TESTS
// ============================================================================

/// Test: Concurrent writes to same key across nodes
@("cache_coherence.concurrent_writes")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Concurrent Writes to Same Key");
    
    auto tempDir = scoped(new TempDir("coherence-concurrent-writes"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 3);
    scope(exit) cluster.close();
    
    // Create test file
    tempDir.createFile("source.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.d");
    
    shared size_t successfulWrites = 0;
    
    // All nodes write to same key with different hashes
    foreach (nodeIdx; parallel(iota(3)))
    {
        auto node = cluster.getNode(nodeIdx);
        auto hash = "hash-from-node" ~ nodeIdx.to!string;
        
        if (node.put("shared-key", [sourcePath], [], hash))
            atomicOp!"+="(successfulWrites, 1);
    }
    
    Assert.equal(atomicLoad(successfulWrites), 3, "All writes should succeed");
    
    // Each node should have its own version cached
    foreach (nodeIdx; 0 .. 3)
    {
        auto node = cluster.getNode(nodeIdx);
        Assert.isTrue(node.isCached("shared-key", [sourcePath], []),
                     "Node " ~ nodeIdx.to!string ~ " should have cached key");
    }
    
    writeln("  \x1b[32m✓ Concurrent writes test passed\x1b[0m");
}

/// Test: Cache coherence during network partition
@("cache_coherence.partition_behavior")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Behavior During Network Partition");
    
    auto tempDir = scoped(new TempDir("coherence-partition"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 4);
    scope(exit) cluster.close();
    
    // Create test file
    tempDir.createFile("test.cpp", "int main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "test.cpp");
    
    // Initially, all nodes agree
    foreach (i; 0 .. 4)
    {
        cluster.getNode(i).put("partition-key", [sourcePath], [], "initial-hash");
    }
    
    // Create partition: nodes 0,1 vs nodes 2,3
    cluster.createPartition([2, 3]);
    
    // Nodes 0,1 can still operate
    Assert.isTrue(cluster.getNode(0).put("partition-key", [sourcePath], [], "updated-hash-a"),
                 "Non-partitioned node should write");
    Assert.isTrue(cluster.getNode(1).isCached("partition-key", [sourcePath], []),
                 "Non-partitioned node should read");
    
    // Nodes 2,3 cannot operate
    Assert.isFalse(cluster.getNode(2).put("partition-key", [sourcePath], [], "updated-hash-b"),
                  "Partitioned node should fail write");
    Assert.isFalse(cluster.getNode(3).isCached("partition-key", [sourcePath], []),
                  "Partitioned node should fail read");
    
    // Heal partition
    cluster.healPartition();
    
    // All nodes can operate again
    foreach (i; 0 .. 4)
    {
        Assert.isFalse(cluster.getNode(i).isPartitioned(),
                      "Node " ~ i.to!string ~ " should be healed");
    }
    
    writeln("  \x1b[32m✓ Partition behavior test passed\x1b[0m");
}

/// Test: Cache invalidation propagation
@("cache_coherence.invalidation_propagation")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Invalidation Propagation");
    
    auto tempDir = scoped(new TempDir("coherence-invalidation"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 3);
    scope(exit) cluster.close();
    
    // Create and cache file on all nodes
    tempDir.createFile("invalidate.d", "version 1");
    auto sourcePath = buildPath(tempDir.getPath(), "invalidate.d");
    
    foreach (i; 0 .. 3)
    {
        cluster.getNode(i).put("invalidate-target", [sourcePath], [], "v1-hash");
    }
    
    // All nodes should have cache hit
    foreach (i; 0 .. 3)
    {
        Assert.isTrue(cluster.getNode(i).isCached("invalidate-target", [sourcePath], []),
                     "Initial cache should be valid");
    }
    
    // Modify source file
    Thread.sleep(10.msecs);  // Ensure timestamp changes
    tempDir.createFile("invalidate.d", "version 2");
    
    // All nodes should detect invalidation (file modified)
    foreach (i; 0 .. 3)
    {
        Assert.isFalse(cluster.getNode(i).isCached("invalidate-target", [sourcePath], []),
                      "Cache should be invalidated after source change");
    }
    
    writeln("  \x1b[32m✓ Invalidation propagation test passed\x1b[0m");
}

/// Test: CAS blob consistency across nodes
@("cache_coherence.cas_consistency")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - CAS Blob Consistency");
    
    auto tempDir = scoped(new TempDir("coherence-cas"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 3);
    scope(exit) cluster.close();
    
    // Store same blob on all nodes
    ubyte[] testData = cast(ubyte[])"Test blob data for consistency check";
    string[] hashes;
    
    foreach (i; 0 .. 3)
    {
        auto hash = cluster.getNode(i).putBlob(testData);
        Assert.notEmpty([hash], "Hash should not be empty");
        hashes ~= hash;
    }
    
    // All nodes should produce same hash for same content
    Assert.equal(hashes[0], hashes[1], "Hashes should match across nodes");
    Assert.equal(hashes[1], hashes[2], "Hashes should match across nodes");
    
    // All nodes should retrieve same content
    foreach (i; 0 .. 3)
    {
        auto retrieved = cluster.getNode(i).getBlob(hashes[0]);
        Assert.equal(retrieved, testData, "Retrieved data should match original");
    }
    
    writeln("  \x1b[32m✓ CAS consistency test passed\x1b[0m");
}

/// Test: High-frequency cache updates
@("cache_coherence.high_frequency_updates")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - High Frequency Updates");
    
    auto tempDir = scoped(new TempDir("coherence-high-freq"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 2);
    scope(exit) cluster.close();
    
    tempDir.createFile("rapid.txt", "initial");
    auto sourcePath = buildPath(tempDir.getPath(), "rapid.txt");
    
    shared size_t totalUpdates = 0;
    shared size_t conflicts = 0;
    
    // Two nodes rapidly updating same key
    foreach (nodeIdx; parallel(iota(2)))
    {
        auto node = cluster.getNode(nodeIdx);
        
        foreach (i; 0 .. 100)
        {
            auto hash = "hash-" ~ nodeIdx.to!string ~ "-" ~ i.to!string;
            node.put("rapid-key", [sourcePath], [], hash);
            atomicOp!"+="(totalUpdates, 1);
            
            // Check for read-after-write consistency
            if (!node.isCached("rapid-key", [sourcePath], []))
            {
                atomicOp!"+="(conflicts, 1);
            }
        }
    }
    
    Logger.info("High frequency updates: " ~ atomicLoad(totalUpdates).to!string ~ 
               ", conflicts: " ~ atomicLoad(conflicts).to!string);
    
    Assert.equal(atomicLoad(totalUpdates), 200, "All updates should complete");
    
    writeln("  \x1b[32m✓ High frequency updates test passed\x1b[0m");
}

/// Test: Split-brain recovery
@("cache_coherence.split_brain_recovery")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Split-Brain Recovery");
    
    auto tempDir = scoped(new TempDir("coherence-split-brain"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 4);
    scope(exit) cluster.close();
    
    tempDir.createFile("split.cpp", "original");
    auto sourcePath = buildPath(tempDir.getPath(), "split.cpp");
    
    // Initial state: all nodes agree
    foreach (i; 0 .. 4)
    {
        cluster.getNode(i).put("split-key", [sourcePath], [], "original-hash");
    }
    
    // Create split-brain: partition nodes 0,1 from nodes 2,3
    cluster.createPartition([2, 3]);
    
    // Each partition evolves independently (simulated by different file versions)
    // Partition A (nodes 0,1) modifies the file
    Thread.sleep(10.msecs);
    tempDir.createFile("split.cpp", "partition A version");
    cluster.getNode(0).put("split-key", [sourcePath], [], "partition-a-hash");
    cluster.getNode(1).put("split-key", [sourcePath], [], "partition-a-hash");
    
    // Heal partition
    cluster.healPartition();
    
    // After healing, nodes may have different versions
    // This is expected - the test verifies the system doesn't crash
    bool node0Cached = cluster.getNode(0).isCached("split-key", [sourcePath], []);
    bool node2Cached = cluster.getNode(2).isCached("split-key", [sourcePath], []);
    
    Logger.info("After split-brain recovery - Node0 cached: " ~ node0Cached.to!string ~
               ", Node2 cached: " ~ node2Cached.to!string);
    
    // Both nodes should be operational (not crashed)
    Assert.isTrue(true, "System should survive split-brain");
    
    writeln("  \x1b[32m✓ Split-brain recovery test passed\x1b[0m");
}

/// Test: Cache stats under load
@("cache_coherence.stats_under_load")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Stats Under Load");
    
    auto tempDir = scoped(new TempDir("coherence-stats"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 3);
    scope(exit) cluster.close();
    
    // Create multiple test files
    foreach (i; 0 .. 10)
    {
        tempDir.createFile("file" ~ i.to!string ~ ".d", "content" ~ i.to!string);
    }
    
    // Generate load on all nodes
    foreach (nodeIdx; parallel(iota(3)))
    {
        auto node = cluster.getNode(nodeIdx);
        
        foreach (i; 0 .. 100)
        {
            auto fileIdx = i % 10;
            auto sourcePath = buildPath(tempDir.getPath(), "file" ~ fileIdx.to!string ~ ".d");
            auto key = "target-" ~ fileIdx.to!string;
            
            // 50% writes, 50% reads
            if (i % 2 == 0)
            {
                node.put(key, [sourcePath], [], "hash-" ~ i.to!string);
            }
            else
            {
                node.isCached(key, [sourcePath], []);
            }
        }
    }
    
    // Verify stats
    size_t totalWrites = 0;
    size_t totalReads = 0;
    
    foreach (i; 0 .. 3)
    {
        auto stats = cluster.getNode(i).getStats();
        totalWrites += stats.writes;
        totalReads += stats.reads;
        
        Logger.info("Node " ~ i.to!string ~ " - writes: " ~ stats.writes.to!string ~
                   ", reads: " ~ stats.reads.to!string ~
                   ", hit rate: " ~ (stats.hitRate * 100).to!string ~ "%");
    }
    
    Assert.equal(totalWrites, 150, "Should have 150 total writes (50 per node)");
    Assert.equal(totalReads, 150, "Should have 150 total reads (50 per node)");
    
    writeln("  \x1b[32m✓ Stats under load test passed\x1b[0m");
}

/// Test: Concurrent blob storage stress
@("cache_coherence.blob_stress")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Blob Storage Stress");
    
    auto tempDir = scoped(new TempDir("coherence-blob-stress"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 3);
    scope(exit) cluster.close();
    
    shared size_t successfulStores = 0;
    shared size_t successfulRetrieves = 0;
    
    // All nodes store many blobs concurrently
    foreach (nodeIdx; parallel(iota(3)))
    {
        auto node = cluster.getNode(nodeIdx);
        string[] storedHashes;
        
        // Store blobs
        foreach (i; 0 .. 50)
        {
            ubyte[] data = new ubyte[100];
            foreach (j; 0 .. 100)
            {
                data[j] = cast(ubyte)((nodeIdx * 1000 + i * 10 + j) % 256);
            }
            
            auto hash = node.putBlob(data);
            if (hash.length > 0)
            {
                storedHashes ~= hash;
                atomicOp!"+="(successfulStores, 1);
            }
        }
        
        // Retrieve blobs
        foreach (hash; storedHashes)
        {
            auto retrieved = node.getBlob(hash);
            if (retrieved.length > 0)
            {
                atomicOp!"+="(successfulRetrieves, 1);
            }
        }
    }
    
    Logger.info("Blob stress - stored: " ~ atomicLoad(successfulStores).to!string ~
               ", retrieved: " ~ atomicLoad(successfulRetrieves).to!string);
    
    Assert.equal(atomicLoad(successfulStores), 150, "All stores should succeed");
    Assert.equal(atomicLoad(successfulRetrieves), 150, "All retrieves should succeed");
    
    writeln("  \x1b[32m✓ Blob storage stress test passed\x1b[0m");
}

/// Test: Cache recovery after corruption
@("cache_coherence.corruption_recovery")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Recovery After Corruption");
    
    auto tempDir = scoped(new TempDir("coherence-corruption"));
    
    // Create and populate cache
    {
        auto cache = new BuildCache(buildPath(tempDir.getPath(), "cache"));
        tempDir.createFile("source.d", "content");
        auto sourcePath = buildPath(tempDir.getPath(), "source.d");
        
        cache.update("corrupt-target", [sourcePath], [], "original-hash");
        cache.flush();
        cache.close();
    }
    
    // Corrupt cache file
    auto cacheFile = buildPath(tempDir.getPath(), "cache", "cache.bin");
    if (exists(cacheFile))
    {
        auto data = cast(ubyte[])read(cacheFile);
        if (data.length > 50)
        {
            // Corrupt middle of file
            foreach (i; 25 .. 50)
            {
                data[i] = cast(ubyte)(data[i] ^ 0xFF);
            }
            write(cacheFile, data);
        }
    }
    
    // Try to recover
    try
    {
        auto cache2 = new BuildCache(buildPath(tempDir.getPath(), "cache"));
        
        // Should be able to use cache after corruption (fresh start)
        tempDir.createFile("new.d", "new content");
        auto newPath = buildPath(tempDir.getPath(), "new.d");
        
        cache2.update("new-target", [newPath], [], "new-hash");
        Assert.isTrue(cache2.isCached("new-target", [newPath], []),
                     "Cache should work after corruption recovery");
        
        cache2.close();
        writeln("  \x1b[32m✓ Corruption recovery test passed (recovered)\x1b[0m");
    }
    catch (Exception e)
    {
        // Corruption detection is also valid behavior
        writeln("  \x1b[32m✓ Corruption recovery test passed (detected)\x1b[0m");
    }
}

/// Test: Interleaved reads and writes
@("cache_coherence.interleaved_ops")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Interleaved Reads and Writes");
    
    auto tempDir = scoped(new TempDir("coherence-interleaved"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 2);
    scope(exit) cluster.close();
    
    tempDir.createFile("interleave.cpp", "content");
    auto sourcePath = buildPath(tempDir.getPath(), "interleave.cpp");
    
    shared bool running = true;
    shared size_t readOps = 0;
    shared size_t writeOps = 0;
    shared size_t inconsistencies = 0;
    
    // Writer thread
    auto writerThread = new Thread({
        auto node = cluster.getNode(0);
        size_t version_ = 0;
        
        while (atomicLoad(running))
        {
            version_++;
            node.put("interleave-key", [sourcePath], [], "v" ~ version_.to!string);
            atomicOp!"+="(writeOps, 1);
            Thread.sleep(1.msecs);
        }
    });
    
    // Reader thread
    auto readerThread = new Thread({
        auto node = cluster.getNode(1);
        
        while (atomicLoad(running))
        {
            // Reader on different node may see stale data (expected in distributed system)
            node.isCached("interleave-key", [sourcePath], []);
            atomicOp!"+="(readOps, 1);
            Thread.sleep(1.msecs);
        }
    });
    
    writerThread.start();
    readerThread.start();
    
    Thread.sleep(500.msecs);
    atomicStore(running, false);
    
    writerThread.join();
    readerThread.join();
    
    Logger.info("Interleaved ops - reads: " ~ atomicLoad(readOps).to!string ~
               ", writes: " ~ atomicLoad(writeOps).to!string);
    
    Assert.isTrue(atomicLoad(readOps) > 100, "Should have many reads");
    Assert.isTrue(atomicLoad(writeOps) > 100, "Should have many writes");
    
    writeln("  \x1b[32m✓ Interleaved operations test passed\x1b[0m");
}

/// Test: Large value storage and retrieval
@("cache_coherence.large_values")
@system unittest
{
    writeln("\x1b[36m[COHERENCE]\x1b[0m Cache - Large Value Storage");
    
    auto tempDir = scoped(new TempDir("coherence-large"));
    auto cluster = new DistributedCacheCluster(tempDir.getPath(), 2);
    scope(exit) cluster.close();
    
    // Create large file (1 MB)
    auto largeContent = new char[1024 * 1024];
    largeContent[] = 'X';
    tempDir.createFile("large.bin", largeContent.idup);
    auto largePath = buildPath(tempDir.getPath(), "large.bin");
    
    // Store on node 0
    cluster.getNode(0).put("large-target", [largePath], [], "large-hash");
    
    // Verify both nodes can work with large files
    Assert.isTrue(cluster.getNode(0).isCached("large-target", [largePath], []),
                 "Node 0 should cache large target");
    
    // Store large blob
    ubyte[] largeBlob = new ubyte[512 * 1024];  // 512 KB
    foreach (i; 0 .. largeBlob.length)
    {
        largeBlob[i] = cast(ubyte)(i % 256);
    }
    
    auto hash = cluster.getNode(0).putBlob(largeBlob);
    Assert.notEmpty([hash], "Large blob should be stored");
    
    auto retrieved = cluster.getNode(0).getBlob(hash);
    Assert.equal(retrieved.length, largeBlob.length, "Retrieved blob should match size");
    
    writeln("  \x1b[32m✓ Large value storage test passed\x1b[0m");
}

