module engine.runtime.remote.artifacts.manager;

import std.file : exists, read, getSize;
import std.conv : to;
import engine.distributed.protocol.protocol : ArtifactId, ActionId, InputSpec, OutputSpec;
import engine.runtime.hermetic : SandboxSpec;
import engine.caching.distributed.remote.client : RemoteCacheClient;
import infrastructure.utils.files.chunking : ChunkTransfer, TransferStats;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Size threshold for mmap reads (>1MB uses mmap)
private enum size_t ARTIFACT_MMAP_THRESHOLD = 1_048_576;

/// Artifact manager - single responsibility: manage artifact upload/download
/// 
/// Separation of concerns:
/// - RemoteExecutor: orchestrates remote execution flow
/// - ArtifactManager: handles artifact I/O and transfer
/// - RemoteCacheClient: handles actual network transfer to cache
final class ArtifactManager
{
    private RemoteCacheClient cacheClient;
    
    this(RemoteCacheClient cacheClient) @safe
    {
        this.cacheClient = cacheClient;
    }
    
    /// Upload input artifacts to remote store
    /// 
    /// Responsibility: Read, hash, and upload all input files/directories
    /// Uses chunk-based transfer for large files (> 1MB) for efficiency
    /// Returns: Array of InputSpec with artifact IDs for remote execution
    BuildResult!(InputSpec[]) uploadInputs(SandboxSpec spec) @trusted
    {
        InputSpec[] inputs;
        
        foreach (inputPath; spec.inputs.paths)
        {
            // Read artifact from filesystem
            auto readResult = readArtifact(inputPath);
            if (readResult.isErr)
            {
                auto error = Errors.generic(
                    "Failed to read input: " ~ inputPath ~ ": " ~ readResult.unwrapErr(),
                    ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build();
                return Err!(InputSpec[], BuildError)(error);
            }
            
            auto data = readResult.unwrap();
            
            // Compute artifact ID (content hash)
            auto artifactId = computeArtifactId(data);
            immutable artifactHash = artifactId.toString();
            
            // Use chunk-based upload for large files (> 1MB)
            if (data.length > 1_048_576)
            {
                auto chunkResult = cacheClient.putFileChunked(inputPath, artifactHash);
                if (chunkResult.isErr)
                {
                    return Err!(InputSpec[], BuildError)(chunkResult.unwrapErr());
                }
                
                auto upload = chunkResult.unwrap();
                if (upload.useChunking)
                {
                    structuredLog.debug_("uploaded_large_input_using_chunks_").field("detail", "Uploaded large input using chunks: " ~ inputPath ~ 
                                  " (" ~ upload.stats.chunksTransferred.to!string ~ " chunks, " ~
                                  upload.stats.bytesTransferred.to!string ~ " bytes)").emit();
                }
            }
            else
            {
                // Use regular upload for small files
                auto uploadResult = cacheClient.put(artifactHash, cast(const(ubyte)[])data);
                if (uploadResult.isErr)
                {
                    return Err!(InputSpec[], BuildError)(uploadResult.unwrapErr());
                }
            }
            
            // Check if executable
            bool executable = isExecutable(inputPath);
            
            inputs ~= InputSpec(artifactId, inputPath, executable);
            
            structuredLog.debug_("uploaded_input_").field("detail", "Uploaded input: " ~ inputPath ~ 
                          " -> " ~ artifactHash).emit();
        }
        
        return Ok!(InputSpec[], BuildError)(inputs);
    }
    
    /// Upload input with incremental chunking (only changed chunks)
    /// 
    /// Use this when updating an existing artifact to save bandwidth
    /// Returns: Transfer statistics showing bandwidth savings
    BuildResult!TransferStats uploadInputIncremental(
        string inputPath,
        ArtifactId newArtifactId,
        ArtifactId oldArtifactId
    ) @trusted
    {
        if (!exists(inputPath))
        {
            auto error = Errors.generic("Failed to read input: " ~ inputPath ~ ": file not found", ErrorCode.FileNotFound)
                .withLocation(__FILE__, __LINE__)
                .build();
            return Err!(TransferStats, BuildError)(error);
        }
        
        // Check file size - only use chunking for large files
        auto fileSize = getSize(inputPath);
        if (fileSize < 1_048_576)  // 1 MB
        {
            // For small files, just do regular upload
            auto data = cast(ubyte[])read(inputPath);
            auto uploadResult = cacheClient.put(newArtifactId.toString(), data);
            
            if (uploadResult.isErr)
                return Err!(TransferStats, BuildError)(uploadResult.unwrapErr());
            
            // Return stats for full upload
            TransferStats stats;
            stats.totalChunks = 1;
            stats.chunksTransferred = 1;
            stats.bytesTransferred = fileSize;
            
            return Ok!(TransferStats, BuildError)(stats);
        }
        
        // Use incremental chunk upload
        auto updateResult = cacheClient.updateFileChunked(
            inputPath,
            newArtifactId.toString(),
            oldArtifactId.toString()
        );
        
        if (updateResult.isErr)
            return updateResult;
        
        auto stats = updateResult.unwrap();
        
        structuredLog.debug_("incremental_upload_").field("detail", "Incremental upload: " ~ inputPath ~ 
                      " (saved " ~ stats.bytesSaved.to!string ~ " bytes, " ~
                      stats.savingsPercent().to!string ~ "%)").emit();
        
        return Ok!(TransferStats, BuildError)(stats);
    }
    
    /// Download output artifacts from remote store
    /// 
    /// Responsibility: Download all output artifacts specified
    /// Uses chunk-based download for large files for efficiency
    VoidBuildResult downloadOutputs(ArtifactId[] artifacts, string outputDir) @trusted
    {
        import std.path : buildPath;
        
        foreach (artifactId; artifacts)
        {
            immutable artifactHash = artifactId.toString();
            immutable outputPath = buildPath(outputDir, artifactHash);
            
            // Try chunk-based download first (will fallback to regular if no manifest)
            auto downloadResult = cacheClient.getFileChunked(artifactHash, outputPath);
            if (downloadResult.isErr)
            {
                return VoidBuildResult.err(downloadResult.unwrapErr());
            }
            
            auto stats = downloadResult.unwrap();
            if (stats.totalChunks > 1)
            {
                structuredLog.debug_("downloaded_output_using_chunks_").field("detail", "Downloaded output using chunks: " ~ artifactHash ~ 
                              " (" ~ stats.chunksTransferred.to!string ~ " chunks, " ~
                              stats.bytesTransferred.to!string ~ " bytes)").emit();
            }
            else
            {
                structuredLog.debug_("downloaded_output_").field("detail", "Downloaded output: " ~ artifactHash).emit();
            }
        }
        
        return Ok!BuildError();
    }
    
    /// Download output artifacts (backward compatibility - no output directory)
    VoidBuildResult downloadOutputs(ArtifactId[] artifacts) @trusted
    {
        foreach (artifactId; artifacts)
        {
            // Download from artifact store (regular download)
            auto downloadResult = cacheClient.get(artifactId.toString());
            if (downloadResult.isErr)
            {
                return VoidBuildResult.err(downloadResult.unwrapErr());
            }
            
            structuredLog.debug_("downloaded_output_").field("detail", "Downloaded output: " ~ artifactId.toString()).emit();
        }
        
        return Ok!BuildError();
    }
    
    /// Read artifact from filesystem (uses mmap for large files)
    private Result!(ubyte[], string) readArtifact(string path) @trusted
    {
        if (!exists(path))
            return Err!(ubyte[], string)("File not found: " ~ path);
        
        try
        {
            immutable size = getSize(path);
            
            // Large files: memory-mapped read (zero kernel-to-user copy)
            if (size >= ARTIFACT_MMAP_THRESHOLD)
            {
                auto region = MmapRegion.map(path, MapMode.ReadOnly);
                if (region !is null)
                {
                    scope(exit) region.unmap();
                    return Ok!(ubyte[], string)(region[].dup);
                }
            }
            
            // Small files or mmap fallback: standard read
            return Ok!(ubyte[], string)(cast(ubyte[])read(path));
        }
        catch (Exception e)
        {
            return Err!(ubyte[], string)(e.msg);
        }
    }
    
    /// Compute artifact ID from content
    /// 
    /// Responsibility: Hash artifact content using Blake3
    /// Uses Blake3 for consistency across the system
    private ArtifactId computeArtifactId(const ubyte[] data) @trusted
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        
        auto hasher = Blake3(0);
        hasher.put(cast(const(ubyte)[])data);
        
        auto hashBytes = hasher.finish(32);
        ubyte[32] hash;
        hash[0 .. 32] = hashBytes[0 .. 32];
        
        return ArtifactId(hash);
    }
    
    /// Check if file is executable
    /// 
    /// Responsibility: Determine file execution permissions
    private bool isExecutable(string path) @trusted
    {
        version(Posix)
        {
            import core.sys.posix.sys.stat;
            import std.string : toStringz;
            
            stat_t statbuf;
            if (stat(toStringz(path), &statbuf) == 0)
            {
                return (statbuf.st_mode & S_IXUSR) != 0;
            }
        }
        
        return false;
    }
}

