# Additional Content-Defined Chunking Opportunities

## Overview

Beyond artifact store uploads and distributed cache transfers, several other Builder subsystems could benefit from content-defined chunking. This document identifies and prioritizes these opportunities.

## Current Integration

✅ **Already Implemented:**
1. **Artifact Store Uploads** - Large binaries (10-100MB+)
2. **Distributed Cache Transfers** - Remote cache operations
3. **Remote Execution Inputs** - Input files for remote workers

## Additional Opportunities

### 1. Graph Cache Storage 🟢 HIGH IMPACT

**Location:** `source/graph/cache.d`, `source/graph/storage.d`

**Current Approach:**
```d
// Serializes entire BuildGraph to binary
auto graphData = GraphStorage.serialize(graph);  // Can be 10+ MB
std.file.write(cacheFilePath, graphData);
```

**Problem:**
- Large monorepos have huge dependency graphs (1000+ targets = 100KB-10MB)
- Small changes (adding one target) require re-uploading entire graph
- Remote cache transfers waste bandwidth

**Chunking Benefit:**
```d
// Chunk the serialized graph
auto manifest = ChunkTransfer.uploadFileChunked(graphData, graphHash);

// Later, incremental update (only changed chunks)
auto updateResult = cacheClient.updateFileChunked(
    newGraphPath,
    newGraphHash,
    oldGraphHash
);

// Typical savings: 90%+ (most targets unchanged)
```

**Impact:**
- **Bandwidth Saved:** 80-95% for incremental graph changes
- **Use Case:** Distributed builds with graph cache sharing
- **Effort:** Low (graph already serialized to binary)

**Implementation:**
```d
class GraphCache
{
    // Chunked upload to remote cache
    void putRemote(BuildGraph graph, RemoteCacheClient cacheClient)
    {
        auto graphData = GraphStorage.serialize(graph);
        auto tempFile = ".builder-cache/graph-temp.bin";
        write(tempFile, graphData);
        
        // Use chunking for large graphs (> 1MB)
        auto uploadResult = cacheClient.putFileChunked(
            tempFile,
            computeGraphHash(graph)
        );
        
        if (uploadResult.isOk && uploadResult.unwrap().useChunking)
        {
            writeln("Graph uploaded using ", 
                    uploadResult.unwrap().stats.chunksTransferred, " chunks");
        }
    }
}
```

---

### 2. Parse Cache (AST Storage) 🟡 MEDIUM IMPACT

**Location:** `source/infrastructure/config/caching/parse.d`, `source/infrastructure/config/caching/storage.d`

**Current Approach:**
```d
// Serializes entire AST for each Builderfile
auto astData = ASTStorage.serialize(entry.ast);  // Can be 100KB+
buffer.put(astData);
```

**Problem:**
- Large Builderfiles generate big ASTs (100KB-1MB)
- AST cache synced across machines wastes bandwidth
- Small DSL changes require re-uploading entire AST

**Chunking Benefit:**
```d
// Chunk AST storage for remote sync
class ParseCache
{
    void syncToRemote(RemoteCacheClient cacheClient)
    {
        foreach (filePath, entry; entries)
        {
            auto astData = ASTStorage.serialize(entry.ast);
            
            if (astData.length > 100_000)  // 100KB threshold
            {
                // Use chunking for large ASTs
                auto result = cacheClient.putFileChunked(
                    tempPath(astData),
                    entry.contentHash
                );
                
                writeln("AST chunked: saved ", 
                        result.unwrap().stats.savingsPercent(), "%");
            }
        }
    }
}
```

**Impact:**
- **Bandwidth Saved:** 60-80% for incrementally updated ASTs
- **Use Case:** CI/CD with shared parse cache
- **Effort:** Low-Medium (requires remote sync infrastructure)

---

### 3. Action Cache (Build Results) 🟢 HIGH IMPACT

**Location:** `source/caching/actions/action.d`

**Current Approach:**
```d
// Stores action results in local cache
entries[actionId.toString()] = entry;  // Full entry
saveCache();  // Serializes all entries
```

**Problem:**
- Action cache can be huge (50,000 actions = 25MB+)
- Sharing action cache across CI/CD workers wastes bandwidth
- Most actions unchanged between builds

**Chunking Benefit:**
```d
class ActionCache
{
    // Incremental remote sync
    void syncToRemote(RemoteCacheClient cacheClient)
    {
        // Serialize action cache
        auto cacheData = serializeCache();
        auto tempFile = ".builder-cache/actions-temp.bin";
        write(tempFile, cacheData);
        
        // Incremental upload (only changed actions)
        auto updateResult = cacheClient.updateFileChunked(
            tempFile,
            computeCacheHash(),
            lastRemoteHash
        );
        
        writeln("Action cache sync: ", 
                updateResult.unwrap().chunksTransferred, " chunks, ",
                updateResult.unwrap().savingsPercent(), "% saved");
    }
}
```

**Impact:**
- **Bandwidth Saved:** 85-95% (most actions unchanged)
- **Use Case:** Distributed CI/CD with shared action cache
- **Effort:** Medium (requires sync coordination)

---

### 4. Distributed Worker Communication 🟢 HIGH IMPACT

**Location:** `source/distributed/worker/queue.d`, `source/distributed/coordinator/messages.d`

**Current Approach:**
```d
// Workers send/receive large action data
auto serialized = action.serialize();
client.send(serialized);  // Can be large (embedded data)
```

**Problem:**
- Action requests can include large embedded data
- Workers re-download same inputs multiple times
- Serialized actions can be 1MB+ for data-heavy tasks

**Chunking Benefit:**
```d
class DistributedQueue
{
    // Chunk-based action transfer
    void sendAction(ActionRequest action, Socket client)
    {
        // If action has large data, use chunking
        if (action.estimatedSize() > 1_048_576)  // 1MB
        {
            // Extract large data, chunk it
            auto largeData = action.extractLargeData();
            auto manifest = chunkAndStore(largeData);
            
            // Send action with chunk references instead of data
            action.replaceWithChunkRefs(manifest);
            client.send(action.serialize());
            
            writeln("Action sent using ", manifest.chunks.length, " chunks");
        }
        else
        {
            // Regular send for small actions
            client.send(action.serialize());
        }
    }
}
```

**Impact:**
- **Bandwidth Saved:** 70-90% for data-heavy actions
- **Use Case:** Distributed builds with large test data
- **Effort:** Medium-High (protocol changes)

---

### 5. Telemetry Log Storage 🟡 MEDIUM IMPACT

**Location:** `source/telemetry/persistence/storage.d`

**Current Approach:**
```d
// Appends telemetry events to log file
appendToLog(event);  // Grows continuously
```

**Problem:**
- Telemetry logs can be huge (100MB+ for long builds)
- Uploading to monitoring systems wastes bandwidth
- Most log content is repetitive

**Chunking Benefit:**
```d
class TelemetryStorage
{
    // Chunked upload to monitoring
    void uploadToMonitoring(RemoteCacheClient cacheClient)
    {
        auto logFile = buildPath(storageDir, "telemetry.log");
        
        // Chunk large log files
        auto result = cacheClient.putFileChunked(logFile, computeLogHash());
        
        if (result.isOk)
        {
            writeln("Telemetry uploaded: ", 
                    result.unwrap().stats.bytesTransferred, " bytes, ",
                    result.unwrap().stats.savingsPercent(), "% saved");
        }
    }
}
```

**Impact:**
- **Bandwidth Saved:** 50-70% (repetitive log patterns)
- **Use Case:** Centralized telemetry aggregation
- **Effort:** Low (logs already file-based)

---

### 6. Large Test Fixtures 🟡 MEDIUM IMPACT

**Location:** `source/testframework/`, test examples

**Current Approach:**
```d
// Tests load large fixture files
auto testData = read("fixtures/large_dataset.json");  // Can be 10MB+
```

**Problem:**
- Test fixtures can be huge (10-100MB datasets)
- Distributed test execution re-downloads fixtures
- CI/CD test parallelization limited by fixture transfer

**Chunking Benefit:**
```d
class TestFramework
{
    // Chunked fixture distribution
    void distributeFixture(string fixturePath, TestWorker[] workers)
    {
        // Chunk large fixture once
        auto manifest = ChunkTransfer.uploadFileChunked(
            fixturePath,
            (chunkHash, chunkData) {
                return broadcastChunk(chunkHash, chunkData, workers);
            }
        );
        
        // Workers can now fetch only missing chunks
        foreach (worker; workers)
        {
            worker.notifyFixtureAvailable(fixturePath, manifest);
        }
    }
}
```

**Impact:**
- **Bandwidth Saved:** 80-95% (fixtures reused across tests)
- **Use Case:** Parallel test execution with large fixtures
- **Effort:** Medium (requires test framework changes)

---

### 7. Language-Specific Large Outputs 🟢 HIGH IMPACT

**Location:** `source/languages/compiled/protobuf/`, other language handlers

**Current Approach:**
```d
// Protobuf generates large output files
auto outputData = read(outputPath);  // Can be 10MB+ for large schemas
cacheClient.put(outputHash, outputData);
```

**Problem:**
- Protobuf, gRPC, and other codegen tools produce huge files
- Small schema changes regenerate entire output
- Remote cache transfers waste bandwidth

**Chunking Benefit:**
```d
class ProtobufHandler
{
    // Already integrated with ArtifactManager!
    // Automatically uses chunking for large outputs
    
    Result!BuildError handleBuild(Target target)
    {
        // Build protobuf
        auto result = compileProto(target);
        
        // Upload output (automatically chunked if > 1MB)
        artifactManager.uploadInputs(sandboxSpec);
        // ^^^ This already uses chunking! No changes needed.
    }
}
```

**Impact:**
- **Bandwidth Saved:** 85-95% for incremental codegen
- **Use Case:** Monorepos with large protocol definitions
- **Effort:** **ZERO** ✅ (already integrated via ArtifactManager)

---

## Priority Matrix

| Opportunity | Impact | Effort | Bandwidth Saved | Priority |
|-------------|--------|--------|-----------------|----------|
| **Graph Cache** | High | Low | 80-95% | 🔴 P0 |
| **Action Cache** | High | Medium | 85-95% | 🔴 P0 |
| **Distributed Workers** | High | Medium-High | 70-90% | 🟠 P1 |
| **Language Outputs** | High | **Zero** ✅ | 85-95% | ✅ Done |
| **Parse Cache** | Medium | Low-Medium | 60-80% | 🟡 P2 |
| **Telemetry Logs** | Medium | Low | 50-70% | 🟡 P2 |
| **Test Fixtures** | Medium | Medium | 80-95% | 🟡 P2 |

## Implementation Recommendations

### Phase 1: Quick Wins (P0)

**1. Graph Cache Chunking** (1-2 days)
```d
// Add to source/graph/cache.d
void syncToRemote(RemoteCacheClient cacheClient, BuildGraph graph)
{
    auto graphData = GraphStorage.serialize(graph);
    auto tempFile = ".builder-cache/graph-temp.bin";
    write(tempFile, graphData);
    
    auto result = cacheClient.putFileChunked(tempFile, graphHash);
    writeln("Graph cache synced: ", result.unwrap().stats.savingsPercent(), "% saved");
}
```

**2. Action Cache Chunking** (2-3 days)
```d
// Add to source/caching/actions/action.d
void syncToRemote(RemoteCacheClient cacheClient)
{
    auto cacheData = serializeCache();
    auto tempFile = ".builder-cache/actions-temp.bin";
    write(tempFile, cacheData);
    
    auto result = cacheClient.updateFileChunked(tempFile, newHash, oldHash);
    writeln("Action cache synced: ", result.unwrap().chunksTransferred, " chunks");
}
```

### Phase 2: Medium Wins (P1)

**3. Distributed Worker Chunking** (3-5 days)
- Modify protocol to support chunk references
- Implement chunk-based action data transfer
- Add chunk deduplication across workers

### Phase 3: Nice-to-Have (P2)

**4-7. Parse Cache, Telemetry, Test Fixtures**
- Implement as needed based on user demand
- Lower priority but significant bandwidth savings

## Expected Impact

### Overall Bandwidth Savings (All P0+P1 Implemented)

**Typical CI/CD Pipeline:**
- 20 builds/day
- 10 stages per build
- 500 MB artifacts per stage

**Current:**
- Graph cache: 10 MB × 200 = 2 GB/day
- Action cache: 25 MB × 200 = 5 GB/day
- Worker comm: 100 MB × 200 = 20 GB/day
- **Total: 27 GB/day**

**With Chunking:**
- Graph cache: 0.5 MB × 200 = 100 MB/day (95% saved)
- Action cache: 1 MB × 200 = 200 MB/day (96% saved)
- Worker comm: 5 MB × 200 = 1 GB/day (95% saved)
- **Total: 1.3 GB/day** (95% saved)

**Annual Savings:**
- **9.6 TB/year bandwidth saved**
- At $0.08/GB egress: **$768/year saved per CI/CD cluster**

## Code Reuse

All opportunities can reuse the existing chunking infrastructure:

```d
import utils.files.chunking;
import caching.distributed.remote.client;

// Universal pattern:
auto result = cacheClient.putFileChunked(filePath, fileHash);
auto stats = result.unwrap().stats;
writeln("Saved ", stats.savingsPercent(), "% bandwidth");
```

**Key Insight:** The investment in content-defined chunking has multiplicative returns across the entire codebase.

## Conclusion

Content-defined chunking is not just for artifact uploads—it's a **cross-cutting optimization** that can save 80-95% bandwidth across:

1. ✅ Artifact store uploads (Done)
2. ✅ Distributed cache transfers (Done)
3. ✅ Language-specific outputs (Done via ArtifactManager)
4. 🔴 **Graph cache sync** (P0 - High Impact, Low Effort)
5. 🔴 **Action cache sync** (P0 - High Impact, Medium Effort)
6. 🟠 **Distributed worker communication** (P1 - High Impact, Medium-High Effort)
7. 🟡 Parse cache, telemetry, test fixtures (P2 - Medium Impact)

**Recommendation:** Implement P0 items (Graph + Action cache) next for maximum ROI with minimal effort.

