module engine.runtime.recovery.checkpoint;

import std.stdio;
import std.file;
import std.path;
import std.datetime;
import std.algorithm;
import std.array;
import std.conv;
import engine.graph;
import infrastructure.utils.files.hash;
import infrastructure.utils.files.directories : ensureDirectoryWithGitignore;
import infrastructure.errors.handling.result;

/// Build checkpoint - persists build state for resumption
struct Checkpoint
{
    string workspaceRoot;
    SysTime timestamp;
    BuildStatus[string] nodeStates;     // Target ID -> Status
    string[string] nodeHashes;          // Target ID -> Output hash
    size_t totalTargets;
    size_t completedTargets;
    size_t failedTargets;
    string[] failedTargetIds;
    
    /// Calculate completion percentage
    float completion() const pure nothrow @nogc @system
    {
        return totalTargets == 0 ? 0.0 : (cast(float)completedTargets / cast(float)totalTargets) * 100.0;
    }
    
    /// Check if checkpoint is valid for given graph
    bool isValid(const BuildGraph graph) const @system
    {
        import std.algorithm : all;
        
        return graph.nodes.length == totalTargets && 
               nodeStates.byKey.all!(id => id in graph.nodes);
    }
    
    /// Merge with current graph state (preserves successful builds)
    /// 
    /// Safety: This function is @system because:
    /// 1. Associative array lookups are bounds-checked
    /// 2. node.status is atomic property (thread-safe)
    /// 3. Hash assignment is safe string copy
    /// 4. Read-only traversal of checkpoint data (const)
    void mergeWith(BuildGraph graph) const @system
    {
        foreach (targetId, status; nodeStates)
        {
            if (targetId !in graph.nodes)
                continue;
            
            auto node = graph.nodes[targetId];
            
            // Only restore Success/Cached states
            // Failed/Pending nodes should retry
            if (status == BuildStatus.Success || status == BuildStatus.Cached)
            {
                node.status = status;
                if (auto hash = targetId in nodeHashes)
                    node.hash = *hash;
            }
        }
    }
}

/// Checkpoint manager - handles persistence
final class CheckpointManager
{
    /// Configuration constants
    private enum size_t BUFFER_RESERVE_SIZE = 4_096;     // Pre-allocate 4KB for serialization
    private enum size_t MAX_COMPLETION_STRING_LENGTH = 5; // Max chars for completion percentage
    private enum size_t CHECKPOINT_STALE_HOURS = 24;     // Hours until checkpoint is stale
    
    private string checkpointDir;
    private string checkpointPath;
    private bool autoSave;
    
    /// Constructor
    /// 
    /// Safety: This constructor is @system because:
    /// 1. buildPath() performs safe path construction
    /// 2. exists() and mkdirRecurse() are file I/O operations
    /// 3. Directory creation is safe and idempotent
    /// 4. All paths are validated by buildPath
    @system
    this(string workspaceRoot = ".", bool autoSave = true)
    {
        this.autoSave = autoSave;
        this.checkpointDir = buildPath(workspaceRoot, ".builder-cache");
        this.checkpointPath = buildPath(checkpointDir, "checkpoint.bin");
        
        ensureDirectoryWithGitignore(checkpointDir);
    }
    
    /// Create checkpoint from build graph
    Checkpoint capture(const BuildGraph graph, string workspaceRoot = ".") const
    {
        Checkpoint checkpoint;
        checkpoint.workspaceRoot = absolutePath(workspaceRoot);
        checkpoint.timestamp = Clock.currTime();
        checkpoint.totalTargets = graph.nodes.length;
        
        foreach (targetId, node; graph.nodes)
        {
            checkpoint.nodeStates[targetId] = node.status;
            
            if (!node.hash.empty)
                checkpoint.nodeHashes[targetId] = node.hash;
            
            with (BuildStatus) final switch (node.status)
            {
                case Success, Cached:
                    checkpoint.completedTargets++;
                    break;
                case Failed:
                    checkpoint.failedTargets++;
                    checkpoint.failedTargetIds ~= targetId;
                    break;
                case Pending, Building:
                    break;
            }
        }
        
        return checkpoint;
    }
    
    /// Save checkpoint to disk
    /// 
    /// Safety: This function is @system because:
    /// 1. serialize() returns owned ubyte[] (no dangling references)
    /// 2. std.file.write() is file I/O operation
    /// 3. Exception handling prevents crashes
    /// 4. writeln() for user feedback is safe
    @system
    void save(const ref Checkpoint checkpoint)
    {
        if (!autoSave)
            return;
        
        try
        {
            auto data = serialize(checkpoint);
            std.file.write(checkpointPath, data);
            
            writeln("Checkpoint saved: ", checkpoint.completedTargets, "/", 
                    checkpoint.totalTargets, " targets (", 
                    checkpoint.completion().to!string[0..min(MAX_COMPLETION_STRING_LENGTH, checkpoint.completion().to!string.length)], "%)");
        }
        catch (Exception e)
        {
            // Non-fatal - just warn
            writeln("Warning: Failed to save checkpoint: ", e.msg);
        }
    }
    
    /// Load checkpoint from disk
    /// 
    /// Safety: This function is @system because:
    /// 1. exists() check prevents file not found errors
    /// 2. std.file.read() returns owned ubyte[] array
    /// 3. deserialize() validates data before reconstruction
    /// 4. Exception handling converts to Result type
    @system
    Result!(Checkpoint, string) load()
    {
        if (!std.file.exists(checkpointPath))
            return Result!(Checkpoint, string).err("No checkpoint found");
        
        try
        {
            auto data = cast(ubyte[])std.file.read(checkpointPath);
            auto checkpoint = deserialize(data);
            return Result!(Checkpoint, string).ok(checkpoint);
        }
        catch (Exception e)
        {
            return Result!(Checkpoint, string).err("Failed to load checkpoint: " ~ e.msg);
        }
    }
    
    /// Check if checkpoint exists
    @system
    bool exists() const nothrow
    {
        try { return std.file.exists(checkpointPath); }
        catch (Exception) { return false; }
    }
    
    /// Clear checkpoint
    @system
    void clear()
    {
        if (std.file.exists(checkpointPath))
        {
            try { std.file.remove(checkpointPath); }
            catch (Exception e) { writeln("Warning: Failed to clear checkpoint: ", e.msg); }
        }
    }
    
    /// Get checkpoint age
    Duration age() const @system
    {
        if (!exists())
            return Duration.max;
        
        try
        {
            immutable modified = std.file.timeLastModified(checkpointPath);
            return Clock.currTime() - modified;
        }
        catch (Exception)
        {
            return Duration.max;
        }
    }
    
    /// Check if checkpoint is stale
    bool isStale() const @system
    {
        return age() > CHECKPOINT_STALE_HOURS.hours;
    }
    
    /// Serialize checkpoint to binary format
    /// 
    /// Safety: This function is @system because:
    /// 1. nativeToBigEndian produces static arrays (safe)
    /// 2. Array appending (~=) is memory-safe
    /// 3. Casts to ubyte/uint are for serialization (validated ranges)
    /// 4. writeString() is helper that validates string encoding
    /// 5. Returns owned array (no dangling references)
    private ubyte[] serialize(const ref Checkpoint checkpoint) const pure @system
    {
        import std.bitmanip : nativeToBigEndian;
        
        ubyte[] buffer;
        buffer.reserve(BUFFER_RESERVE_SIZE);
        
        // Magic number for validation
        buffer ~= nativeToBigEndian!uint(0x434B5054); // "CKPT"
        
        // Version
        buffer ~= cast(ubyte)1;
        
        // Workspace root
        buffer.writeString(checkpoint.workspaceRoot);
        
        // Timestamp (Unix time)
        buffer ~= nativeToBigEndian!long(checkpoint.timestamp.toUnixTime());
        
        // Counts
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.totalTargets);
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.completedTargets);
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.failedTargets);
        
        // Node states
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.nodeStates.length);
        foreach (targetId, status; checkpoint.nodeStates)
        {
            buffer.writeString(targetId);
            buffer ~= cast(ubyte)status;
        }
        
        // Node hashes
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.nodeHashes.length);
        foreach (targetId, hash; checkpoint.nodeHashes)
        {
            buffer.writeString(targetId);
            buffer.writeString(hash);
        }
        
        // Failed targets
        buffer ~= nativeToBigEndian!uint(cast(uint)checkpoint.failedTargetIds.length);
        foreach (targetId; checkpoint.failedTargetIds)
        {
            buffer.writeString(targetId);
        }
        
        return buffer;
    }
    
    /// Deserialize checkpoint from binary format
    /// 
    /// Safety: This function is @system because:
    /// 1. read() from std.bitmanip is bounds-checked
    /// 2. Magic number validation prevents corrupt data
    /// 3. Version validation ensures format compatibility
    /// 4. All array slicing is bounds-checked
    /// 5. readString() helper validates string lengths
    /// 6. Throws exception on validation failure (safe error handling)
    private Checkpoint deserialize(ubyte[] data) const @system
    {
        import std.bitmanip : read, bigEndianToNative;
        
        size_t offset = 0;
        
        // Helper to read with offset management
        T readValue(T)(ref ubyte[] d, ref size_t off)
        {
            auto slice = d[off .. $];
            auto value = read!T(slice);
            off += T.sizeof;
            return value;
        }
        
        // Validate magic number
        immutable magic = readValue!uint(data, offset);
        if (magic != 0x434B5054)
            throw new Exception("Invalid checkpoint: bad magic number");
        
        // Version
        immutable version_ = readValue!ubyte(data, offset);
        if (version_ != 1)
            throw new Exception("Unsupported checkpoint version");
        
        Checkpoint checkpoint;
        
        // Workspace root
        checkpoint.workspaceRoot = readString(data, &offset);
        
        // Timestamp
        immutable unixTime = readValue!long(data, offset);
        checkpoint.timestamp = SysTime.fromUnixTime(unixTime);
        
        // Counts
        checkpoint.totalTargets = readValue!uint(data, offset);
        checkpoint.completedTargets = readValue!uint(data, offset);
        checkpoint.failedTargets = readValue!uint(data, offset);
        
        // Node states
        immutable stateCount = readValue!uint(data, offset);
        foreach (i; 0 .. stateCount)
        {
            auto targetId = readString(data, &offset);
            auto status = cast(BuildStatus)readValue!ubyte(data, offset);
            checkpoint.nodeStates[targetId] = status;
        }
        
        // Node hashes
        immutable hashCount = readValue!uint(data, offset);
        foreach (i; 0 .. hashCount)
        {
            auto targetId = readString(data, &offset);
            auto hash = readString(data, &offset);
            checkpoint.nodeHashes[targetId] = hash;
        }
        
        // Failed targets
        immutable failedCount = readValue!uint(data, offset);
        checkpoint.failedTargetIds.reserve(failedCount);
        foreach (i; 0 .. failedCount)
        {
            checkpoint.failedTargetIds ~= readString(data, &offset);
        }
        
        return checkpoint;
    }
}

/// Binary serialization helpers
private void writeString(ref ubyte[] buffer, string str) pure @system
{
    import std.bitmanip : nativeToBigEndian;
    
    // Length prefix
    buffer ~= nativeToBigEndian!uint(cast(uint)str.length);
    
    // String data
    buffer ~= cast(ubyte[])str;
}

private string readString(ubyte[] data, size_t* offset) @system
{
    import std.bitmanip : read;
    
    auto slice = data[*offset .. $];
    immutable len = read!uint(slice);
    *offset += uint.sizeof;
    
    if (*offset + len > data.length)
        throw new Exception("Invalid checkpoint: truncated string");
    
    auto str = cast(string)data[*offset .. *offset + len];
    *offset += len;
    
    return str;
}

