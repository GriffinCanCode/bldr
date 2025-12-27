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
                Errors.cache("Invalid artifact metadata: insufficient data", Cache.Corrupted).build());
        
        try
        {
            auto result = Codec.deserialize!SerializableArtifactMetadata(cast(ubyte[])data);
            
            if (result.isErr)
                return Err!(ArtifactMetadata, BuildError)(
                    Errors.cache("Failed to deserialize artifact metadata: " ~ result.unwrapErr(), Cache.Corrupted).build());
            
            auto serializable = result.unwrap();
            auto meta = fromSerializable!ArtifactMetadata(serializable);
            
            return Ok!(ArtifactMetadata, BuildError)(meta);
        }
        catch (Exception e)
        {
            return Err!(ArtifactMetadata, BuildError)(
                Errors.cache("Exception during deserialization: " ~ e.msg, Cache.Corrupted).build());
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
        
        // Required: URL (check multiple sources)
        config.serverUrl = environment.get("BUILDER_REMOTE_CACHE_URL", "");
        
        // Auto-discovery: try well-known locations if not explicitly set
        if (config.serverUrl.length == 0)
            config.serverUrl = discoverCacheServer();
        
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
    
    /// Auto-discover cache server from well-known locations
    /// Checks: .bldr-cache file, CI environment variables, common hostnames
    private static string discoverCacheServer() @system
    {
        import std.process : environment;
        import std.file : exists, readText;
        import std.string : strip, startsWith;
        import std.algorithm : canFind;
        
        // 1. Check for .bldr-cache config file in project root
        if (exists(".bldr-cache"))
        {
            try
            {
                auto contents = readText(".bldr-cache").strip;
                if (contents.startsWith("http://") || contents.startsWith("https://") || 
                    contents.startsWith("grpc://"))
                    return contents;
            }
            catch (Exception) {}
        }
        
        // 2. Check CI-specific environment variables
        static immutable ciEnvVars = [
            "BUILDBUDDY_CACHE_URL",   // BuildBuddy
            "BUILDBARN_CACHE_URL",    // BuildBarn
            "REMOTE_CACHE_URL",       // Generic CI
            "BAZEL_REMOTE_CACHE",     // Bazel-compatible
            "TURBO_REMOTE_CACHE_URL", // Turborepo
        ];
        
        foreach (envVar; ciEnvVars)
        {
            auto val = environment.get(envVar, "");
            if (val.length > 0) return val;
        }
        
        // 3. Try common internal hostnames (only in CI environments)
        auto ciEnv = environment.get("CI", "");
        if (ciEnv == "true" || ciEnv == "1")
        {
            static immutable commonHosts = [
                "http://cache:8080",          // Docker Compose default
                "http://bldr-cache:8080",     // bldr-specific
                "http://build-cache:8080",    // Generic
                "http://remote-cache:8080",   // Another common name
            ];
            
            foreach (host; commonHosts)
            {
                if (testCacheConnection(host))
                    return host;
            }
        }
        
        return "";  // No cache discovered
    }
    
    /// Test if a cache server is reachable
    private static bool testCacheConnection(string url) @system nothrow
    {
        import std.socket : TcpSocket, getAddress, SocketOSException;
        import std.string : indexOf;
        import core.time : dur;
        
        try
        {
            // Parse host:port from URL
            auto start = url.indexOf("://");
            if (start < 0) return false;
            
            auto hostPort = url[start + 3 .. $];
            auto colonIdx = hostPort.indexOf(":");
            if (colonIdx < 0) return false;
            
            auto host = hostPort[0 .. colonIdx];
            auto portStr = hostPort[colonIdx + 1 .. $];
            
            // Remove path if present
            auto slashIdx = portStr.indexOf("/");
            if (slashIdx >= 0) portStr = portStr[0 .. slashIdx];
            
            ushort port = 8080;
            try { port = cast(ushort)portStr.to!int; } catch (Exception) {}
            
            // Try to connect with short timeout
            auto socket = new TcpSocket();
            scope(exit) socket.close();
            
            // Set socket timeout using blocking with limited time
            socket.blocking = true;
            
            auto addresses = getAddress(host, port);
            if (addresses.length == 0) return false;
            
            socket.connect(addresses[0]);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Generate setup instructions for remote cache
    static string getSetupInstructions() pure @safe nothrow
    {
        return `Remote Cache Setup Guide
========================

1. Quick Start (Docker):
   docker run -p 8080:8080 ghcr.io/buchgr/bazel-remote-cache

2. Configure:
   export BUILDER_REMOTE_CACHE_URL=http://localhost:8080
   export BUILDER_REMOTE_CACHE_TOKEN=your-token  # if auth required

3. Or create .bldr-cache file:
   echo "http://cache-server:8080" > .bldr-cache

4. CI Integration (GitHub Actions):
   env:
     BUILDER_REMOTE_CACHE_URL: ${{ secrets.CACHE_URL }}
     BUILDER_REMOTE_CACHE_TOKEN: ${{ secrets.CACHE_TOKEN }}

Expected Speedup: 70-85% faster CI builds with warm cache
`;
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
