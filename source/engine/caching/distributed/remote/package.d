module engine.caching.distributed.remote;

/// Production-ready remote caching module
/// Provides distributed cache for build artifacts across teams and CI/CD
/// 
/// Architecture:
/// - Content-addressable storage (BLAKE3)
/// - HTTP/1.1 transport (no external dependencies)
/// - LRU eviction with configurable limits
/// - Workspace isolation via HMAC
/// - Connection pooling and retry logic
/// 
/// Production Features:
/// - Connection Pool: Bounded thread pool (not thread-per-connection)
/// - Compression: Zstd/LZ4 with adaptive selection
/// - Rate Limiting: Token bucket with reputation tracking
/// - TLS: Built-in HTTPS support
/// - Metrics: Prometheus endpoint (/metrics)
/// - CDN: Cache headers and signed URLs
/// - Health: /health endpoint
/// 
/// Usage:
/// ```d
/// // Client
/// auto config = RemoteCacheConfig.fromEnvironment();
/// auto client = new RemoteCacheClient(config);
/// auto result = client.get(contentHash);
/// 
/// // Server
/// auto server = new CacheServer("0.0.0.0", 8080);
/// server.start();
/// 
/// // Production Server (with thread pool tuning)
/// auto tlsConfig = TlsConfig("cert.pem", "key.pem");
/// auto cdnConfig = CdnConfig("cdn.example.com", "signing-key");
/// auto prodServer = new CacheServer(
///     "0.0.0.0", 8080, ".cache",
///     "auth-token", 100_000_000_000,
///     true, true, true,  // compression, rate limiting, metrics
///     tlsConfig, cdnConfig,
///     32,    // worker threads (0 = 2*CPUs)
///     4096   // connection queue size
/// );
/// prodServer.start();
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


