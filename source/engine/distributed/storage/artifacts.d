module engine.distributed.storage.artifacts;

import std.file : read, write, exists, mkdirRecurse, remove, getSize;
import std.path : buildPath, dirName, baseName;
import std.digest : toHexString;
import std.string : toLower;
import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown, SocketOptionLevel, SocketOption;
import std.datetime : Duration, seconds;
import std.conv : to;
import engine.distributed.protocol.protocol : ArtifactId, InputSpec, DistributedError;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging;
import infrastructure.utils.crypto.blake3 : Blake3;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;
import infrastructure.utils.files.cdc : FastCDC, ChunkManifest, shouldChunk, LARGE_ARTIFACT_THRESHOLD;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Size threshold for mmap artifact reads (>256KB uses mmap)
private enum size_t ARTIFACT_MMAP_THRESHOLD = 256 * 1024;

/// Artifact with data
struct InputArtifact
{
    ArtifactId id;
    string path;
    bool executable;
    ubyte[] data;
}

/// Artifact store configuration
struct ArtifactStoreConfig
{
    string localCachePath;      // Local disk cache directory
    string remoteUrl;           // Remote artifact store URL (optional)
    size_t maxLocalCacheSize;   // Max local cache size in bytes
    bool enableRemote = true;   // Enable remote fetching/uploading
    Duration timeout = 30.seconds;
}

/// Artifact store - manages fetching and uploading build artifacts
final class ArtifactStore
{
    private ArtifactStoreConfig config;
    private size_t currentCacheSize;
    
    this(ArtifactStoreConfig config) @trusted
    {
        this.config = config;
        
        // Ensure local cache directory exists
        if (config.localCachePath.length > 0)
        {
            try
            {
                import std.file : mkdirRecurse, exists;
                if (!exists(config.localCachePath))
                    mkdirRecurse(config.localCachePath);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_create_artifact_cache_director").field("detail", "Failed to create artifact cache directory: " ~ e.msg).emit();
            }
        }
    }
    
    /// Fetch artifact by ID (uses mmap for large files)
    BuildResult!InputArtifact fetch(InputSpec spec) @trusted
    {
        InputArtifact artifact;
        artifact.id = spec.id;
        artifact.path = spec.path;
        artifact.executable = spec.executable;
        
        // Try local cache first
        auto localPath = getLocalPath(spec.id);
        if (exists(localPath))
        {
            try
            {
                immutable size = getSize(localPath);
                
                // Large artifacts: memory-mapped read
                if (size >= ARTIFACT_MMAP_THRESHOLD)
                {
                    auto region = MmapRegion.map(localPath, MapMode.ReadOnly);
                    if (region !is null)
                    {
                        scope(exit) region.unmap();
                        artifact.data = region[].dup;
                        structuredLog.debug_("artifact_fetched_from_local_cache_mmap_").field("detail", "Artifact fetched from local cache (mmap): " ~ spec.id.toString()).emit();
                        return Ok!(InputArtifact, BuildError)(artifact);
                    }
                }
                
                // Small artifacts or mmap fallback: standard read
                artifact.data = cast(ubyte[])read(localPath);
                structuredLog.debug_("artifact_fetched_from_local_cache_").field("detail", "Artifact fetched from local cache: " ~ spec.id.toString()).emit();
                return Ok!(InputArtifact, BuildError)(artifact);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_read_from_local_cache_").field("detail", "Failed to read from local cache: " ~ e.msg).emit();
                // Fall through to remote fetch
            }
        }
        
        // Try remote fetch if enabled
        if (config.enableRemote && config.remoteUrl.length > 0)
        {
            auto remoteResult = fetchRemote(spec.id);
            if (remoteResult.isOk)
            {
                artifact.data = remoteResult.unwrap();
                
                // Save to local cache
                try
                {
                    saveToLocalCache(spec.id, artifact.data);
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_save_to_local_cache_").field("detail", "Failed to save to local cache: " ~ e.msg).emit();
                }
                
                structuredLog.debug_("artifact_fetched_from_remote_").field("detail", "Artifact fetched from remote: " ~ spec.id.toString()).emit();
                return Ok!(InputArtifact, BuildError)(artifact);
            }
            else
            {
                structuredLog.error("failed_to_fetch_from_remote").emit();
                structuredLog.error("log_event").field("message", formatError(remoteResult.unwrapErr())).emit();
            }
        }
        
        // Artifact not found
        return Err!(InputArtifact, BuildError)(
            Errors.cache("Artifact not found: " ~ spec.id.toString(), Cache.NotFound));
    }
    
    /// Upload artifact - uses FastCDC for large artifacts (>100MB)
    VoidBuildResult upload(ArtifactId id, const ubyte[] data) @trusted
    {
        // Verify content hash matches ID
        auto hasher = Blake3(0);
        hasher.put(data);
        auto actualHash = hasher.finish(32);
        
        if (actualHash[0 .. 32] != id.hash[0 .. 32])
            return VoidBuildResult.err(
                Errors.generic("Artifact hash mismatch: expected " ~ id.toString() ~ 
                    " but got " ~ toHexString(actualHash[0 .. 32]).toLower(), Cache.Corrupted));
        
        // Use FastCDC for large artifacts (>100MB)
        if (shouldChunk(data.length) && config.enableRemote && config.remoteUrl.length > 0)
            return uploadWithCDC(id, data);
        
        // Save to local cache
        try
        {
            saveToLocalCache(id, data);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_save_to_local_cache_").field("detail", "Failed to save to local cache: " ~ e.msg).emit();
        }
        
        // Upload to remote if enabled
        if (config.enableRemote && config.remoteUrl.length > 0)
        {
            auto remoteResult = uploadRemote(id, data);
            if (remoteResult.isErr)
            {
                structuredLog.warning("failed_to_upload_to_remote_").field("detail", "Failed to upload to remote: " ~ remoteResult.unwrapErr().message()).emit();
                // Don't fail - local cache is sufficient
            }
            else
            {
                structuredLog.debug_("artifact_uploaded_to_remote_").field("detail", "Artifact uploaded to remote: " ~ id.toString()).emit();
            }
        }
        
        return Ok!BuildError();
    }
    
    /// Upload large artifact using FastCDC for delta transfers
    private VoidBuildResult uploadWithCDC(ArtifactId id, const ubyte[] data) @trusted
    {
        import infrastructure.utils.crypto.blake3 : toHexString;
        
        // Chunk data using FastCDC
        auto cdc = FastCDC(FastCDC.Config.large());
        auto chunkResult = cdc.chunkData(data);
        
        if (chunkResult.chunks.length == 0)
            return VoidBuildResult.err(
                Errors.cache("FastCDC chunking failed", Cache.WriteFailed).build());
        
        // Upload each chunk
        size_t chunksUploaded = 0;
        foreach (ref chunk; chunkResult.chunks)
        {
            immutable chunkHash = toHexString(chunk.hash[]);
            immutable chunkUrl = config.remoteUrl ~ "/chunks/" ~ chunkHash;
            
            // Check if chunk exists
            auto checkResult = executeHttpHead(chunkUrl);
            if (checkResult.isOk && checkResult.unwrap())
                continue;  // Chunk exists, skip
            
            // Upload chunk
            auto chunkData = data[chunk.offset .. chunk.offset + chunk.length];
            auto putResult = executeHttpPut(chunkUrl, chunkData);
            if (putResult.isErr)
            {
                structuredLog.warning("failed_to_upload_chunk_").field("detail", "Failed to upload chunk: " ~ chunkHash).emit();
                continue;  // Try other chunks
            }
            chunksUploaded++;
        }
        
        // Create and upload manifest
        ubyte[32] blobHash = id.hash;
        auto manifest = ChunkManifest.fromResult(chunkResult, blobHash[]);
        auto manifestData = manifest.serialize();
        
        immutable manifestUrl = config.remoteUrl ~ "/manifests/" ~ id.toString();
        auto manifestResult = executeHttpPut(manifestUrl, manifestData);
        
        if (manifestResult.isErr)
            structuredLog.warning("failed_to_upload_manifest_for_").field("detail", "Failed to upload manifest for: " ~ id.toString()).emit();
        
        // Save to local cache
        try { saveToLocalCache(id, data); }
        catch (Exception e) { structuredLog.warning("failed_to_save_to_local_cache_").field("detail", "Failed to save to local cache: " ~ e.msg).emit(); }
        
        structuredLog.debug_("uploaded_large_artifact_via_cdc_").field("detail", "Uploaded large artifact via CDC: " ~ id.toString() ~ 
                       " (" ~ chunksUploaded.to!string ~ "/" ~ chunkResult.chunks.length.to!string ~ " chunks uploaded)").emit();
        
        return Ok!BuildError();
    }
    
    /// Execute HTTP HEAD request
    private BuildResult!bool executeHttpHead(string url) @trusted
    {
        import std.string : indexOf, startsWith;
        
        string host;
        ushort port = 80;
        string path;
        
        string remaining = url;
        if (SIMDStrings.startsWith(remaining, "http://")) remaining = remaining[7 .. $];
        else if (SIMDStrings.startsWith(remaining, "https://")) { remaining = remaining[8 .. $]; port = 443; }
        
        immutable slashPos = remaining.indexOf('/');
        if (slashPos >= 0) { host = remaining[0 .. slashPos]; path = remaining[slashPos .. $]; }
        else { host = remaining; path = "/"; }
        
        immutable colonPos = host.indexOf(':');
        if (colonPos >= 0) { port = host[colonPos + 1 .. $].to!ushort; host = host[0 .. colonPos]; }
        
        try
        {
            auto addr = new InternetAddress(host, port);
            auto socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, config.timeout);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, config.timeout);
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            string request = "HEAD " ~ path ~ " HTTP/1.1\r\nHost: " ~ host ~ "\r\nConnection: close\r\n\r\n";
            socket.send(request);
            
            ubyte[1024] buffer;
            auto received = socket.receive(buffer);
            if (received <= 0) return Ok!(bool, BuildError)(false);
            
            immutable responseStr = cast(string)buffer[0 .. received];
            immutable firstLine = responseStr[0 .. responseStr.indexOf('\r')];
            import std.string : split;
            auto parts = firstLine.split(' ');
            if (parts.length >= 2)
            {
                immutable statusCode = parts[1].to!int;
                return Ok!(bool, BuildError)(statusCode >= 200 && statusCode < 300);
            }
            return Ok!(bool, BuildError)(false);
        }
        catch (Exception e)
        {
            return Ok!(bool, BuildError)(false);  // Assume not exists on error
        }
    }
    
    /// Check if artifact exists locally
    bool existsLocally(ArtifactId id) const @safe
    {
        auto localPath = getLocalPath(id);
        return exists(localPath);
    }
    
    /// Get local cache path for artifact
    private string getLocalPath(ArtifactId id) const @safe
    {
        immutable hashStr = id.toString();
        // Use 2-level directory structure for better filesystem performance
        // e.g., /cache/ab/cd/abcd...
        immutable subdir1 = hashStr[0 .. 2];
        immutable subdir2 = hashStr[2 .. 4];
        return buildPath(config.localCachePath, subdir1, subdir2, hashStr);
    }
    
    /// Save artifact to local cache
    private void saveToLocalCache(ArtifactId id, const ubyte[] data) @trusted
    {
        import std.file : write, mkdirRecurse;
        
        auto localPath = getLocalPath(id);
        auto dir = dirName(localPath);
        
        if (!exists(dir))
            mkdirRecurse(dir);
        
        write(localPath, data);
        currentCacheSize += data.length;
        
        // Evict old entries if cache is too large
        if (config.maxLocalCacheSize > 0 && currentCacheSize > config.maxLocalCacheSize)
        {
            evictOldEntries();
        }
    }
    
    /// Evict old cache entries (LRU-style)
    private void evictOldEntries() @trusted
    {
        import std.file : dirEntries, SpanMode, timeLastModified;
        import std.algorithm : sort;
        import std.array : array;
        
        try
        {
            // Get all cached files sorted by modification time
            auto files = dirEntries(config.localCachePath, SpanMode.depth)
                .array
                .sort!((a, b) => timeLastModified(a) < timeLastModified(b));
            
            // Remove oldest files until we're under the limit
            size_t freed = 0;
            foreach (file; files)
            {
                if (currentCacheSize - freed <= config.maxLocalCacheSize * 0.8) // 80% threshold
                    break;
                
                try
                {
                    import std.file : getSize;
                    immutable fileSize = getSize(file);
                    remove(file);
                    freed += fileSize;
                    structuredLog.debug_("evicted_cache_entry_").field("detail", "Evicted cache entry: " ~ baseName(file)).emit();
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_evict_cache_entry_").field("detail", "Failed to evict cache entry: " ~ e.msg).emit();
                }
            }
            
            currentCacheSize -= freed;
            structuredLog.info("evicted_").field("detail", "Evicted " ~ freed.to!string ~ " bytes from artifact cache").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("cache_eviction_failed_").field("detail", "Cache eviction failed: " ~ e.msg).emit();
        }
    }
    
    /// Fetch artifact from remote store via HTTP
    private BuildResult!(ubyte[]) fetchRemote(ArtifactId id) @trusted
    {
        immutable url = config.remoteUrl ~ "/artifacts/" ~ id.toString();
        return executeHttpGet(url);
    }
    
    /// Upload artifact to remote store via HTTP
    private VoidBuildResult uploadRemote(ArtifactId id, const ubyte[] data) @trusted
    {
        immutable url = config.remoteUrl ~ "/artifacts/" ~ id.toString();
        return executeHttpPut(url, data);
    }
    
    /// Execute HTTP GET request
    private BuildResult!(ubyte[]) executeHttpGet(string url) @trusted
    {
        import std.string : indexOf, startsWith;
        
        // Parse URL
        string host;
        ushort port = 80;
        string path;
        
        string remaining = url;
        if (SIMDStrings.startsWith(remaining, "http://"))
            remaining = remaining[7 .. $];
        else if (SIMDStrings.startsWith(remaining, "https://"))
        {
            remaining = remaining[8 .. $];
            port = 443;
        }
        
        immutable slashPos = remaining.indexOf('/');
        if (slashPos >= 0)
        {
            host = remaining[0 .. slashPos];
            path = remaining[slashPos .. $];
        }
        else
        {
            host = remaining;
            path = "/";
        }
        
        // Extract port if present
        immutable colonPos = host.indexOf(':');
        if (colonPos >= 0)
        {
            port = host[colonPos + 1 .. $].to!ushort;
            host = host[0 .. colonPos];
        }
        
        try
        {
            auto addr = new InternetAddress(host, port);
            auto socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, config.timeout);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, config.timeout);
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            // Build HTTP request
            string request = "GET " ~ path ~ " HTTP/1.1\r\n";
            request ~= "Host: " ~ host ~ "\r\n";
            request ~= "Connection: close\r\n";
            request ~= "\r\n";
            
            // Send request
            socket.send(request);
            
            // Receive response
            ubyte[] responseData;
            ubyte[8192] buffer;
            while (true)
            {
                auto received = socket.receive(buffer);
                if (received <= 0)
                    break;
                responseData ~= buffer[0 .. received];
            }
            
            // Parse HTTP response
            immutable responseStr = cast(string)responseData;
            immutable headersEnd = responseStr.indexOf("\r\n\r\n");
            if (headersEnd < 0)
            {
                auto error = new DistributedError(Network.Error, "Invalid HTTP response");
                return Err!(ubyte[], BuildError)(error);
            }
            
            // Extract status code
            immutable firstLine = responseStr[0 .. responseStr.indexOf('\r')];
            import std.string : split;
            auto parts = firstLine.split(' ');
            if (parts.length < 2)
            {
                auto error = new DistributedError(Network.Error, "Invalid HTTP status line");
                return Err!(ubyte[], BuildError)(error);
            }
            
            immutable statusCode = parts[1].to!int;
            if (statusCode == 404)
                return Err!(ubyte[], BuildError)(
                    Errors.cache("Artifact not found", Cache.NotFound));
            else if (statusCode >= 400)
            {
                auto error = new DistributedError(
                    Network.Error,
                    "HTTP error: " ~ statusCode.to!string
                );
                return Err!(ubyte[], BuildError)(error);
            }
            
            // Extract body
            auto body_ = cast(ubyte[])responseData[headersEnd + 4 .. $];
            return Ok!(ubyte[], BuildError)(body_);
        }
        catch (Exception e)
        {
            auto error = new DistributedError(Network.Error, "HTTP GET failed: " ~ e.msg);
            return Err!(ubyte[], BuildError)(error);
        }
    }
    
    /// Execute HTTP PUT request
    private VoidBuildResult executeHttpPut(string url, const ubyte[] data) @trusted
    {
        import std.string : indexOf, startsWith;
        
        // Parse URL (same as GET)
        string host;
        ushort port = 80;
        string path;
        
        string remaining = url;
        if (SIMDStrings.startsWith(remaining, "http://"))
            remaining = remaining[7 .. $];
        else if (SIMDStrings.startsWith(remaining, "https://"))
        {
            remaining = remaining[8 .. $];
            port = 443;
        }
        
        immutable slashPos = remaining.indexOf('/');
        if (slashPos >= 0)
        {
            host = remaining[0 .. slashPos];
            path = remaining[slashPos .. $];
        }
        else
        {
            host = remaining;
            path = "/";
        }
        
        immutable colonPos = host.indexOf(':');
        if (colonPos >= 0)
        {
            port = host[colonPos + 1 .. $].to!ushort;
            host = host[0 .. colonPos];
        }
        
        try
        {
            auto addr = new InternetAddress(host, port);
            auto socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, config.timeout);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, config.timeout);
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            // Build HTTP request
            string request = "PUT " ~ path ~ " HTTP/1.1\r\n";
            request ~= "Host: " ~ host ~ "\r\n";
            request ~= "Content-Length: " ~ data.length.to!string ~ "\r\n";
            request ~= "Content-Type: application/octet-stream\r\n";
            request ~= "\r\n";
            
            // Send request and body
            socket.send(request);
            socket.send(data);
            
            // Receive response
            ubyte[4096] buffer;
            ubyte[] responseData;
            while (true)
            {
                auto received = socket.receive(buffer);
                if (received <= 0)
                    break;
                responseData ~= buffer[0 .. received];
            }
            
            // Check status code
            immutable responseStr = cast(string)responseData;
            if (responseStr.length > 0)
            {
                immutable firstLine = responseStr[0 .. responseStr.indexOf('\r')];
                import std.string : split;
                auto parts = firstLine.split(' ');
                if (parts.length >= 2)
                {
                    immutable statusCode = parts[1].to!int;
                    if (statusCode >= 400)
                    {
                        auto error = new DistributedError(
                            Network.Error,
                            "HTTP PUT error: " ~ statusCode.to!string
                        );
                        return VoidBuildResult.err(error);
                    }
                }
            }
            
            return Ok!BuildError();
        }
        catch (Exception e)
        {
            auto error = new DistributedError(Network.Error, "HTTP PUT failed: " ~ e.msg);
            return VoidBuildResult.err(error);
        }
    }
}

