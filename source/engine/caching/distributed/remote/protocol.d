module engine.caching.distributed.remote.protocol;

import std.datetime : SysTime, Duration;
import core.time : seconds;
import std.conv : to;
import infrastructure.utils.serialization;
import engine.caching.distributed.remote.schema;
import infrastructure.errors;

/// Remote cache protocol version
enum ProtocolVersion : ubyte
{
    V1 = 1  // Initial version
}

/// Cache artifact metadata
struct ArtifactMetadata
{
    string contentHash;     // BLAKE3 hash
    size_t size;            // Uncompressed size
    size_t compressedSize;  // Compressed size (0 if not compressed)
    SysTime timestamp;      // Creation time
    string workspace;       // Workspace identifier
    bool compressed;        // Whether artifact is compressed
    
    /// Serialize to binary format using high-performance Codec
    ubyte[] serialize() const @trusted
    {
        auto serializable = toSerializable(this);
        return Codec.serialize(serializable);
    }
    
    /// Deserialize from binary format using high-performance Codec
    static BuildResult!ArtifactMetadata deserialize(const(ubyte)[] data) @system
    {
        if (data.length < 8)
            return Err!(ArtifactMetadata, BuildError)(
                Errors.cache("Invalid artifact metadata: insufficient data", ErrorCode.CacheCorrupted).build());
        
        try
        {
            auto result = Codec.deserialize!SerializableArtifactMetadata(cast(ubyte[])data);
            
            if (result.isErr)
                return Err!(ArtifactMetadata, BuildError)(
                    Errors.cache("Failed to deserialize artifact metadata: " ~ result.unwrapErr(), ErrorCode.CacheCorrupted).build());
            
            auto serializable = result.unwrap();
            auto meta = fromSerializable!ArtifactMetadata(serializable);
            
            return Ok!(ArtifactMetadata, BuildError)(meta);
        }
        catch (Exception e)
        {
            return Err!(ArtifactMetadata, BuildError)(
                Errors.cache("Exception during deserialization: " ~ e.msg, ErrorCode.CacheCorrupted).build());
        }
    }
}

/// Cache request message
struct CacheRequest
{
    string contentHash;     // BLAKE3 hash of artifact
    string workspace;       // Workspace identifier
}

/// Cache response message  
struct CacheResponse
{
    bool found;             // Whether artifact was found
    ArtifactMetadata meta;  // Metadata if found
    ubyte[] data;           // Artifact data if found
}

/// Remote cache client configuration
struct RemoteCacheConfig
{
    string serverUrl;       // Cache server URL
    string url;             // Server URL (alias for compatibility)
    string authToken;       // Authentication token
    Duration timeout = 30.seconds;  // Request timeout
    size_t maxRetries = 3;  // Maximum retry attempts
    bool compression = true;  // Enable compression
    string workspace = "";  // Workspace identifier
    size_t maxArtifactSize = 100_000_000;  // 100 MB max per artifact
    bool enableCompression = true;   // Enable zstd compression
    size_t maxConnections = 4;       // Connection pool size
    
    /// Load configuration from environment
    static RemoteCacheConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        RemoteCacheConfig config;
        
        // Required: URL
        config.serverUrl = environment.get("BUILDER_REMOTE_CACHE_URL", "");
        config.url = config.serverUrl;  // Alias for compatibility
        
        // Optional: Auth token
        config.authToken = environment.get("BUILDER_REMOTE_CACHE_TOKEN", "");
        
        // Optional: Timeout (seconds)
        immutable timeoutStr = environment.get("BUILDER_REMOTE_CACHE_TIMEOUT");
        if (timeoutStr.length > 0)
            config.timeout = timeoutStr.to!size_t.seconds;
        
        // Optional: Max retries
        immutable retriesStr = environment.get("BUILDER_REMOTE_CACHE_RETRIES");
        if (retriesStr.length > 0)
            config.maxRetries = retriesStr.to!size_t;
        
        // Optional: Max connections
        immutable connsStr = environment.get("BUILDER_REMOTE_CACHE_CONNECTIONS");
        if (connsStr.length > 0)
            config.maxConnections = connsStr.to!size_t;
        
        // Optional: Max artifact size (bytes)
        immutable sizeStr = environment.get("BUILDER_REMOTE_CACHE_MAX_SIZE");
        if (sizeStr.length > 0)
            config.maxArtifactSize = sizeStr.to!size_t;
        
        // Optional: Compression
        immutable compressStr = environment.get("BUILDER_REMOTE_CACHE_COMPRESS");
        if (compressStr.length > 0)
            config.enableCompression = compressStr != "false" && compressStr != "0";
        
        return config;
    }
    
    /// Check if remote cache is enabled
    bool enabled() const pure @safe nothrow
    {
        return serverUrl.length > 0;
    }
}

/// Remote cache statistics
struct RemoteCacheStats
{
    size_t getRequests;      // Number of GET requests
    size_t putRequests;      // Number of PUT requests
    size_t headRequests;     // Number of HEAD requests
    size_t hits;             // Cache hits
    size_t misses;           // Cache misses
    size_t errors;           // Request errors
    size_t bytesUploaded;    // Total bytes sent
    size_t bytesDownloaded;  // Total bytes received
    float hitRate;           // Hit rate percentage
    float averageLatency;    // Average request latency (ms)
    
    // FastCDC delta transfer statistics
    size_t cdcChunksUploaded;   // Chunks uploaded (new)
    size_t cdcChunksReused;     // Chunks reused (delta savings)
    size_t cdcChunksDownloaded; // Chunks downloaded
    
    // Delta compression statistics (rsync-style)
    size_t deltaUploads;        // Number of delta uploads
    size_t deltaByteSavings;    // Bytes saved via delta compression
    size_t deltaReconstructions; // Successful delta reconstructions
    
    /// Compute derived statistics
    void compute() pure @safe nothrow
    {
        immutable total = hits + misses;
        hitRate = total > 0 ? (hits * 100.0) / total : 0.0;
    }
    
    /// CDC bandwidth savings percentage
    float cdcSavingsPercent() const pure @safe nothrow
    {
        immutable total = cdcChunksUploaded + cdcChunksReused;
        return total > 0 ? (cdcChunksReused * 100.0f) / total : 0.0f;
    }
    
    /// Delta compression savings percentage
    float deltaSavingsPercent() const pure @safe nothrow
    {
        immutable total = bytesUploaded + deltaByteSavings;
        return total > 0 ? (deltaByteSavings * 100.0f) / total : 0.0f;
    }
}
