module engine.caching.distributed.remote.unified;

import std.datetime : Duration, seconds;
import std.algorithm : startsWith;
import engine.caching.distributed.remote.artifact;
import engine.caching.distributed.remote.protocol : RemoteCacheConfig;
import infrastructure.errors;

/**
 * Unified Artifact Transport Factory
 * 
 * Creates optimal transport based on configuration:
 * - HTTP/1.1: Default, no dependencies, wide compatibility
 * - gRPC/HTTP2: High throughput via multiplexing for REAPI backends
 * 
 * SoC: Factory lives in caching layer (consumer), delegates to
 * protocol layer implementations (HTTP transport, gRPC CAS transport).
 */
final class ArtifactTransportFactory {
    
    /// Transport type selection
    enum Type { Http, Grpc, Auto }
    
    /// Create transport from configuration
    static BuildResult!ArtifactTransport create(ArtifactTransportConfig config) @trusted {
        final switch (config.transportType) {
            case Type.Http:
                return createHttpTransport(config);
            case Type.Grpc:
                return createGrpcTransport(config);
            case Type.Auto:
                return createAutoTransport(config);
        }
    }
    
    /// Create from URL with auto-detection
    static BuildResult!ArtifactTransport fromUrl(string url) @trusted =>
        create(ArtifactTransportConfig.fromUrl(url));
    
    /// Create from RemoteCacheConfig
    static BuildResult!ArtifactTransport fromCacheConfig(RemoteCacheConfig config) @trusted {
        ArtifactTransportConfig transportConfig;
        transportConfig.endpoint = config.url.length > 0 ? config.url : config.serverUrl;
        transportConfig.timeout = config.timeout;
        transportConfig.maxRetries = config.maxRetries;
        transportConfig.authToken = config.authToken;
        transportConfig.enableCompression = config.enableCompression;
        transportConfig.transportType = Type.Auto;
        
        return create(transportConfig);
    }
    
    private static BuildResult!ArtifactTransport createHttpTransport(
        ArtifactTransportConfig config
    ) @trusted {
        import engine.caching.distributed.remote.transport : HttpTransport;
        
        RemoteCacheConfig cacheConfig;
        cacheConfig.url = config.endpoint;
        cacheConfig.serverUrl = config.endpoint;
        cacheConfig.timeout = config.timeout;
        cacheConfig.maxRetries = config.maxRetries;
        cacheConfig.authToken = config.authToken;
        cacheConfig.enableCompression = config.enableCompression;
        cacheConfig.maxConnections = config.maxConnections;
        
        auto transport = new HttpArtifactTransport(cacheConfig);
        return Ok!(ArtifactTransport, BuildError)(transport);
    }
    
    private static BuildResult!ArtifactTransport createGrpcTransport(
        ArtifactTransportConfig config
    ) @trusted {
        import engine.distributed.protocol.grpc.cas : GrpcCasFactory;
        
        auto result = GrpcCasFactory.fromUrl(config.endpoint, config.instanceName);
        if (result.isErr) return Err!(ArtifactTransport, BuildError)(result.unwrapErr());
        
        return Ok!(ArtifactTransport, BuildError)(cast(ArtifactTransport)result.unwrap());
    }
    
    private static BuildResult!ArtifactTransport createAutoTransport(
        ArtifactTransportConfig config
    ) @trusted {
        // Auto-detect based on URL scheme
        if (config.endpoint.startsWith("grpc://") || config.endpoint.startsWith("grpcs://"))
            return createGrpcTransport(config);
        
        // Default to HTTP for http://, https://, or unspecified
        return createHttpTransport(config);
    }
}

/// Transport configuration
struct ArtifactTransportConfig {
    string endpoint;                             // Server URL
    ArtifactTransportFactory.Type transportType = ArtifactTransportFactory.Type.Auto;
    Duration timeout = 30.seconds;               // Request timeout
    size_t maxRetries = 3;                       // Max retry attempts
    string authToken;                            // Auth token
    bool enableCompression = true;               // Wire compression
    size_t maxConnections = 4;                   // HTTP connection pool size
    string instanceName;                         // REAPI instance name (gRPC)
    
    /// Create from URL with auto-detection
    static ArtifactTransportConfig fromUrl(string url) @safe {
        ArtifactTransportConfig config;
        config.endpoint = url;
        
        if (url.startsWith("grpc://") || url.startsWith("grpcs://"))
            config.transportType = ArtifactTransportFactory.Type.Grpc;
        else
            config.transportType = ArtifactTransportFactory.Type.Http;
        
        return config;
    }
    
    /// Create gRPC config
    static ArtifactTransportConfig grpc(string endpoint, string instanceName = "") @safe {
        ArtifactTransportConfig config;
        config.endpoint = endpoint;
        config.transportType = ArtifactTransportFactory.Type.Grpc;
        config.instanceName = instanceName;
        return config;
    }
    
    /// Create HTTP config
    static ArtifactTransportConfig http(string endpoint) @safe {
        ArtifactTransportConfig config;
        config.endpoint = endpoint;
        config.transportType = ArtifactTransportFactory.Type.Http;
        return config;
    }
}

/**
 * HTTP Artifact Transport Adapter
 * 
 * Wraps HttpTransport to implement ArtifactTransport interface.
 * Maintains SoC by adapting existing transport to new interface.
 */
private final class HttpArtifactTransport : ArtifactTransport {
    import engine.caching.distributed.remote.transport : HttpTransport;
    
    private HttpTransport transport;
    private RemoteCacheConfig config;
    
    this(RemoteCacheConfig config) @trusted {
        this.config = config;
        this.transport = new HttpTransport(config);
    }
    
    BuildResult!(ubyte[]) get(string contentHash) @trusted =>
        transport.get(contentHash);
    
    VoidBuildResult put(string contentHash, const(ubyte)[] data) @trusted =>
        transport.put(contentHash, data);
    
    BuildResult!bool has(string contentHash) @trusted =>
        transport.head(contentHash);
    
    VoidBuildResult remove(string contentHash) @trusted =>
        transport.remove(contentHash);
    
    void close() @trusted {
        // HttpTransport cleanup handled by destructor
    }
    
    bool isConnected() @trusted => true; // HTTP is connectionless per-request
    
    TransportCapabilities capabilities() const @safe =>
        TransportCapabilities.http();
}


