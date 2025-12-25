# Remote Caching

Production-ready remote caching for distributed builds.

## Overview

Remote caching enables distributed builds by sharing build artifacts across developers and CI/CD pipelines. Content-addressable HTTP cache with enterprise features built on D's standard library.

### Features

- **Compression**: Zstd/LZ4 with adaptive selection
- **Rate Limiting**: Token bucket with hierarchical limits
- **Prometheus Metrics**: `/metrics` endpoint
- **TLS Support**: Built-in HTTPS
- **CDN Integration**: CloudFront/Cloudflare support
- **Health Checks**: `/health` endpoint

### Benefits

- **Faster CI/CD builds**: Share artifacts across pipeline runs
- **Team velocity**: Pull artifacts built by teammates
- **Simple deployment**: Single binary, no dependencies
- **Secure**: BLAKE3 content addressing + Bearer token auth
- **Horizontally scalable**: Stateless design

## Architecture

### Design Principles

1. **Content-Addressable Storage** — Artifacts identified by BLAKE3 hash
   - Eliminates coordination overhead
   - Natural deduplication
   - Tamper-evident

2. **HTTP/1.1 Transport** — No dependencies, maximum compatibility
   - REST API (GET/PUT/HEAD/DELETE)
   - Standard HTTP caching
   - CDN-friendly

3. **Stateless Server** — Horizontal scaling without coordination
   - No shared state beyond filesystem
   - Load balancer ready

4. **Graceful Degradation** — Remote cache failures never block builds
   - Local cache fallback
   - Errors logged but not fatal

### System Diagram

```
┌──────────────┐                  ┌──────────────┐
│  Developer   │                  │     CI/CD    │
│   Machine    │                  │   Pipeline   │
└──────┬───────┘                  └──────┬───────┘
       │                                 │
       │  1. Check local cache           │
       │  2. Check remote cache          │
       │  3. Build if needed             │
       │  4. Push to remote              │
       │                                 │
       └────────┬───────────────┬────────┘
                │               │
                ▼               ▼
         ┌──────────────────────────┐
         │   Cache Server (HTTP)    │
         │  ┌────────────────────┐  │
         │  │  Content Store     │  │
         │  │  (Filesystem)      │  │
         │  │                    │  │
         │  │  /artifacts/       │  │
         │  │    abc123...       │  │
         │  │    def456...       │  │
         │  └────────────────────┘  │
         └──────────────────────────┘
```

## Implementation

### Core Components

#### 1. Protocol (`engine/caching/distributed/remote/protocol.d`)

**ArtifactMetadata:**
```d
struct ArtifactMetadata {
    string contentHash;     // BLAKE3 hash
    size_t size;            // Uncompressed size
    size_t compressedSize;  // Compressed size
    SysTime timestamp;      // Creation time
    string workspace;       // Workspace ID
    bool compressed;        // Compression flag
}
```

**RemoteCacheConfig:**
```d
struct RemoteCacheConfig {
    string serverUrl;                     // Server URL
    string authToken;                     // Bearer token
    Duration timeout = 30.seconds;        // Request timeout
    size_t maxRetries = 3;                // Retry attempts
    size_t maxConnections = 4;            // Connection pool
    size_t maxArtifactSize = 100_000_000; // 100 MB max
    bool enableCompression = true;
}
```

#### 2. Transport (`engine/caching/distributed/remote/transport.d`)

**HttpTransport** — Minimal HTTP/1.1 client:
- No external dependencies (uses `std.socket`)
- Connection pooling
- Automatic retry with exponential backoff
- Timeout handling

```d
Result!(ubyte[], BuildError) get(string contentHash);
VoidBuildResult put(string contentHash, const(ubyte)[] data);
Result!(bool, BuildError) head(string contentHash);
```

#### 3. Client (`engine/caching/distributed/remote/client.d`)

**RemoteCacheClient** — High-level cache client:
- Retry logic with backoff
- Statistics tracking
- Workspace isolation via HMAC
- Delta compression support
- Content-defined chunking for large artifacts

```d
auto config = RemoteCacheConfig.fromEnvironment();
auto client = new RemoteCacheClient(config);

// Check existence
auto hasResult = client.has(contentHash);

// Fetch artifact
auto getResult = client.get(contentHash);

// Store artifact
auto putResult = client.put(contentHash, artifactData);
```

#### 4. Server (`engine/caching/distributed/remote/server.d`)

**CacheServer** — Production HTTP cache server:
- Content-addressable storage
- LRU eviction when storage limit reached
- Optional Bearer token authentication
- Bounded thread pool (not thread-per-connection)
- Compression, rate limiting, TLS, metrics, CDN support

## Usage

### Server Setup

```bash
# Basic (no auth)
bldr cache-server

# With authentication
bldr cache-server --auth my-secret-token

# Custom configuration
bldr cache-server \
  --host 0.0.0.0 \
  --port 8080 \
  --storage /var/cache/bldr \
  --max-size 50000000000

# High-concurrency server
bldr cache-server \
  --workers 32 \
  --queue-size 4096
```

### Client Configuration

**Environment variables:**
```bash
# Required
export BUILDER_REMOTE_CACHE_URL=http://cache-server:8080

# Optional
export BUILDER_REMOTE_CACHE_TOKEN=my-secret-token
export BUILDER_REMOTE_CACHE_TIMEOUT=30       # seconds
export BUILDER_REMOTE_CACHE_RETRIES=3
export BUILDER_REMOTE_CACHE_CONNECTIONS=4
export BUILDER_REMOTE_CACHE_MAX_SIZE=100000000  # bytes
export BUILDER_REMOTE_CACHE_COMPRESS=true
```

**Build with remote cache:**
```bash
# Client automatically uses remote cache if configured
export BUILDER_REMOTE_CACHE_URL=http://localhost:8080
bldr build //...

# Cache statistics
bldr build //... --stats
#   Remote cache hits: 42
#   Remote cache misses: 8
#   Hit rate: 84.0%
```

### Health Check

```bash
curl http://localhost:8080/health
```
```json
{
  "status": "healthy",
  "uptime": 86400,
  "storage_used": 45678901234,
  "storage_total": 100000000000,
  "cache_hits": 8500,
  "cache_misses": 1500,
  "hit_rate": 85.0
}
```

### Prometheus Metrics

```bash
curl http://localhost:8080/metrics
```
```prometheus
# HELP builder_cache_requests_total Total number of requests
# TYPE builder_cache_requests_total counter
builder_cache_requests_total 12345

# HELP builder_cache_hit_rate Cache hit rate (0.0-1.0)
# TYPE builder_cache_hit_rate gauge
builder_cache_hit_rate 0.85

# HELP builder_cache_storage_bytes_used Storage space used (bytes)
# TYPE builder_cache_storage_bytes_used gauge
builder_cache_storage_bytes_used 45678901234

# HELP builder_cache_request_duration_milliseconds Request latency
# TYPE builder_cache_request_duration_milliseconds histogram
builder_cache_request_duration_milliseconds_bucket{le="1"} 5000
builder_cache_request_duration_milliseconds_bucket{le="5"} 8000
builder_cache_request_duration_milliseconds_bucket{le="10"} 9500
builder_cache_request_duration_milliseconds_bucket{le="+Inf"} 10000
```

### Docker Deployment

```dockerfile
FROM dlang/dmd:latest
COPY builder /usr/local/bin/
EXPOSE 8080
CMD ["builder", "cache-server", "--host", "0.0.0.0", "--port", "8080"]
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: builder-cache
spec:
  replicas: 3
  selector:
    matchLabels:
      app: builder-cache
  template:
    metadata:
      labels:
        app: builder-cache
    spec:
      containers:
      - name: cache-server
        image: builder:latest
        args: ["cache-server", "--host", "0.0.0.0", "--port", "8080"]
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: cache-storage
          mountPath: /cache-storage
        env:
        - name: BUILDER_CACHE_SERVER_AUTH_TOKEN
          valueFrom:
            secretKeyRef:
              name: builder-cache-auth
              key: token
      volumes:
      - name: cache-storage
        persistentVolumeClaim:
          claimName: builder-cache-pvc
```

## API Reference

### HTTP Endpoints

#### GET /artifacts/{hash}
Fetch artifact by content hash

**Response:**
- `200 OK` — Artifact data in body
- `404 Not Found` — Artifact not in cache
- `401 Unauthorized` — Invalid auth token

```bash
curl -H "Authorization: Bearer TOKEN" \
     http://cache:8080/artifacts/abc123...
```

#### PUT /artifacts/{hash}
Store artifact

**Request Body:** Binary artifact data

**Response:**
- `201 Created` — Artifact stored
- `413 Payload Too Large` — Exceeds size limit
- `401 Unauthorized` — Invalid auth token

```bash
curl -X PUT \
     -H "Authorization: Bearer TOKEN" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @artifact.bin \
     http://cache:8080/artifacts/abc123...
```

#### HEAD /artifacts/{hash}
Check artifact existence

**Response:**
- `200 OK` — Artifact exists
- `404 Not Found` — Artifact not in cache

```bash
curl -I -H "Authorization: Bearer TOKEN" \
     http://cache:8080/artifacts/abc123...
```

#### DELETE /artifacts/{hash}
Remove artifact (admin only)

**Response:**
- `204 No Content` — Artifact deleted
- `404 Not Found` — Artifact not found

## Performance

### Benchmarks

| Scenario | Without Cache | With Cache | Speedup |
|----------|--------------|------------|---------|
| Clean build (CI) | 15 min | 15 min | 1.0x |
| Incremental build (CI) | 5 min | 30 sec | 10x |
| Developer pull | 3 min | 10 sec | 18x |

### Network Overhead

- Latency: 10-50ms per artifact check
- Bandwidth: Artifacts typically < 10 MB
- Connection reuse: 4 concurrent connections per client

### Storage

- 1000 developers: ~50 GB/day
- Retention: 30 days (configurable)
- Total: ~1.5 TB (with eviction)

## Security

### Protected Against

- ✓ Cache poisoning — Content addressing prevents tampering
- ✓ Unauthorized access — Bearer token authentication
- ✓ Workspace isolation — Separate keys per workspace
- ✓ DoS via large artifacts — Size limits enforced
- ✓ Rate limiting attacks — Token bucket with reputation tracking
- ✓ Network sniffing — Built-in TLS support

### Best Practices

1. **Use TLS**
   ```nginx
   server {
       listen 443 ssl;
       server_name cache.company.com;
       
       ssl_certificate /path/to/cert.pem;
       ssl_certificate_key /path/to/key.pem;
       
       location / {
           proxy_pass http://localhost:8080;
       }
   }
   ```

2. **Rotate tokens**
   ```bash
   openssl rand -base64 32
   ```

3. **Firewall**
   ```bash
   iptables -A INPUT -p tcp --dport 8080 -s 10.0.0.0/8 -j ACCEPT
   iptables -A INPUT -p tcp --dport 8080 -j DROP
   ```

## Operations

### Troubleshooting

**Connection refused:**
```bash
curl http://cache:8080/
telnet cache 8080
```

**Unauthorized errors:**
```bash
echo $BUILDER_REMOTE_CACHE_TOKEN
```

**Low hit rate:**
```bash
bldr build --verbose
# Look for "cache miss" reasons
```

**Storage full:**
```bash
du -sh .cache-storage
# Increase max-size or enable LRU eviction
```

## Comparison

| Feature | bldr | Bazel | Buck2 | Gradle |
|---------|------|-------|-------|--------|
| Protocol | HTTP/1.1 | gRPC | gRPC | HTTP |
| Dependencies | None | Protobuf | Protobuf | None |
| Setup | 1 command | Complex | Complex | Medium |
| Compression | Zstd/LZ4 | Zstd | Zstd | Optional |
| Rate Limiting | Hierarchical | — | — | Basic |
| Metrics | Prometheus | Basic | Basic | ✓ |
| TLS Built-in | Optional | — | — | ✓ |
| CDN Integration | ✓ | — | — | Limited |

## See Also

- [Cache Design](../architecture/cachedesign.md)
- [Performance](./performance.md)
- [Security](../security/SECURITY.md)
