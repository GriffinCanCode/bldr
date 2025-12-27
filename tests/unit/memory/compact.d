module tests.unit.memory.compact;

import infrastructure.utils.memory.compact;
import infrastructure.utils.memory.refs;

/// Test CompactRef basic operations
@system unittest
{
    // Basic equality
    auto r1 = CompactRef(0, 12345);
    auto r2 = CompactRef(0, 12345);
    auto r3 = CompactRef(1, 12345);
    
    assert(r1 == r2, "Same index+hash should be equal");
    assert(r1 != r3, "Different index should not be equal");
    assert(r1.toHash() == 12345, "Hash should return hash32");
    assert(r1.isValid, "Non-max index should be valid");
    assert(!CompactRef.invalid.isValid, "Invalid sentinel should not be valid");
}

/// Test CompactRef serialization
@system unittest
{
    auto original = CompactRef(42, 0xDEADBEEF);
    auto bytes = original.serialize();
    auto restored = CompactRef.deserialize(bytes);
    
    assert(restored == original, "Roundtrip should preserve value");
    assert(restored.index == 42, "Index should be preserved");
    assert(restored.hash32 == 0xDEADBEEF, "Hash should be preserved");
}

/// Test Registry deduplication
@system unittest
{
    auto registry = new Registry!string(16);
    
    auto ref1 = registry.register!fnv64("hello");
    auto ref2 = registry.register!fnv64("hello");
    auto ref3 = registry.register!fnv64("world");
    
    assert(ref1 == ref2, "Same value should return same ref");
    assert(ref1 != ref3, "Different values should return different refs");
    assert(registry.count == 2, "Should have 2 unique entries");
}

/// Test Registry resolution
@system unittest
{
    auto registry = new Registry!string(16);
    
    auto ref1 = registry.register!fnv64("alpha");
    auto ref2 = registry.register!fnv64("beta");
    
    assert(registry.resolve(ref1) == "alpha", "Should resolve to original");
    assert(registry.resolve(ref2) == "beta", "Should resolve to original");
    assert(registry.resolve(CompactRef.invalid) == "", "Invalid should return init");
}

/// Test TargetRef basic operations
@system unittest
{
    auto data = TargetIdData("", "", "mylib");
    auto ref1 = TargetRef.from(data);
    auto ref2 = TargetRef.from(data);
    
    assert(ref1 == ref2, "Same target should deduplicate");
    assert(ref1.isValid, "Should be valid");
    
    auto resolved = ref1.resolve();
    assert(resolved.simpleName() == "mylib", "Should resolve correctly");
}

/// Test TargetRef with qualified names
@system unittest
{
    auto data = TargetIdData("workspace", "path/to", "target");
    auto ref_ = TargetRef.from(data);
    
    assert(ref_.toString() == "workspace//path/to:target", "Should format correctly");
}

/// Test TargetIdData <-> TargetRef conversion
@system unittest
{
    // Create target data
    auto original = TargetIdData("ws", "pkg/sub", "lib");
    
    // Convert to compact ref
    auto ref_ = TargetRef.from(original);
    assert(ref_.isValid, "Ref should be valid");
    
    // Convert back
    auto restored = ref_.resolve();
    assert(restored.workspace.toString() == "ws", "Workspace should match");
    assert(restored.path.toString() == "pkg/sub", "Path should match");
    assert(restored.name.toString() == "lib", "Name should match");
    assert(restored.toString() == original.toString(), "String repr should match");
}

/// Test batch operations
@system unittest
{
    TargetIdData[] data = [
        TargetIdData("", "", "a"),
        TargetIdData("", "", "b"),
        TargetIdData("", "", "c")
    ];
    
    auto refs = batchRegister(data);
    assert(refs.length == 3, "Should have 3 refs");
    
    auto resolved = batchResolve(refs);
    assert(resolved.length == 3, "Should resolve 3");
    assert(resolved[0].simpleName() == "a");
    assert(resolved[1].simpleName() == "b");
    assert(resolved[2].simpleName() == "c");
}

/// Test TargetRef as associative array key
@system unittest
{
    auto ref1 = TargetRef.from(TargetIdData("", "", "key"));
    auto ref2 = TargetRef.from(TargetIdData("", "", "key"));
    
    int[TargetRef] map;
    map[ref1] = 42;
    assert(ref2 in map, "Same key should be found");
    assert(map[ref2] == 42, "Should retrieve correct value");
}

/// Test memory efficiency
@system unittest
{
    // CompactRef should be exactly 8 bytes
    assert(CompactRef.sizeof == 8, "CompactRef should be 8 bytes");
    
    // TargetRef wraps CompactRef
    assert(TargetRef.sizeof == 8, "TargetRef should be 8 bytes");
}

/// Test FNV-64 hash function
@system unittest
{
    assert(fnv64("hello") != fnv64("world"), "Different strings should hash differently");
    assert(fnv64("test") == fnv64("test"), "Same string should hash same");
    assert(fnv64("") != fnv64("a"), "Empty vs non-empty should differ");
}

/// Test hash combining
@system unittest
{
    auto h1 = fnv64("a");
    auto h2 = fnv64("b");
    
    auto combined = hashCombine(h1, h2);
    assert(combined != h1, "Combined should differ from inputs");
    assert(combined != h2, "Combined should differ from inputs");
    
    // Deterministic
    assert(hashCombine(h1, h2) == hashCombine(h1, h2), "Should be deterministic");
}

/// Performance test: O(1) comparison vs O(n) string comparison
version(none) @system unittest
{
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.stdio : writefln;
    
    // Create many targets
    enum N = 100_000;
    TargetRef[] refs;
    refs.reserve(N);
    
    foreach (i; 0 .. N)
    {
        import std.conv : to;
        refs ~= TargetRef.from(TargetIdData("ws", "path", "target" ~ i.to!string));
    }
    
    // Benchmark equality comparisons
    auto sw = StopWatch(AutoStart.yes);
    size_t matches = 0;
    
    foreach (r; refs)
        if (r == refs[0])
            matches++;
    
    sw.stop();
    writefln("CompactRef: %d comparisons in %s µs", N, sw.peek.total!"usecs");
    
    // Should be ~1 match (itself if refs[0] appears multiple times due to dedup)
    assert(matches >= 1);
}

