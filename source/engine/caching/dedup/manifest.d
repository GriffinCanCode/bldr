module engine.caching.dedup.manifest;

import std.algorithm : map, filter;
import std.array : array;
import std.datetime : Clock, SysTime;
import engine.caching.dedup.dedup : BlobRef, DedupEngine;
import infrastructure.utils.serialization;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// Action output manifest - references blobs instead of storing inline data
/// Enables massive deduplication when multiple actions produce identical outputs
/// 
/// Example: 100 actions each producing same 10MB library
/// - Without dedup: 1GB storage
/// - With dedup: 10MB storage + 100 manifests (~100KB)
/// 
/// Schema v1.0 - initial release
@Serializable(SchemaVersion(1, 0), 0x4D4E4654) // "MNFT"
struct ActionManifest
{
    @Field(1) string actionId;           // Parent action identifier
    @Field(2) ManifestEntry[] outputs;   // Output file references
    @Field(3) @Packed long timestamp;    // Creation time
    @Field(4) string inputsHash;         // Combined hash of all inputs
    @Field(5) @Optional string execHash; // Execution context hash
    @Field(6) bool success;              // Action succeeded
    
    /// Compute manifest hash for integrity
    string hash() const @system
    {
        string[] parts;
        parts ~= actionId;
        foreach (ref o; outputs)
            parts ~= o.blobHash ~ o.path;
        parts ~= inputsHash;
        return FastHash.hashStrings(parts);
    }
    
    /// Total output size
    size_t totalSize() const pure @safe
    {
        size_t total;
        foreach (ref o; outputs)
            total += o.size;
        return total;
    }
    
    /// Number of outputs
    size_t outputCount() const pure @safe => outputs.length;
}

/// Single output entry in manifest
@Serializable(SchemaVersion(1, 0))
struct ManifestEntry
{
    @Field(1) string blobHash;    // Content hash -> CAS lookup
    @Field(2) @Packed long size;  // Original file size
    @Field(3) string path;        // Relative output path
    @Field(4) bool executable;    // Preserve +x bit
    @Field(5) @Optional string mode; // File mode (optional)
    
    /// Convert from BlobRef
    static ManifestEntry fromBlobRef(BlobRef ref_) pure @safe
    {
        ManifestEntry e;
        e.blobHash = ref_.hash;
        e.size = ref_.size;
        e.path = ref_.path;
        e.executable = ref_.executable;
        return e;
    }
    
    /// Convert to BlobRef
    BlobRef toBlobRef() const pure @safe
    {
        BlobRef r;
        r.hash = blobHash;
        r.size = size;
        r.path = path;
        r.executable = executable;
        return r;
    }
}

/// Manifest storage - serialization layer
struct ManifestStorage
{
    /// Serialize manifest to binary
    static ubyte[] serialize(const ref ActionManifest manifest) @system
        => Codec.serialize(manifest);
    
    /// Deserialize manifest from binary
    static BuildResult!ActionManifest deserialize(const(ubyte)[] data) @system
    {
        auto result = Codec.deserialize!ActionManifest(data);
        return result.isErr 
            ? Err!(ActionManifest, BuildError)(Errors.cache(
                "Failed to deserialize manifest", Cache.LoadFailed).build())
            : Ok!(ActionManifest, BuildError)(result.unwrap());
    }
}

/// Build a manifest from action outputs
/// Stores blobs in CAS and returns manifest referencing them
BuildResult!ActionManifest buildManifest(
    DedupEngine engine,
    string actionId,
    const(ubyte)[][] outputs,
    string[] paths,
    string inputsHash,
    string execHash = "",
    bool success = true
) @system
{
    ManifestEntry[] entries;
    entries.reserve(outputs.length);
    
    // Store each output in CAS
    foreach (i, data; outputs)
    {
        immutable path = i < paths.length ? paths[i] : "";
        auto storeResult = engine.store(data, path);
        if (storeResult.isErr)
            return Err!(ActionManifest, BuildError)(storeResult.unwrapErr());
        
        entries ~= ManifestEntry.fromBlobRef(storeResult.unwrap());
    }
    
    ActionManifest manifest;
    manifest.actionId = actionId;
    manifest.outputs = entries;
    manifest.timestamp = Clock.currTime.stdTime;
    manifest.inputsHash = inputsHash;
    manifest.execHash = execHash;
    manifest.success = success;
    
    return Ok!(ActionManifest, BuildError)(manifest);
}

/// Materialize manifest - fetch all blob contents
/// Returns array of (path, data) pairs
BuildResult!(OutputFile[]) materializeManifest(
    DedupEngine engine,
    ActionManifest manifest
) @system
{
    OutputFile[] files;
    files.reserve(manifest.outputs.length);
    
    foreach (ref entry; manifest.outputs)
    {
        auto fetchResult = engine.fetch(entry.toBlobRef());
        if (fetchResult.isErr)
            return Err!(OutputFile[], BuildError)(fetchResult.unwrapErr());
        
        files ~= OutputFile(entry.path, fetchResult.unwrap(), entry.executable);
    }
    
    return Ok!(OutputFile[], BuildError)(files);
}

/// Materialized output file
struct OutputFile
{
    string path;
    ubyte[] data;
    bool executable;
}

/// Collect all blob hashes from manifest (for reference tracking)
string[] collectBlobHashes(ActionManifest manifest) @safe
{
    string[] hashes;
    hashes.reserve(manifest.outputs.length);
    foreach (ref o; manifest.outputs)
        hashes ~= o.blobHash;
    return hashes;
}

