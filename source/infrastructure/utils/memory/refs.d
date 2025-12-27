module infrastructure.utils.memory.refs;

import infrastructure.utils.memory.compact;
import infrastructure.utils.memory.intern : StringPool, Intern;
import core.atomic;

/// Compact target reference: 8-byte handle for TargetId
/// 
/// Replaces ~100+ byte TargetId in hot paths with O(1) operations.
/// Full TargetId recoverable via global registry lookup.
/// 
/// Usage:
///   auto ref_ = TargetRef.from(targetId);  // Register and get compact ref
///   auto id = ref_.resolve();              // Recover full TargetId
///   if (ref1 == ref2) { }                  // O(1) comparison
/// 
/// Memory Layout (8 bytes):
///   [index: 4 bytes][hash32: 4 bytes]
struct TargetRef
{
    private CompactRef _ref;
    
    private this(CompactRef ref_) pure nothrow @safe @nogc { _ref = ref_; }
    
    /// Invalid/uninitialized reference sentinel
    enum invalid = TargetRef(CompactRef.invalid);
    
    /// Create from TargetId (registers if new)
    static TargetRef from(TargetIdData id) @trusted =>
        TargetRef(targetRegistry.register!targetHash(id));
    
    /// Resolve to full TargetId
    TargetIdData resolve() const @trusted =>
        targetRegistry.resolve(_ref);
    
    /// O(1) equality
    bool opEquals(const TargetRef other) const pure nothrow @safe @nogc =>
        _ref == other._ref;
    
    /// O(1) hashing
    size_t toHash() const pure nothrow @safe @nogc => _ref.toHash();
    
    /// Comparison for sorting
    int opCmp(const TargetRef other) const pure nothrow @safe @nogc =>
        _ref.opCmp(other._ref);
    
    /// Get underlying index (for indexed array access)
    @property uint index() const pure nothrow @safe @nogc => _ref.index;
    @property bool isValid() const pure nothrow @safe @nogc => _ref.isValid;
    
    /// Get string representation (resolves and converts)
    string toString() const @trusted
    {
        if (!isValid) return "<invalid>";
        auto data = resolve();
        return data.toString();
    }
    
    /// Serialize to 8 bytes
    ubyte[8] serialize() const pure nothrow @safe @nogc => _ref.serialize();
    
    /// Deserialize from 8 bytes
    static TargetRef deserialize(const ubyte[8] data) pure nothrow @safe @nogc =>
        TargetRef(CompactRef.deserialize(data));
}

/// Internal target data structure (stored in registry)
/// Mirrors TargetId fields but owns interned strings
struct TargetIdData
{
    Intern workspace;
    Intern path;
    Intern name;
    private string _cachedString;
    
    /// Create from components
    this(string ws, string p, string n) @system
    {
        auto pool = targetStringPool;
        workspace = pool.intern(ws);
        path = pool.intern(p);
        name = pool.intern(n);
        _cachedString = computeString(ws, p, n);
    }
    
    /// Empty/default state
    static TargetIdData init() @system =>
        TargetIdData("", "", "");
    
    /// Compute string representation
    private static string computeString(string ws, string p, string n) pure nothrow @system
    {
        if (ws.length == 0 && p.length == 0) return n;
        if (ws.length == 0) return "//" ~ p ~ ":" ~ n;
        if (p.length == 0) return ws ~ "//:" ~ n;
        return ws ~ "//" ~ p ~ ":" ~ n;
    }
    
    /// Get cached string representation
    string toString() const @system =>
        _cachedString.length > 0 ? _cachedString : "";
    
    /// O(1) equality (interned pointer comparison)
    bool opEquals(const TargetIdData other) const pure nothrow @nogc @system =>
        workspace == other.workspace &&
        path == other.path &&
        name == other.name;
    
    /// Simple name accessor
    string simpleName() const @system => name.toString();
    
    /// Check if simple (no workspace/path)
    bool isSimple() const @system =>
        workspace.empty && path.empty;
}

/// Hash function for TargetIdData
private ulong targetHash(TargetIdData data) @system
{
    auto h1 = fnv64(data.workspace.toString());
    auto h2 = fnv64(data.path.toString());
    auto h3 = fnv64(data.name.toString());
    return hashCombine(hashCombine(h1, h2), h3);
}

// ============================================================================
// Global Registry (Module-level singleton)
// ============================================================================

private __gshared Registry!TargetIdData _targetRegistry;
private __gshared StringPool _targetStringPool;
private shared bool _initialized;

/// Get global target registry
@property Registry!TargetIdData targetRegistry() @trusted
{
    if (!atomicLoad(_initialized))
        initializeRegistry();
    return _targetRegistry;
}

/// Get global string pool for targets
@property StringPool targetStringPool() @trusted
{
    if (!atomicLoad(_initialized))
        initializeRegistry();
    return _targetStringPool;
}

/// Initialize global registry (thread-safe, idempotent)
private void initializeRegistry() @trusted
{
    import core.sync.mutex : Mutex;
    __gshared Mutex initMutex;
    
    if (initMutex is null)
        initMutex = new Mutex();
    
    synchronized (initMutex)
    {
        if (atomicLoad(_initialized))
            return;
        
        _targetStringPool = new StringPool();
        _targetRegistry = new Registry!TargetIdData(4096);
        atomicStore(_initialized, true);
    }
}

/// Get registry statistics
struct TargetRefStats
{
    size_t registeredTargets;
    size_t internedStrings;
    size_t memoryBytes;
    
    static TargetRefStats get() @trusted
    {
        TargetRefStats stats;
        stats.registeredTargets = targetRegistry.count;
        stats.internedStrings = targetStringPool.size;
        // Estimate: 8 bytes per ref + ~32 bytes avg per interned string
        stats.memoryBytes = stats.registeredTargets * 8 +
                           stats.internedStrings * 32;
        return stats;
    }
}

// ============================================================================
// Batch Operations (Optimized for hot paths)
// ============================================================================

/// Convert multiple TargetIds to TargetRefs in batch
TargetRef[] batchRegister(T)(T[] ids) @trusted
    if (is(T == TargetIdData) || __traits(hasMember, T, "workspace"))
{
    TargetRef[] refs;
    refs.reserve(ids.length);
    
    foreach (ref id; ids)
    {
        static if (is(T == TargetIdData))
            refs ~= TargetRef.from(id);
        else
            refs ~= TargetRef.from(TargetIdData(id.workspace, id.path, id.name));
    }
    return refs;
}

/// Resolve multiple TargetRefs in batch (reduces lock acquisitions)
TargetIdData[] batchResolve(const TargetRef[] refs) @trusted
{
    CompactRef[] compactRefs;
    compactRefs.reserve(refs.length);
    foreach (ref r; refs)
        compactRefs ~= r._ref;
    
    return targetRegistry.resolveMany(compactRefs);
}

// ============================================================================
// Unit Tests
// ============================================================================

unittest
{
    // Basic registration and resolution
    auto data1 = TargetIdData("", "", "mylib");
    auto ref1 = TargetRef.from(data1);
    auto ref2 = TargetRef.from(data1);  // Same data
    
    // Deduplication
    assert(ref1 == ref2);
    assert(ref1.index == ref2.index);
    
    // Resolution
    auto resolved = ref1.resolve();
    assert(resolved.simpleName() == "mylib");
}

unittest
{
    // Different targets get different refs
    auto ref1 = TargetRef.from(TargetIdData("", "", "target1"));
    auto ref2 = TargetRef.from(TargetIdData("", "", "target2"));
    
    assert(ref1 != ref2);
    assert(ref1.resolve().simpleName() == "target1");
    assert(ref2.resolve().simpleName() == "target2");
}

unittest
{
    // Full qualified name
    auto data = TargetIdData("workspace", "path/to", "target");
    auto ref_ = TargetRef.from(data);
    
    assert(ref_.toString() == "workspace//path/to:target");
}

unittest
{
    // Serialization roundtrip
    auto original = TargetRef.from(TargetIdData("ws", "p", "n"));
    auto bytes = original.serialize();
    auto restored = TargetRef.deserialize(bytes);
    
    assert(restored == original);
    assert(restored.resolve().simpleName() == "n");
}

unittest
{
    // Invalid ref handling
    auto invalid = TargetRef.invalid;
    assert(!invalid.isValid);
    assert(invalid.toString() == "<invalid>");
}

unittest
{
    // Batch operations
    TargetIdData[] data = [
        TargetIdData("", "", "a"),
        TargetIdData("", "", "b"),
        TargetIdData("", "", "c")
    ];
    
    auto refs = batchRegister(data);
    assert(refs.length == 3);
    
    auto resolved = batchResolve(refs);
    assert(resolved.length == 3);
    assert(resolved[0].simpleName() == "a");
    assert(resolved[1].simpleName() == "b");
    assert(resolved[2].simpleName() == "c");
}

unittest
{
    // Hash and equality for use as AA keys
    auto ref1 = TargetRef.from(TargetIdData("", "", "key"));
    auto ref2 = TargetRef.from(TargetIdData("", "", "key"));
    
    int[TargetRef] map;
    map[ref1] = 42;
    assert(map[ref2] == 42);  // Same key via equality
}

@system unittest
{
    import std.parallelism : parallel;
    import std.range : iota;
    
    // Thread safety
    foreach (_; parallel(iota(100)))
    {
        auto r1 = TargetRef.from(TargetIdData("", "", "concurrent"));
        auto r2 = TargetRef.from(TargetIdData("", "", "test"));
        assert(r1.resolve().simpleName() == "concurrent");
        assert(r2.resolve().simpleName() == "test");
    }
}

