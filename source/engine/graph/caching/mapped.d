module engine.graph.caching.mapped;

import std.file : read, write, remove, mkdirRecurse, getSize, rmdirRecurse, tempDir;
import stdfile = std.file;
import std.path : buildPath, dirName;
import std.bitmanip : nativeToLittleEndian, littleEndianToNative;
import std.exception : collectException;
import std.conv : to;
import std.datetime : Clock;
import core.sync.mutex : Mutex;

import engine.graph.core.graph;
import engine.graph.caching.schema;
import infrastructure.config.schema.schema;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode, MapAdvice;
import infrastructure.utils.serialization;
import infrastructure.errors;

/// Memory-mapped graph format header (v2 with config hash for watch mode)
private struct MappedGraphHeader
{
    ubyte[4] magic = ['B', 'G', 'R', 'P'];  // "BGRP" = Builder Graph
    uint version_ = 2;                       // v2: added configHash for watch mode
    uint flags;
    ulong nodeCount;
    ulong edgeCount;
    ulong nodeTableOffset;
    ulong edgeTableOffset;
    ulong stringTableOffset;
    ulong stringTableSize;
    ubyte[32] contentHash;
    ubyte[32] configHash;                    // Hash of config files for instant validation
    ulong timestamp;                         // Persistence timestamp for staleness check
    
    enum HEADER_SIZE = 136;  // Fixed header size for v2
    
    /// Serialize header to bytes
    ubyte[HEADER_SIZE] serialize() const @safe nothrow
    {
        ubyte[HEADER_SIZE] result;
        result[0 .. 4] = magic[];
        result[4 .. 8] = nativeToLittleEndian(version_)[];
        result[8 .. 12] = nativeToLittleEndian(flags)[];
        result[12 .. 20] = nativeToLittleEndian(nodeCount)[];
        result[20 .. 28] = nativeToLittleEndian(edgeCount)[];
        result[28 .. 36] = nativeToLittleEndian(nodeTableOffset)[];
        result[36 .. 44] = nativeToLittleEndian(edgeTableOffset)[];
        result[44 .. 52] = nativeToLittleEndian(stringTableOffset)[];
        result[52 .. 60] = nativeToLittleEndian(stringTableSize)[];
        result[60 .. 92] = contentHash[];
        result[92 .. 124] = configHash[];
        result[124 .. 132] = nativeToLittleEndian(timestamp)[];
        return result;
    }
    
    /// Deserialize header from bytes
    static MappedGraphHeader deserialize(const(ubyte)[] data) @safe nothrow
    {
        MappedGraphHeader h;
        if (data.length < HEADER_SIZE) return h;
        
        h.magic = data[0 .. 4][0 .. 4];
        h.version_ = littleEndianToNative!uint(data[4 .. 8][0 .. 4]);
        h.flags = littleEndianToNative!uint(data[8 .. 12][0 .. 4]);
        h.nodeCount = littleEndianToNative!ulong(data[12 .. 20][0 .. 8]);
        h.edgeCount = littleEndianToNative!ulong(data[20 .. 28][0 .. 8]);
        h.nodeTableOffset = littleEndianToNative!ulong(data[28 .. 36][0 .. 8]);
        h.edgeTableOffset = littleEndianToNative!ulong(data[36 .. 44][0 .. 8]);
        h.stringTableOffset = littleEndianToNative!ulong(data[44 .. 52][0 .. 8]);
        h.stringTableSize = littleEndianToNative!ulong(data[52 .. 60][0 .. 8]);
        h.contentHash = data[60 .. 92][0 .. 32];
        h.configHash = data[92 .. 124][0 .. 32];
        h.timestamp = littleEndianToNative!ulong(data[124 .. 132][0 .. 8]);
        return h;
    }
    
    /// Validate header (accepts v1 or v2)
    bool valid() const @safe pure nothrow @nogc =>
        magic == ['B', 'G', 'R', 'P'] && (version_ == 1 || version_ == 2);
}

/// Fixed-size node record for memory-mapped access
private struct MappedNode
{
    ulong targetIdOffset;      // Offset into string table
    ushort targetIdLength;
    ubyte status;              // BuildStatus
    ubyte targetType;          // Target type enum
    ulong outputPathOffset;    // Offset into string table
    ushort outputPathLength;
    ubyte[32] hash;
    ulong firstEdgeIndex;      // Index into edge table
    ushort edgeCount;          // Number of dependencies
    ushort dependentCount;     // Number of dependents
    uint retryAttempts;
    uint depth;
    ubyte[16] _reserved;       // Future use
    
    enum SIZE = 96;  // Fixed record size
    
    /// Serialize to bytes
    ubyte[SIZE] serialize() const @safe nothrow
    {
        ubyte[SIZE] result;
        result[0 .. 8] = nativeToLittleEndian(targetIdOffset)[];
        result[8 .. 10] = nativeToLittleEndian(targetIdLength)[];
        result[10] = status;
        result[11] = targetType;
        result[12 .. 20] = nativeToLittleEndian(outputPathOffset)[];
        result[20 .. 22] = nativeToLittleEndian(outputPathLength)[];
        result[22 .. 54] = hash[];
        result[54 .. 62] = nativeToLittleEndian(firstEdgeIndex)[];
        result[62 .. 64] = nativeToLittleEndian(edgeCount)[];
        result[64 .. 66] = nativeToLittleEndian(dependentCount)[];
        result[66 .. 70] = nativeToLittleEndian(retryAttempts)[];
        result[70 .. 74] = nativeToLittleEndian(depth)[];
        return result;
    }
    
    /// Deserialize from bytes
    static MappedNode deserialize(const(ubyte)[] data) @safe nothrow
    {
        MappedNode n;
        if (data.length < SIZE) return n;
        
        n.targetIdOffset = littleEndianToNative!ulong(data[0 .. 8][0 .. 8]);
        n.targetIdLength = littleEndianToNative!ushort(data[8 .. 10][0 .. 2]);
        n.status = data[10];
        n.targetType = data[11];
        n.outputPathOffset = littleEndianToNative!ulong(data[12 .. 20][0 .. 8]);
        n.outputPathLength = littleEndianToNative!ushort(data[20 .. 22][0 .. 2]);
        n.hash = data[22 .. 54][0 .. 32];
        n.firstEdgeIndex = littleEndianToNative!ulong(data[54 .. 62][0 .. 8]);
        n.edgeCount = littleEndianToNative!ushort(data[62 .. 64][0 .. 2]);
        n.dependentCount = littleEndianToNative!ushort(data[64 .. 66][0 .. 2]);
        n.retryAttempts = littleEndianToNative!uint(data[66 .. 70][0 .. 4]);
        n.depth = littleEndianToNative!uint(data[70 .. 74][0 .. 4]);
        return n;
    }
}

/// Edge record (8 bytes)
private struct MappedEdge
{
    uint fromIndex;  // Source node index
    uint toIndex;    // Target node index
    
    enum SIZE = 8;
    
    ubyte[SIZE] serialize() const @safe nothrow
    {
        ubyte[SIZE] result;
        result[0 .. 4] = nativeToLittleEndian(fromIndex)[];
        result[4 .. 8] = nativeToLittleEndian(toIndex)[];
        return result;
    }
    
    static MappedEdge deserialize(const(ubyte)[] data) @safe nothrow
    {
        MappedEdge e;
        if (data.length < SIZE) return e;
        e.fromIndex = littleEndianToNative!uint(data[0 .. 4][0 .. 4]);
        e.toIndex = littleEndianToNative!uint(data[4 .. 8][0 .. 4]);
        return e;
    }
}

/// Zero-copy graph view backed by memory mapping
/// 
/// Design:
/// - Graph file is memory-mapped directly
/// - No deserialization overhead on load
/// - Nodes accessed via direct pointer arithmetic
/// - Strings accessed via offset into string table
/// - Lazy loading via page faults
/// 
/// Layout:
/// ```
/// [Header: 96 bytes]
/// [Node Table: nodeCount * 96 bytes]
/// [Edge Table: edgeCount * 8 bytes]
/// [String Table: variable]
/// ```
final class MappedGraphView
{
    private MmapRegion _region;
    private MappedGraphHeader _header;
    private bool _valid;
    
    private this() {}
    
    /// Open memory-mapped graph
    static BuildResult!MappedGraphView open(string path) @system
    {
        if (!stdfile.exists(path))
            return Err!(MappedGraphView, BuildError)(
                Errors.cache("Graph file not found: " ~ path, ErrorCode.CacheNotFound).build()
            );
        
        string mapError;
        auto region = MmapRegion.map(path, MapMode.ReadOnly, 0, 0, &mapError);
        if (region is null)
            return Err!(MappedGraphView, BuildError)(
                Errors.cache("Failed to map graph: " ~ mapError, ErrorCode.CacheLoadFailed).build()
            );
        
        auto view = new MappedGraphView();
        view._region = region;
        
        // Parse header (v2 is 136 bytes, v1 was 96)
        auto data = region[];
        if (data.length < MappedGraphHeader.HEADER_SIZE)
        {
            region.unmap();
            return Err!(MappedGraphView, BuildError)(
                Errors.cache("Graph file too small", ErrorCode.CacheCorrupted).build()
            );
        }
        
        view._header = MappedGraphHeader.deserialize(data[0 .. MappedGraphHeader.HEADER_SIZE]);
        
        if (!view._header.valid)
        {
            region.unmap();
            return Err!(MappedGraphView, BuildError)(
                Errors.cache("Invalid graph format", ErrorCode.CacheCorrupted).build()
            );
        }
        
        view._valid = true;
        
        // Hint sequential access for initial scan
        region.advise(MapAdvice.Sequential);
        
        return Ok!(MappedGraphView, BuildError)(view);
    }
    
    /// Number of nodes
    size_t nodeCount() const @safe pure nothrow @nogc =>
        _valid ? cast(size_t)_header.nodeCount : 0;
    
    /// Number of edges
    size_t edgeCount() const @safe pure nothrow @nogc =>
        _valid ? cast(size_t)_header.edgeCount : 0;
    
    /// Get node by index (zero-copy)
    MappedNode getNode(size_t index) const @system nothrow
    {
        if (!_valid || _region is null || index >= _header.nodeCount) return MappedNode.init;
        
        immutable offset = _header.nodeTableOffset + index * MappedNode.SIZE;
        auto data = _region[];
        
        if (offset + MappedNode.SIZE > data.length) return MappedNode.init;
        
        return MappedNode.deserialize(data[offset .. offset + MappedNode.SIZE]);
    }
    
    /// Get edge by index (zero-copy)
    MappedEdge getEdge(size_t index) const @system nothrow
    {
        if (!_valid || _region is null || index >= _header.edgeCount) return MappedEdge.init;
        
        immutable offset = _header.edgeTableOffset + index * MappedEdge.SIZE;
        auto data = _region[];
        
        if (offset + MappedEdge.SIZE > data.length) return MappedEdge.init;
        
        return MappedEdge.deserialize(data[offset .. offset + MappedEdge.SIZE]);
    }
    
    /// Get string from string table (zero-copy slice)
    const(char)[] getString(ulong offset, ushort length) const @system nothrow
    {
        if (!_valid || _region is null) return null;
        
        immutable start = _header.stringTableOffset + offset;
        auto data = _region[];
        
        if (start + length > data.length) return null;
        
        return cast(const(char)[])data[start .. start + length];
    }
    
    /// Get target ID for node
    const(char)[] nodeTargetId(size_t index) const @system nothrow
    {
        auto node = getNode(index);
        return getString(node.targetIdOffset, node.targetIdLength);
    }
    
    /// Get output path for node
    const(char)[] nodeOutputPath(size_t index) const @system nothrow
    {
        auto node = getNode(index);
        return getString(node.outputPathOffset, node.outputPathLength);
    }
    
    /// Get dependencies for node
    uint[] nodeDependencies(size_t index) const @system
    {
        auto node = getNode(index);
        uint[] deps;
        deps.reserve(node.edgeCount);
        
        foreach (i; 0 .. node.edgeCount)
        {
            auto edge = getEdge(node.firstEdgeIndex + i);
            deps ~= edge.toIndex;
        }
        
        return deps;
    }
    
    /// Iterate all nodes
    int opApply(scope int delegate(size_t, MappedNode) @system dg) @system
    {
        if (!_valid) return 0;
        
        foreach (i; 0 .. cast(size_t)_header.nodeCount)
        {
            if (auto result = dg(i, getNode(i)))
                return result;
        }
        return 0;
    }
    
    /// Check if valid
    bool valid() const @safe pure nothrow @nogc => _valid;
    
    /// Content hash for integrity check
    const(ubyte)[32] contentHash() const @safe pure nothrow @nogc =>
        _valid ? _header.contentHash : (ubyte[32]).init;
    
    /// Config hash for watch mode validation
    const(ubyte)[32] configHash() const @safe pure nothrow @nogc =>
        _valid ? _header.configHash : (ubyte[32]).init;
    
    /// Persistence timestamp
    ulong timestamp() const @safe pure nothrow @nogc =>
        _valid ? _header.timestamp : 0;
    
    /// Validate config hash matches (for instant watch mode startup)
    bool validateConfigHash(const ubyte[32] expectedHash) const @safe pure nothrow @nogc
    {
        if (!_valid) return false;
        return _header.configHash == expectedHash;
    }
    
    /// Optimize for random access (after initial scan)
    void optimizeForRandomAccess() @system nothrow
    {
        if (_valid && _region !is null)
            _region.advise(MapAdvice.Random);
    }
    
    /// Pin in memory (prevent swapping)
    bool pin() @system nothrow => _valid && _region !is null ? _region.lock() : false;
    
    /// Unpin from memory
    bool unpin() @system nothrow => _valid && _region !is null ? _region.unlock() : false;
}

/// Memory-mapped graph storage
/// 
/// Provides:
/// - Zero-copy graph loading via mmap
/// - Efficient serialization with fixed-size records
/// - Lazy loading through page faults
/// - Cross-process sharing via kernel page cache
final class MappedGraphStorage
{
    private string cacheDir;
    private string graphPath;
    private Mutex mutex;
    private MappedGraphStorageStats _stats;
    
    this(string cacheDir = ".builder-cache") @system
    {
        this.cacheDir = cacheDir;
        this.graphPath = buildPath(cacheDir, "graph.mapped");
        this.mutex = new Mutex();
        
        if (!stdfile.exists(cacheDir))
            mkdirRecurse(cacheDir);
    }
    
    /// Serialize BuildGraph to memory-mapped format
    /// configHash: Optional hash of config files for watch mode validation
    VoidBuildResult persist(BuildGraph graph, const ubyte[32] configHash = (ubyte[32]).init) @system
    {
        if (graph is null)
            return VoidBuildResult.err(Errors.cache("Null graph", ErrorCode.InvalidInput).build());
        
        synchronized (mutex)
        {
            try
            {
                // Build string table
                StringTableBuilder strings;
                
                // Collect node data
                MappedNode[] nodes;
                nodes.reserve(graph.nodes.length);
                
                uint[string] nodeIndexMap;
                uint nodeIndex = 0;
                
                foreach (key, node; graph.nodes)
                {
                    nodeIndexMap[key] = nodeIndex++;
                    
                    MappedNode mn;
                    
                    auto targetId = node.id.toString();
                    mn.targetIdOffset = strings.add(targetId);
                    mn.targetIdLength = cast(ushort)targetId.length;
                    
                    mn.status = cast(ubyte)node.status;
                    mn.targetType = cast(ubyte)node.target.type;
                    
                    auto outputPath = node.target.outputPath;
                    mn.outputPathOffset = strings.add(outputPath);
                    mn.outputPathLength = cast(ushort)outputPath.length;
                    
                    // Copy hash if available
                    if (node.hash.length >= 32)
                        mn.hash = cast(ubyte[32])node.hash[0 .. 32];
                    
                    mn.retryAttempts = cast(uint)node.retryAttempts;
                    mn.depth = cast(uint)node.depth(graph);
                    
                    nodes ~= mn;
                }
                
                // Build edge table
                MappedEdge[] edges;
                uint edgeIndex = 0;
                
                foreach (key, node; graph.nodes)
                {
                    auto fromIdx = nodeIndexMap.get(key, uint.max);
                    if (fromIdx == uint.max) continue;
                    
                    // Update node's edge info
                    nodes[fromIdx].firstEdgeIndex = edgeIndex;
                    nodes[fromIdx].edgeCount = cast(ushort)node.dependencyIds.length;
                    
                    foreach (depId; node.dependencyIds)
                    {
                        auto depKey = depId.toString();
                        if (auto toIdxPtr = depKey in nodeIndexMap)
                        {
                            MappedEdge edge;
                            edge.fromIndex = fromIdx;
                            edge.toIndex = *toIdxPtr;
                            edges ~= edge;
                            edgeIndex++;
                        }
                    }
                }
                
                // Calculate offsets (v2 header is 136 bytes)
                immutable nodeTableOffset = MappedGraphHeader.HEADER_SIZE;
                immutable nodeTableSize = nodes.length * MappedNode.SIZE;
                immutable edgeTableOffset = nodeTableOffset + nodeTableSize;
                immutable edgeTableSize = edges.length * MappedEdge.SIZE;
                immutable stringTableOffset = edgeTableOffset + edgeTableSize;
                
                // Build header
                MappedGraphHeader header;
                header.nodeCount = nodes.length;
                header.edgeCount = edges.length;
                header.nodeTableOffset = nodeTableOffset;
                header.edgeTableOffset = edgeTableOffset;
                header.stringTableOffset = stringTableOffset;
                header.stringTableSize = strings.data.length;
                header.configHash = configHash;
                header.timestamp = cast(ulong)Clock.currStdTime();
                
                // Compute content hash
                import infrastructure.utils.crypto.blake3 : Blake3;
                auto hasher = Blake3(0);
                hasher.put(header.serialize[]);
                foreach (ref n; nodes) hasher.put(n.serialize[]);
                foreach (ref e; edges) hasher.put(e.serialize[]);
                hasher.put(strings.data);
                auto hashResult = hasher.finish(32);
                header.contentHash = hashResult[0 .. 32];
                
                // Write to file
                ubyte[] fileData;
                fileData.reserve(stringTableOffset + strings.data.length);
                
                fileData ~= header.serialize[];
                foreach (ref n; nodes) fileData ~= n.serialize[];
                foreach (ref e; edges) fileData ~= e.serialize[];
                fileData ~= strings.data;
                
                write(graphPath, fileData);
                
                _stats.graphsSaved++;
                _stats.bytesSaved += fileData.length;
                
                return Ok!BuildError();
            }
            catch (Exception e)
            {
                return VoidBuildResult.err(
                    Errors.cache("Failed to persist graph: " ~ e.msg, ErrorCode.CacheWriteFailed).build()
                );
            }
        }
    }
    
    /// Load graph with zero-copy memory mapping
    BuildResult!MappedGraphView load() @system
    {
        synchronized (mutex)
        {
            if (!stdfile.exists(graphPath))
                return Err!(MappedGraphView, BuildError)(
                    Errors.cache("No cached graph found", ErrorCode.CacheNotFound).build()
                );
            
            auto result = MappedGraphView.open(graphPath);
            
            if (result.isOk)
            {
                _stats.graphsLoaded++;
                _stats.bytesLoaded += getSize(graphPath);
            }
            
            return result;
        }
    }
    
    /// Restore full BuildGraph from mapped view
    /// Use this when you need a mutable graph
    BuildResult!BuildGraph restore() @system
    {
        auto viewResult = load();
        if (viewResult.isErr)
            return Err!(BuildGraph, BuildError)(viewResult.unwrapErr());
        
        return restoreFromView(viewResult.unwrap());
    }
    
    /// Check if cached graph exists
    bool graphExists() const @system => stdfile.exists(graphPath);
    
    /// Invalidate cached graph
    void invalidate() @system
    {
        synchronized (mutex)
        {
            try { if (stdfile.exists(graphPath)) stdfile.remove(graphPath); }
            catch (Exception) {}
        }
    }
    
    /// Storage statistics
    struct MappedGraphStorageStats
    {
        size_t graphsSaved;
        size_t graphsLoaded;
        size_t graphsRestored;
        size_t bytesSaved;
        size_t bytesLoaded;
        size_t watchModeHits;      // Instant startup successes
        size_t watchModeMisses;    // Config changed, needed full rebuild
    }
    
    MappedGraphStorageStats stats() const @safe nothrow => _stats;
    
    /// Try to load graph for watch mode with config validation
    /// Returns Ok with graph if config unchanged, Err if needs rebuild
    /// This enables instant startup when config hasn't changed
    BuildResult!BuildGraph tryLoadForWatchMode(const ubyte[32] configHash) @system
    {
        synchronized (mutex)
        {
            auto viewResult = load();
            if (viewResult.isErr)
            {
                _stats.watchModeMisses++;
                return Err!(BuildGraph, BuildError)(viewResult.unwrapErr());
            }
            
            auto view = viewResult.unwrap();
            
            // Validate config hash for instant startup
            if (!view.validateConfigHash(configHash))
            {
                _stats.watchModeMisses++;
                return Err!(BuildGraph, BuildError)(
                    Errors.cache("Config changed since last persist", ErrorCode.CacheCorrupted).build()
                );
            }
            
            // Config matches - restore graph instantly
            auto restoreResult = restoreFromView(view);
            if (restoreResult.isOk)
                _stats.watchModeHits++;
            else
                _stats.watchModeMisses++;
            
            return restoreResult;
        }
    }
    
    /// Restore BuildGraph from an already-loaded view
    private BuildResult!BuildGraph restoreFromView(MappedGraphView view) @system
    {
        try
        {
            // Create graph with arena pre-sized for node count
            auto graph = new BuildGraph(ValidationMode.Deferred, view.nodeCount);
            
            // First pass: create nodes
            string[uint] indexToId;
            
            foreach (i, mappedNode; view)
            {
                auto targetIdStr = view.nodeTargetId(i).idup;
                auto outputPath = view.nodeOutputPath(i).idup;
                
                auto idResult = TargetId.parse(targetIdStr);
                if (idResult.isErr) continue;
                
                auto targetId = idResult.unwrap();
                
                Target target;
                target.type = cast(TargetType)mappedNode.targetType;
                target.name = targetIdStr;
                target.outputPath = outputPath;
                
                auto node = graph.createNode(targetId, target);
                node.status = cast(BuildStatus)mappedNode.status;
                node.setRetryAttempts(mappedNode.retryAttempts);
                
                if (mappedNode.hash != (ubyte[32]).init)
                    node.hash = cast(string)(cast(char[])mappedNode.hash[]);
                
                graph.nodes[targetIdStr] = node;
                indexToId[cast(uint)i] = targetIdStr;
            }
            
            // Second pass: restore edges
            foreach (i, mappedNode; view)
            {
                auto nodeId = indexToId.get(cast(uint)i, null);
                if (nodeId is null) continue;
                
                auto node = graph.nodes.get(nodeId, null);
                if (node is null) continue;
                
                foreach (edgeIdx; 0 .. mappedNode.edgeCount)
                {
                    auto edge = view.getEdge(mappedNode.firstEdgeIndex + edgeIdx);
                    auto depId = indexToId.get(edge.toIndex, null);
                    
                    if (depId !is null)
                    {
                        auto depIdResult = TargetId.parse(depId);
                        if (depIdResult.isOk)
                            node.dependencyIds ~= depIdResult.unwrap();
                    }
                }
            }
            
            _stats.graphsRestored++;
            return Ok!(BuildGraph, BuildError)(graph);
        }
        catch (Exception e)
        {
            return Err!(BuildGraph, BuildError)(
                Errors.cache("Failed to restore graph: " ~ e.msg, ErrorCode.CacheLoadFailed).build()
            );
        }
    }
    
    /// Compute config hash from a list of config files
    /// Use this to generate the configHash parameter for persist()
    static ubyte[32] computeConfigHash(scope const(string)[] configFiles) @system
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        import std.file : exists, read;
        import std.algorithm : sort;
        
        auto hasher = Blake3(0);
        
        // Sort for deterministic ordering
        auto sortedFiles = configFiles.dup;
        sortedFiles.sort();
        
        foreach (file; sortedFiles)
        {
            if (exists(file))
            {
                // Hash filename for path sensitivity
                hasher.put(cast(const(ubyte)[])file);
                // Hash content
                auto content = cast(ubyte[])read(file);
                hasher.put(content);
            }
        }
        
        auto result = hasher.finish(32);
        return result[0 .. 32];
    }
}

/// String table builder for deduplication
private struct StringTableBuilder
{
    ubyte[] data;
    ulong[string] offsets;
    
    ulong add(string s) @trusted
    {
        if (s.length == 0) return 0;
        
        if (auto offset = s in offsets)
            return *offset;
        
        immutable offset = data.length;
        offsets[s] = offset;
        data ~= cast(ubyte[])s;
        
        return offset;
    }
}

unittest
{
    import std.file : tempDir, rmdirRecurse, write;
    import std.path : buildPath;
    
    // Create test graph
    auto graph = new BuildGraph(ValidationMode.Deferred);
    
    // Add some nodes
    auto id1Result = TargetId.parse("test:lib1");
    auto id2Result = TargetId.parse("test:lib2");
    
    if (id1Result.isOk && id2Result.isOk)
    {
        auto id1 = id1Result.unwrap();
        auto id2 = id2Result.unwrap();
        
        Target t1, t2;
        t1.type = TargetType.Library;
        t1.name = "lib1";
        t1.outputPath = "/out/lib1.a";
        
        t2.type = TargetType.Library;
        t2.name = "lib2";
        t2.outputPath = "/out/lib2.a";
        
        auto node1 = graph.createNode(id1, t1);
        auto node2 = graph.createNode(id2, t2);
        
        graph.nodes["test:lib1"] = node1;
        graph.nodes["test:lib2"] = node2;
        
        // Test persistence
        immutable testDir = buildPath(tempDir(), "mapped_graph_test");
        scope(exit) collectException(rmdirRecurse(testDir));
        
        // Create a fake config file for hash testing
        mkdirRecurse(testDir);
        auto configPath = buildPath(testDir, "Builderfile");
        write(configPath, "target lib1 {}");
        
        auto storage = new MappedGraphStorage(testDir);
        
        // Compute config hash
        auto configHash = MappedGraphStorage.computeConfigHash([configPath]);
        
        // Save with config hash
        auto saveResult = storage.persist(graph, configHash);
        assert(saveResult.isOk, "Failed to save graph");
        
        // Load view
        auto loadResult = storage.load();
        assert(loadResult.isOk, "Failed to load graph");
        
        auto view = loadResult.unwrap();
        assert(view.nodeCount == 2);
        assert(view.validateConfigHash(configHash), "Config hash mismatch");
        
        // Test watch mode startup with matching hash
        auto watchResult = storage.tryLoadForWatchMode(configHash);
        assert(watchResult.isOk, "Watch mode load failed with matching hash");
        
        // Test watch mode startup with different hash
        ubyte[32] differentHash;
        differentHash[0] = 0xFF;
        auto watchResult2 = storage.tryLoadForWatchMode(differentHash);
        assert(watchResult2.isErr, "Watch mode should fail with different hash");
        
        // Restore full graph
        auto restoreResult = storage.restore();
        assert(restoreResult.isOk, "Failed to restore graph");
        
        auto restored = restoreResult.unwrap();
        assert(restored.nodes.length == 2);
        
        // Verify stats
        auto stats = storage.stats;
        assert(stats.watchModeHits >= 1, "Should have at least one watch mode hit");
        assert(stats.watchModeMisses >= 1, "Should have at least one watch mode miss");
    }
}
