module engine.caching.distributed.remote;

/// Production-ready remote caching module
/// Provides distributed cache for build artifacts across teams and CI/CD
/// 
/// Architecture:
/// - Content-addressable storage (BLAKE3)
/// - HTTP/1.1 transport (default, no external dependencies)
/// - gRPC/HTTP2 transport (high-throughput, REAPI-compatible)
/// - LRU eviction with configurable limits
/// - Workspace isolation via HMAC
/// - Connection pooling and retry logic
/// 
/// Transport Options:
/// - HTTP/1.1: Default, wide compatibility, connection pooling
/// - gRPC/HTTP2: Multiplexing, ByteStream, batch ops (BuildBuddy/BuildBarn/REAPI)
/// 
/// Production Features:
/// - Connection Pool: Bounded thread pool (not thread-per-connection)
/// - Compression: Zstd/LZ4 with adaptive selection
/// - Rate Limiting: Token bucket with reputation tracking
/// - TLS: Built-in HTTPS support
/// - Metrics: Prometheus endpoint (/metrics)
/// - CDN: Cache headers and signed URLs
/// - Health: /health endpoint
/// - HTTP/2 Multiplexing: Concurrent artifact transfers via gRPC
/// 
/// Usage:
/// ```d
/// // Unified Transport (auto-detects HTTP vs gRPC from URL)
/// auto transport = ArtifactTransportFactory.fromUrl("grpc://cas:50051").unwrap();
/// transport.put("hash123", data);
/// auto blob = transport.get("hash123").unwrap();
/// 
/// // High-throughput gRPC with multiplexing
/// import engine.distributed.protocol.grpc.cas;
/// auto grpc = GrpcCasFactory.fromUrl("grpc://cas:50051").unwrap();
/// auto results = grpc.multiplexedUpload(blobs, 10);  // 10 concurrent streams
/// 
/// // Legacy client (HTTP/1.1)
/// auto config = RemoteCacheConfig.fromEnvironment();
/// auto client = new RemoteCacheClient(config);
/// auto result = client.get(contentHash);
/// 
/// // Server
/// auto server = new CacheServer("0.0.0.0", 8080);
/// server.start();
/// ```

public import engine.caching.distributed.remote.protocol;
public import engine.caching.distributed.remote.schema;
public import engine.caching.distributed.remote.transport;
public import engine.caching.distributed.remote.client;
public import engine.caching.distributed.remote.server;
public import engine.caching.distributed.remote.limiter;
public import engine.caching.distributed.remote.compress;
public import engine.caching.distributed.remote.metrics;
public import engine.caching.distributed.remote.tls;
public import engine.caching.distributed.remote.cdn;
public import engine.caching.distributed.remote.artifact;
public import engine.caching.distributed.remote.unified;
public import engine.caching.distributed.remote.delta;
public import engine.caching.distributed.remote.tracing;


