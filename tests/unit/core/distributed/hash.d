module tests.unit.core.distributed.hash;

import engine.distributed.coordinator.hash;
import engine.distributed.protocol.protocol : WorkerId;
import std.conv : to;

/// Test Jump Hash distribution and consistency
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing Jump Hash distribution...");
    
    // Test distribution across 10 buckets with 10000 keys
    size_t[10] counts;
    foreach (i; 0 .. 10000)
        counts[JumpHash.hash(cast(ulong)i, 10)]++;
    
    // Check roughly uniform distribution (within 20%)
    foreach (idx, c; counts)
    {
        assert(c > 800 && c < 1200, 
            "Poor distribution in bucket " ~ idx.to!string ~ ": " ~ c.to!string);
    }
    
    writeln("  Distribution test passed: all buckets within expected range");
}

/// Test Jump Hash monotonicity (key stability when adding buckets)
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing Jump Hash monotonicity...");
    
    // When adding a bucket, most keys should stay in same bucket
    size_t movedCount = 0;
    foreach (i; 0 .. 1000)
    {
        immutable key = cast(ulong)(i * 12345);
        immutable bucket5 = JumpHash.hash(key, 5);
        immutable bucket6 = JumpHash.hash(key, 6);
        
        // Key can only move to the new bucket (5) or stay
        if (bucket5 != bucket6)
        {
            assert(bucket6 == 5, "Key moved to unexpected bucket");
            movedCount++;
        }
    }
    
    // Approximately 1/6 of keys should move to new bucket
    auto moveRate = cast(float)movedCount / 1000.0;
    assert(moveRate > 0.12 && moveRate < 0.22, 
        "Unexpected move rate: " ~ moveRate.to!string);
    
    writeln("  Monotonicity test passed: move rate = ", moveRate);
}

/// Test AffinityKey BLAKE3 hashing
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing AffinityKey BLAKE3 hashing...");
    
    auto key1 = AffinityKey("Rust", "rustc-1.75");
    auto key2 = AffinityKey("Rust", "rustc-1.75");
    auto key3 = AffinityKey("D", "dmd");
    auto key4 = AffinityKey("Rust", "rustc-1.76");
    
    // Same keys produce same hash
    assert(key1.toHash() == key2.toHash(), "Identical keys should hash same");
    
    // Different keys produce different hashes
    assert(key1.toHash() != key3.toHash(), "Different language keys should differ");
    assert(key1.toHash() != key4.toHash(), "Different toolchain keys should differ");
    
    // Empty toolchain is distinct from non-empty
    auto keyNoToolchain = AffinityKey("Rust", "");
    assert(key1.toHash() != keyNoToolchain.toHash(), 
        "Empty toolchain should produce different hash");
    
    writeln("  BLAKE3 hashing test passed");
}

/// Test AffinitySelector basic operations
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing AffinitySelector basic operations...");
    
    auto selector = new AffinitySelector();
    
    // Add workers
    selector.addWorker(WorkerId(1));
    selector.addWorker(WorkerId(2));
    selector.addWorker(WorkerId(3));
    selector.addWorker(WorkerId(4));
    selector.addWorker(WorkerId(5));
    
    assert(selector.workerCount() == 5, "Worker count mismatch");
    
    auto affinity = AffinityKey("Rust", "rustc-1.75");
    
    // Selection should be consistent
    auto result1 = selector.selectWorker(affinity);
    auto result2 = selector.selectWorker(affinity);
    
    assert(result1.isOk && result2.isOk, "Selection failed");
    assert(result1.unwrap() == result2.unwrap(), 
        "Consistent hash should return same worker");
    
    // Different affinities should (likely) map to different workers
    auto affinityD = AffinityKey("D", "dmd");
    auto affinityGo = AffinityKey("Go", "");
    
    auto resultD = selector.selectWorker(affinityD);
    auto resultGo = selector.selectWorker(affinityGo);
    
    assert(resultD.isOk && resultGo.isOk, "Selection failed for different affinities");
    
    writeln("  Basic operations test passed");
}

/// Test AffinitySelector fallbacks
@system unittest
{
    import std.stdio : writeln;
    import std.algorithm : uniq;
    import std.array : array;
    
    writeln("Testing AffinitySelector fallbacks...");
    
    auto selector = new AffinitySelector();
    
    foreach (i; 1 .. 6)
        selector.addWorker(WorkerId(i));
    
    auto affinity = AffinityKey("TypeScript", "tsc-5.0");
    auto fallbacks = selector.selectWithFallbacks(affinity, 3);
    
    assert(fallbacks.length == 3, "Expected 3 fallback workers");
    
    // All fallbacks should be unique
    auto uniqueFallbacks = fallbacks.uniq.array;
    assert(uniqueFallbacks.length == 3, "Fallbacks should be unique");
    
    writeln("  Fallbacks test passed");
}

/// Test worker removal and tombstone handling
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing worker removal...");
    
    auto selector = new AffinitySelector();
    
    foreach (i; 1 .. 6)
        selector.addWorker(WorkerId(i));
    
    auto affinity = AffinityKey("Python", "python3");
    auto resultBefore = selector.selectWorker(affinity);
    assert(resultBefore.isOk, "Selection failed before removal");
    
    auto selectedWorker = resultBefore.unwrap();
    
    // Remove the selected worker
    selector.removeWorker(selectedWorker);
    
    assert(selector.workerCount() == 4, "Worker count should decrease");
    
    // Selection should still work, possibly returning different worker
    auto resultAfter = selector.selectWorker(affinity);
    assert(resultAfter.isOk, "Selection failed after removal");
    assert(resultAfter.unwrap() != selectedWorker, 
        "Should not return removed worker");
    
    writeln("  Worker removal test passed");
}

/// Test compaction
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing compaction...");
    
    auto selector = new AffinitySelector();
    
    foreach (i; 1 .. 11)
        selector.addWorker(WorkerId(i));
    
    // Remove half the workers
    foreach (i; 1 .. 6)
        selector.removeWorker(WorkerId(i));
    
    assert(selector.workerCount() == 5, "Worker count after removal");
    
    // Compact to remove tombstones
    selector.compact();
    
    assert(selector.workerCount() == 5, "Worker count should be same after compact");
    
    // Selection should still work
    auto result = selector.selectWorker(AffinityKey("Java", "javac"));
    assert(result.isOk, "Selection failed after compaction");
    
    writeln("  Compaction test passed");
}

/// Test KetamaRing basic functionality
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing KetamaRing...");
    
    auto ring = new KetamaRing();
    
    ring.addWorker(WorkerId(1), 1);
    ring.addWorker(WorkerId(2), 2);  // Higher weight = more traffic
    ring.addWorker(WorkerId(3), 1);
    
    assert(ring.workerCount() == 3, "Ring worker count");
    
    auto affinity = AffinityKey("Kotlin", "kotlinc");
    
    // Selection should be consistent
    auto result1 = ring.getWorker(affinity);
    auto result2 = ring.getWorker(affinity);
    
    assert(result1.isOk && result2.isOk, "Ring selection failed");
    assert(result1.unwrap() == result2.unwrap(), "Ring selection inconsistent");
    
    // Get multiple workers for replication
    auto workers = ring.getWorkers(affinity, 3);
    assert(workers.length == 3, "Expected 3 workers from ring");
    
    writeln("  KetamaRing test passed");
}

/// Test weighted distribution in KetamaRing
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing KetamaRing weighted distribution...");
    
    auto ring = new KetamaRing();
    
    // Worker 1 has weight 1, Worker 2 has weight 4
    ring.addWorker(WorkerId(1), 1);
    ring.addWorker(WorkerId(2), 4);
    
    size_t worker1Count = 0;
    size_t worker2Count = 0;
    
    // Sample many affinities
    foreach (i; 0 .. 1000)
    {
        auto affinity = AffinityKey("Lang" ~ i.to!string, "");
        auto result = ring.getWorker(affinity);
        if (result.isOk)
        {
            if (result.unwrap().value == 1) worker1Count++;
            else if (result.unwrap().value == 2) worker2Count++;
        }
    }
    
    // Worker 2 should get ~4x more traffic
    auto ratio = cast(float)worker2Count / worker1Count;
    assert(ratio > 2.5 && ratio < 6.0, 
        "Weight ratio unexpected: " ~ ratio.to!string);
    
    writeln("  Weighted distribution test passed: ratio = ", ratio);
}

/// Test affinity extraction from commands
unittest
{
    import std.stdio : writeln;
    
    writeln("Testing affinity extraction...");
    
    // D compilers
    auto dmd = extractAffinity("dmd -O main.d", null);
    assert(dmd.language == "D", "DMD not detected");
    assert(dmd.toolchain == "dmd", "DMD toolchain not captured");
    
    auto ldc = extractAffinity("ldc2 -O3 main.d", null);
    assert(ldc.language == "D", "LDC not detected");
    
    // Rust
    auto cargo = extractAffinity("cargo build --release", null);
    assert(cargo.language == "Rust", "Cargo not detected");
    
    auto rustc = extractAffinity("rustc main.rs", null);
    assert(rustc.language == "Rust", "Rustc not detected");
    
    // TypeScript/JavaScript
    auto tsc = extractAffinity("tsc --build", null);
    assert(tsc.language == "TypeScript", "TSC not detected");
    
    auto node = extractAffinity("node index.js", null);
    assert(node.language == "JavaScript", "Node not detected");
    
    // Go
    auto goCmd = extractAffinity("go build ./...", null);
    assert(goCmd.language == "Go", "Go not detected");
    
    // C/C++
    auto gcc = extractAffinity("gcc -O2 main.c", null);
    assert(gcc.language == "Cpp", "GCC not detected");
    
    auto clang = extractAffinity("clang++ -std=c++20 main.cpp", null);
    assert(clang.language == "Cpp", "Clang++ not detected");
    
    // Environment override
    string[string] env = ["BLDR_LANGUAGE": "OCaml", "BLDR_TOOLCHAIN": "ocamlopt"];
    auto envAffinity = extractAffinity("some random command", env);
    assert(envAffinity.language == "OCaml", "Env override not applied");
    assert(envAffinity.toolchain == "ocamlopt", "Env toolchain not applied");
    
    // Unknown command
    auto unknown = extractAffinity("custom-build-tool", null);
    assert(unknown.language == "Generic", "Unknown should map to Generic");
    
    writeln("  Affinity extraction test passed");
}

/// Test affinity cache in selector
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing affinity cache...");
    
    auto selector = new AffinitySelector();
    
    foreach (i; 1 .. 6)
        selector.addWorker(WorkerId(i));
    
    auto affinity = AffinityKey("Haskell", "ghc");
    
    // Select worker to populate cache
    auto result = selector.selectWorker(affinity);
    assert(result.isOk, "Selection failed");
    
    auto worker = result.unwrap();
    
    // Check affinity was recorded
    assert(selector.hasAffinity(worker, affinity), 
        "Affinity should be cached after selection");
    
    // Get cached workers
    auto cachedWorkers = selector.getAffinityWorkers(affinity);
    assert(cachedWorkers.length > 0, "Should have cached workers");
    
    import std.algorithm : canFind;
    assert(cachedWorkers.canFind(worker), "Selected worker should be in cache");
    
    writeln("  Affinity cache test passed");
}

/// Integration test: simulate workload distribution
@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing workload distribution simulation...");
    
    auto selector = new AffinitySelector();
    
    // Add 10 workers
    foreach (i; 1 .. 11)
        selector.addWorker(WorkerId(i));
    
    // Simulate workload with various languages
    string[] languages = ["D", "Rust", "Go", "TypeScript", "Python", 
                          "Java", "Kotlin", "Cpp", "Swift", "Zig"];
    
    size_t[WorkerId] workerLoads;
    
    // Send 1000 actions
    foreach (i; 0 .. 1000)
    {
        auto lang = languages[i % languages.length];
        auto affinity = AffinityKey(lang, "");
        
        auto result = selector.selectWorker(affinity);
        if (result.isOk)
        {
            auto worker = result.unwrap();
            workerLoads[worker] = workerLoads.get(worker, 0) + 1;
        }
    }
    
    // Each language should consistently route to same worker
    // So with 10 languages and 10 workers, expect reasonable distribution
    size_t minLoad = size_t.max;
    size_t maxLoad = 0;
    
    foreach (load; workerLoads.byValue)
    {
        if (load < minLoad) minLoad = load;
        if (load > maxLoad) maxLoad = load;
    }
    
    // Check balance (not perfect due to consistent hashing, but reasonable)
    auto imbalance = cast(float)(maxLoad - minLoad) / maxLoad;
    assert(imbalance < 0.5, "Extreme load imbalance: " ~ imbalance.to!string);
    
    writeln("  Workload distribution test passed: imbalance = ", imbalance);
}

