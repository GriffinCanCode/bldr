module engine.caching.storage.source_ref;

import std.file : exists, read, getSize;
import std.path : buildPath;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;
import infrastructure.errors;

/// Size threshold for mmap reads (>256KB uses mmap)
private enum size_t SOURCE_MMAP_THRESHOLD = 256 * 1024;

/// Content-addressed source file reference (git-like)
/// Stores only hash, enables deduplication across branches/history
struct SourceRef
{
    string hash;           // Content hash (BLAKE3)
    string originalPath;   // Original path for debugging/display
    ulong size;           // File size in bytes
    
    /// Create from file path (computes hash, uses mmap for large files)
    static BuildResult!SourceRef fromFile(string path) @system
    {
        try
        {
            if (!exists(path))
                return Err!(SourceRef, BuildError)(
                    Errors.io(path, "Source file not found", ErrorCode.FileNotFound)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            
            immutable fileSize = getSize(path);
            ubyte[] content;
            
            // Large files: memory-mapped read (zero kernel-to-user copy)
            if (fileSize >= SOURCE_MMAP_THRESHOLD)
            {
                auto region = MmapRegion.map(path, MapMode.ReadOnly);
                if (region !is null)
                {
                    scope(exit) region.unmap();
                    immutable hash = FastHash.hashBytes(region[]);
                    
                    SourceRef ref_;
                    ref_.hash = hash;
                    ref_.originalPath = path;
                    ref_.size = fileSize;
                    return Ok!(SourceRef, BuildError)(ref_);
                }
            }
            
            // Small files or mmap fallback: standard read
            content = cast(ubyte[])read(path);
            immutable hash = FastHash.hashBytes(content);
            
            SourceRef ref_;
            ref_.hash = hash;
            ref_.originalPath = path;
            ref_.size = content.length;
            
            return Ok!(SourceRef, BuildError)(ref_);
        }
        catch (Exception e)
        {
            return Err!(SourceRef, BuildError)(
                Errors.io(path, "Failed to create source ref: " ~ e.msg, ErrorCode.FileReadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Create from existing hash
    static SourceRef fromHash(string hash, string originalPath = "", ulong size = 0) pure @safe nothrow
    {
        SourceRef ref_;
        ref_.hash = hash;
        ref_.originalPath = originalPath;
        ref_.size = size;
        return ref_;
    }
    
    /// Check if source ref is valid
    bool isValid() const pure @safe nothrow @nogc
    {
        return hash.length > 0;
    }
    
    /// Get short hash for display (first 8 chars, git-like)
    string shortHash() const pure @safe
    {
        return hash.length >= 8 ? hash[0 .. 8] : hash;
    }
    
    /// String representation
    string toString() const pure @safe
    {
        import std.format : format;
        return originalPath.length > 0 
            ? format("%s@%s", originalPath, shortHash())
            : shortHash();
    }
    
    /// Compare for equality (based on hash only)
    bool opEquals()(auto ref const SourceRef other) const pure @safe nothrow @nogc
    {
        return hash == other.hash;
    }
    
    /// Hash for use in associative arrays
    size_t toHash() const pure @safe nothrow
    {
        size_t h = 0;
        foreach (c; hash)
            h = h * 31 + c;
        return h;
    }
}

/// Collection of source references for a target
struct SourceRefSet
{
    SourceRef[] sources;
    string[string] pathToHash;  // Quick lookup: path -> hash
    
    /// Add source reference
    void add(SourceRef ref_) pure @safe
    {
        sources ~= ref_;
        if (ref_.originalPath.length > 0)
            pathToHash[ref_.originalPath] = ref_.hash;
    }
    
    /// Get source by path
    SourceRef* getByPath(string path) pure @trusted nothrow
    {
        if (auto hashPtr = path in pathToHash)
        {
            foreach (ref source; sources)
            {
                if (source.hash == *hashPtr)
                    return &source;
            }
        }
        return null;
    }
    
    /// Get source by hash
    SourceRef* getByHash(string hash) pure @trusted nothrow
    {
        foreach (ref source; sources)
        {
            if (source.hash == hash)
                return &source;
        }
        return null;
    }
    
    /// Total size of all sources
    ulong totalSize() const pure @safe nothrow @nogc
    {
        ulong total = 0;
        foreach (ref source; sources)
            total += source.size;
        return total;
    }
    
    /// Check if empty
    bool empty() const pure @safe nothrow @nogc
    {
        return sources.length == 0;
    }
    
    /// Number of sources
    size_t length() const pure @safe nothrow @nogc
    {
        return sources.length;
    }
}

