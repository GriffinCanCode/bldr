module engine.distributed.protocol.grpc.factory;

import std.datetime : Duration, seconds;
import std.string : startsWith;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport : Transport, HttpTransport, TransportFactory;
import engine.distributed.protocol.grpc.transport : GrpcTransport, GrpcConfig;
import infrastructure.errors;

/**
 * Transport type enumeration
 */
enum TransportType {
    Http,       // HTTP/1.1 (default, no dependencies)
    Grpc,       // gRPC/HTTP2 (pure D implementation)
    Auto        // Auto-detect from URL
}

/**
 * Unified transport configuration
 */
struct TransportConfig {
    TransportType type = TransportType.Auto;
    string endpoint;                          // Target endpoint
    bool useTls = false;                      // Use TLS?
    Duration connectTimeout = 30.seconds;     // Connection timeout
    Duration callTimeout = 60.seconds;        // Call timeout
    size_t maxRetries = 3;                    // Max retry attempts
    
    // TLS settings
    string rootCerts;                         // Root CA certificates
    string clientCert;                        // Client certificate
    string clientKey;                         // Client private key
    
    // gRPC-specific
    size_t maxMessageSize = 4 * 1024 * 1024;  // 4MB default
    bool enableRetry = true;                  // Enable automatic retry
    
    /// Create config from URL with auto-detection
    static TransportConfig fromUrl(string url) pure @safe {
        TransportConfig config;
        config.endpoint = url;
        
        if (url.startsWith("grpc://")) {
            config.type = TransportType.Grpc;
            config.endpoint = url[7 .. $];
            config.useTls = false;
        } else if (url.startsWith("grpcs://")) {
            config.type = TransportType.Grpc;
            config.endpoint = url[8 .. $];
            config.useTls = true;
        } else if (url.startsWith("https://")) {
            config.type = TransportType.Http;
            config.endpoint = url[8 .. $];
            config.useTls = true;
        } else if (url.startsWith("http://")) {
            config.type = TransportType.Http;
            config.endpoint = url[7 .. $];
            config.useTls = false;
        }
        
        return config;
    }
    
    /// Create insecure HTTP config
    static TransportConfig httpInsecure(string host, ushort port) pure @safe {
        TransportConfig config;
        config.type = TransportType.Http;
        config.endpoint = host ~ ":" ~ port.stringof;
        config.useTls = false;
        return config;
    }
    
    /// Create insecure gRPC config
    static TransportConfig grpcInsecure(string endpoint) pure nothrow @safe {
        TransportConfig config;
        config.type = TransportType.Grpc;
        config.endpoint = endpoint;
        config.useTls = false;
        return config;
    }
    
    /// Create secure gRPC config
    static TransportConfig grpcSecure(string endpoint, string rootCerts = "") pure nothrow @safe {
        TransportConfig config;
        config.type = TransportType.Grpc;
        config.endpoint = endpoint;
        config.useTls = true;
        config.rootCerts = rootCerts;
        return config;
    }
}

/**
 * Unified transport factory
 * Creates appropriate transport based on configuration
 */
final class UnifiedTransportFactory {
    
    /// Create transport from configuration
    static Result!(Transport, DistributedError) create(TransportConfig config) @trusted {
        final switch (config.type) {
            case TransportType.Http:
                return createHttpTransport(config);
            case TransportType.Grpc:
                return createGrpcTransport(config);
            case TransportType.Auto:
                return createAutoTransport(config);
        }
    }
    
    /// Create transport from URL (convenience)
    static Result!(Transport, DistributedError) createFromUrl(string url) @trusted =>
        create(TransportConfig.fromUrl(url));
    
    /// Create HTTP transport
    private static Result!(Transport, DistributedError) createHttpTransport(
        TransportConfig config
    ) @trusted {
        import std.string : split;
        import std.conv : to;
        
        auto parts = config.endpoint.split(":");
        if (parts.length != 2)
            return Err!(Transport, DistributedError)(
                new DistributedError("Invalid HTTP endpoint: " ~ config.endpoint));
        
        try {
            auto transport = new HttpTransport(
                parts[0], 
                parts[1].to!ushort, 
                config.connectTimeout
            );
            
            auto connectResult = transport.connect();
            if (connectResult.isErr)
                return Err!(Transport, DistributedError)(connectResult.unwrapErr());
            
            return Ok!(Transport, DistributedError)(cast(Transport)transport);
        } catch (Exception e) {
            return Err!(Transport, DistributedError)(
                new DistributedError("Failed to create HTTP transport: " ~ e.msg));
        }
    }
    
    /// Create gRPC transport
    private static Result!(Transport, DistributedError) createGrpcTransport(
        TransportConfig config
    ) @trusted {
        GrpcConfig grpcConfig;
        grpcConfig.target = config.endpoint;
        grpcConfig.useTls = config.useTls;
        grpcConfig.rootCerts = config.rootCerts;
        grpcConfig.clientCert = config.clientCert;
        grpcConfig.clientKey = config.clientKey;
        grpcConfig.connectTimeout = config.connectTimeout;
        grpcConfig.callTimeout = config.callTimeout;
        grpcConfig.maxMessageSize = config.maxMessageSize;
        grpcConfig.enableRetry = config.enableRetry;
        grpcConfig.maxRetries = config.maxRetries;
        
        try {
            auto transport = new GrpcTransport(grpcConfig);
            return Ok!(Transport, DistributedError)(cast(Transport)transport);
        } catch (Exception e) {
            return Err!(Transport, DistributedError)(
                new DistributedError("Failed to create gRPC transport: " ~ e.msg));
        }
    }
    
    /// Auto-detect and create transport
    private static Result!(Transport, DistributedError) createAutoTransport(
        TransportConfig config
    ) @trusted {
        // Try gRPC first (preferred for remote execution)
        auto grpcResult = createGrpcTransport(config);
        if (grpcResult.isOk)
            return grpcResult;
        
        // Fall back to HTTP
        return createHttpTransport(config);
    }
    
    /// Check if gRPC is available (pure D implementation - always available)
    static bool isGrpcAvailable() @trusted nothrow {
        return true;  // Pure D HTTP/2 + gRPC implementation
    }
}

/**
 * Transport selection strategy
 */
enum TransportStrategy {
    PreferGrpc,     // Use gRPC if available, fall back to HTTP
    PreferHttp,     // Use HTTP if available, fall back to gRPC
    GrpcOnly,       // Only use gRPC (fail if unavailable)
    HttpOnly,       // Only use HTTP
    RoundRobin      // Alternate between transports
}

/**
 * Transport pool for multiple endpoints
 */
final class TransportPool {
    private Transport[] transports;
    private TransportConfig[] configs;
    private size_t currentIndex;
    private TransportStrategy strategy;
    
    this(TransportStrategy strategy = TransportStrategy.PreferGrpc) @safe {
        this.strategy = strategy;
    }
    
    /// Add endpoint to pool
    void addEndpoint(TransportConfig config) @safe {
        configs ~= config;
    }
    
    /// Get transport (creates if needed)
    Result!(Transport, DistributedError) getTransport() @trusted {
        if (configs.length == 0)
            return Err!(Transport, DistributedError)(
                new DistributedError("No endpoints configured"));
        
        // Round-robin selection
        auto config = configs[currentIndex % configs.length];
        currentIndex++;
        
        // Apply strategy
        final switch (strategy) {
            case TransportStrategy.PreferGrpc:
                config.type = UnifiedTransportFactory.isGrpcAvailable() 
                    ? TransportType.Grpc 
                    : TransportType.Http;
                break;
            case TransportStrategy.PreferHttp:
                config.type = TransportType.Http;
                break;
            case TransportStrategy.GrpcOnly:
                config.type = TransportType.Grpc;
                break;
            case TransportStrategy.HttpOnly:
                config.type = TransportType.Http;
                break;
            case TransportStrategy.RoundRobin:
                config.type = (currentIndex % 2 == 0) 
                    ? TransportType.Grpc 
                    : TransportType.Http;
                break;
        }
        
        return UnifiedTransportFactory.create(config);
    }
    
    /// Close all transports
    void closeAll() @trusted {
        foreach (transport; transports)
            transport.close();
        transports = [];
    }
}

