module engine.caching.distributed.remote.server;

import std.socket;
import std.stdio : writeln, writefln;
import std.conv : to, text;
import std.string : split, strip, startsWith, indexOf, format, toLower;
import std.algorithm : canFind;
import std.datetime : Clock, SysTime, MonoTime, Duration;
import std.file : exists, read, write, remove, mkdirRecurse, dirEntries, SpanMode, DirEntry;
import std.path : buildPath, baseName;
import std.array : Appender;
import std.uri : decode;
import core.thread : Thread;
import core.sync.mutex;
import engine.caching.distributed.remote.protocol;
import engine.caching.distributed.remote.limiter;
import engine.caching.distributed.remote.compress;
import engine.caching.distributed.remote.metrics;
import engine.caching.distributed.remote.tls;
import engine.caching.distributed.remote.cdn;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.security.integrity : IntegrityValidator;
import infrastructure.errors;

/// Production-ready HTTP cache server
/// Features: compression, rate limiting, TLS, metrics, CDN integration
/// Content-addressable storage with LRU eviction
final class CacheServer
{
    private string storageDir;
    private string host;
    private ushort port;
    private string authToken;
    private size_t maxStorageSize;
    private Socket listener;
    private bool running;
    private Mutex storageMutex;
    private RemoteCacheStats stats;
    
    // Production features
    private HierarchicalLimiter rateLimiter;
    private ArtifactCompressor compressor;
    private MetricsExporter metricsExporter;
    private TlsContext tlsContext;
    private CdnManager cdnManager;
    private bool enableCompression;
    private bool enableRateLimiting;
    private bool enableMetrics;
    
    /// Constructor
    this(
        string host = "0.0.0.0",
        ushort port = 8080,
        string storageDir = ".cache-storage",
        string authToken = "",
        size_t maxStorageSize = 10_000_000_000,  // 10 GB default
        bool enableCompression = true,
        bool enableRateLimiting = true,
        bool enableMetrics = true,
        TlsConfig tlsConfig = TlsConfig.init,
        CdnConfig cdnConfig = CdnConfig.init
    ) @trusted
    {
        this.host = host;
        this.port = port;
        this.storageDir = storageDir;
        this.authToken = authToken;
        this.maxStorageSize = maxStorageSize;
        this.storageMutex = new Mutex();
        this.enableCompression = enableCompression;
        this.enableRateLimiting = enableRateLimiting;
        this.enableMetrics = enableMetrics;
        
        // Initialize production features
        if (enableRateLimiting)
            this.rateLimiter = new HierarchicalLimiter();
        
        if (enableCompression)
            this.compressor = new ArtifactCompressor(CompressionStrategy.Balanced);
        
        if (enableMetrics)
            this.metricsExporter = new MetricsExporter();
        
        this.tlsContext = new TlsContext(tlsConfig);
        this.cdnManager = new CdnManager(cdnConfig);
        
        // Ensure storage directory exists
        if (!exists(storageDir))
            mkdirRecurse(storageDir);
    }
    
    /// Start the cache server
    void start() @trusted
    {
        listener = new TcpSocket();
        listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
        listener.bind(new InternetAddress(host, port));
        listener.listen(128);
        
        running = true;
        
        writefln("Cache server listening on %s:%d", host, port);
        writefln("Storage directory: %s", storageDir);
        writefln("Max storage size: %.2f GB", maxStorageSize / 1_000_000_000.0);
        
        while (running)
        {
            try
            {
                auto client = listener.accept();
                
                // Handle in new thread for concurrency
                auto thread = new Thread(() => handleClient(client));
                thread.start();
            }
            catch (Exception e)
            {
                if (running)
                    writeln("Error accepting connection: ", e.msg);
            }
        }
    }
    
    /// Stop the cache server
    void stop() @trusted
    {
        running = false;
        if (listener !is null)
        {
            try
            {
                listener.shutdown(SocketShutdown.BOTH);
                listener.close();
            }
            catch (Exception) {}
        }
    }
    
    /// Get cache statistics
    RemoteCacheStats getStats() @trusted
    {
        synchronized (storageMutex)
        {
            return stats;
        }
    }
    
    private void cleanupClient(Socket client) nothrow
    {
        try { client.shutdown(SocketShutdown.BOTH); } catch (Exception) {}
        try { client.close(); } catch (Exception) {}
    }
    
    private void handleClient(Socket client) @trusted
    {
        import core.time : seconds;
        
        scope(exit)
        {
            // Clean up client connection
            cleanupClient(client);
        }
        
        immutable startTime = MonoTime.currTime;
        int statusCode = 500;
        string method = "UNKNOWN";
        
        scope(exit)
        {
            // Record metrics
            if (enableMetrics)
            {
                immutable latency = MonoTime.currTime - startTime;
                metricsExporter.recordRequest(method, statusCode, latency);
            }
        }
        
        try
        {
            // Read request with timeout
            client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 30.seconds);
            
            auto requestResult = receiveHttpRequest(client);
            if (requestResult.isErr)
            {
                statusCode = 400;
                sendErrorResponse(client, 400, "Bad Request");
                return;
            }
            
            auto request = requestResult.unwrap();
            method = request.method;
            
            // Extract client IP for rate limiting
            string clientIp = getClientIp(client, request.headers);
            string token = extractToken(request.headers);
            
            // Check rate limits
            if (enableRateLimiting && !rateLimiter.allow(clientIp, token))
            {
                statusCode = 429;
                immutable retryAfter = rateLimiter.retryAfter(clientIp, token);
                sendRateLimitResponse(client, retryAfter);
                return;
            }
            
            // Handle metrics endpoint
            if (enableMetrics && request.path == "/metrics")
            {
                handleMetrics(client);
                statusCode = 200;
                return;
            }
            
            // Check authentication
            if (authToken.length > 0 && !request.path.startsWith("/health"))
            {
                immutable authHeader = request.headers.get("Authorization", "");
                if (!authHeader.startsWith("Bearer " ~ authToken))
                {
                    statusCode = 401;
                    sendErrorResponse(client, 401, "Unauthorized");
                    return;
                }
            }
            
            // Route request
            if (request.method == "GET")
            {
                if (request.path == "/health")
                {
                    handleHealth(client);
                    statusCode = 200;
                }
                else
                {
                    statusCode = handleGet(client, request);
                }
            }
            else if (request.method == "PUT")
                statusCode = handlePut(client, request);
            else if (request.method == "HEAD")
                statusCode = handleHead(client, request);
            else if (request.method == "DELETE")
                statusCode = handleDelete(client, request);
            else if (request.method == "OPTIONS")
            {
                handleOptions(client, request);
                statusCode = 204;
            }
            else
            {
                statusCode = 405;
                sendErrorResponse(client, 405, "Method Not Allowed");
            }
        }
        catch (Exception e)
        {
            try
            {
                statusCode = 500;
                sendErrorResponse(client, 500, "Internal Server Error");
            }
            catch (Exception) {}
        }
    }
    
    private struct HttpRequest
    {
        string method;
        string path;
        string[string] headers;
        ubyte[] body_;
    }
    
    private BuildResult!HttpRequest receiveHttpRequest(Socket client) @trusted
    {
        HttpRequest request;
        ubyte[] buffer = new ubyte[8192];
        Appender!(ubyte[]) received;
        
        try
        {
            // Read headers
            bool headersComplete = false;
            ptrdiff_t headerEnd = -1;
            
            while (!headersComplete)
            {
                immutable bytesRead = client.receive(buffer);
                if (bytesRead <= 0)
                    break;
                
                received ~= buffer[0 .. bytesRead];
                
                // Check for header end
                foreach (i; 0 .. received.data.length - 3)
                {
                    if (received.data[i .. i + 4] == cast(ubyte[])"\r\n\r\n")
                    {
                        headersComplete = true;
                        headerEnd = i + 4;
                        break;
                    }
                }
                
                // Prevent header overflow
                if (received.data.length > 1_000_000)
                {
                    return Err!(HttpRequest, BuildError)(
                        Errors.network("Request headers too large", ErrorCode.NetworkError));
                }
            }
            
            if (headerEnd < 0)
            {
                return Err!(HttpRequest, BuildError)(
                    Errors.network("Invalid HTTP request", ErrorCode.NetworkError));
            }
            
            // Parse request line and headers
            immutable headerSection = cast(string)received.data[0 .. headerEnd];
            auto lines = headerSection.split("\r\n");
            
            if (lines.length == 0)
            {
                return Err!(HttpRequest, BuildError)(
                    Errors.network("Empty HTTP request", ErrorCode.NetworkError));
            }
            
            // Parse request line
            auto requestParts = lines[0].split(" ");
            if (requestParts.length < 3)
            {
                return Err!(HttpRequest, BuildError)(
                    Errors.network("Invalid request line", ErrorCode.NetworkError));
            }
            
            request.method = requestParts[0];
            request.path = requestParts[1];
            
            // Parse headers
            foreach (line; lines[1 .. $])
            {
                immutable colonIdx = line.indexOf(':');
                if (colonIdx > 0)
                {
                    immutable key = line[0 .. colonIdx].strip();
                    immutable value = line[colonIdx + 1 .. $].strip();
                    request.headers[key] = value;
                }
            }
            
            // Read body if present
            immutable contentLengthStr = request.headers.get("Content-Length", "0");
            size_t contentLength;
            try
            {
                contentLength = contentLengthStr.to!size_t;
            }
            catch (Exception)
            {
                contentLength = 0;
            }
            
            // Extract body from received data
            if (headerEnd < received.data.length)
                request.body_ ~= received.data[headerEnd .. $];
            
            // Read remaining body
            while (request.body_.length < contentLength)
            {
                immutable remaining = contentLength - request.body_.length;
                immutable toRead = remaining < buffer.length ? remaining : buffer.length;
                immutable bytesRead = client.receive(buffer[0 .. toRead]);
                
                if (bytesRead <= 0)
                    break;
                
                request.body_ ~= buffer[0 .. bytesRead];
            }
            
            return Ok!(HttpRequest, BuildError)(request);
        }
        catch (Exception e)
        {
            return Err!(HttpRequest, BuildError)(
                Errors.network("Failed to receive request: " ~ e.msg, ErrorCode.NetworkError));
        }
    }
    
    private int handleGet(Socket client, ref HttpRequest request) @trusted
    {
        // Parse path: /artifacts/{hash}
        if (!request.path.startsWith("/artifacts/"))
        {
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        immutable hash = decode(request.path[11 .. $]);
        immutable artifactPath = buildPath(storageDir, hash);
        
        synchronized (storageMutex)
        {
            stats.getRequests++;
        }
        
        if (!exists(artifactPath))
        {
            synchronized (storageMutex)
            {
                stats.misses++;
                stats.compute();
            }
            
            if (enableMetrics)
                metricsExporter.recordMiss();
            
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        try
        {
            auto data = cast(ubyte[])read(artifactPath);
            
            synchronized (storageMutex)
            {
                stats.hits++;
                stats.bytesDownloaded += data.length;
                stats.compute();
            }
            
            if (enableMetrics)
            {
                metricsExporter.recordHit();
                metricsExporter.recordBytes(0, data.length);
            }
            
            // Add CDN headers
            auto headers = cdnManager.getCacheHeaders(hash, true);
            
            // Add CORS headers if needed
            immutable origin = request.headers.get("Origin", "");
            if (origin.length > 0)
            {
                auto corsHeaders = cdnManager.getCorsHeaders(origin);
                foreach (key, value; corsHeaders)
                    headers[key] = value;
            }
            
            sendResponse(client, 200, "OK", data, headers);
            return 200;
        }
        catch (Exception e)
        {
            synchronized (storageMutex)
            {
                stats.errors++;
            }
            sendErrorResponse(client, 500, "Internal Server Error");
            return 500;
        }
    }
    
    private int handlePut(Socket client, ref HttpRequest request) @trusted
    {
        // Parse path: /artifacts/{hash}
        if (!request.path.startsWith("/artifacts/"))
        {
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        immutable hash = decode(request.path[11 .. $]);
        immutable artifactPath = buildPath(storageDir, hash);
        
        synchronized (storageMutex)
        {
            stats.putRequests++;
        }
        
        try
        {
            ubyte[] dataToStore = request.body_;
            
            // Compress artifact if enabled
            if (enableCompression)
            {
                auto compressResult = compressor.compress(request.body_);
                if (compressResult.isOk)
                {
                    auto compressed = compressResult.unwrap();
                    if (compressed.compressed)
                    {
                        // Only use compressed if beneficial
                        dataToStore = compressed.data;
                        writefln("Compressed artifact %s: %.1f%% reduction",
                                hash, (1.0 - compressed.ratio()) * 100.0);
                    }
                }
            }
            
            // Write artifact
            write(artifactPath, dataToStore);
            
            synchronized (storageMutex)
            {
                stats.bytesUploaded += request.body_.length;
            }
            
            if (enableMetrics)
                metricsExporter.recordBytes(request.body_.length, 0);
            
            // Check if eviction needed
            checkEviction();
            
            sendResponse(client, 201, "Created", null);
            return 201;
        }
        catch (Exception e)
        {
            synchronized (storageMutex)
            {
                stats.errors++;
            }
            sendErrorResponse(client, 500, "Internal Server Error");
            return 500;
        }
    }
    
    private int handleHead(Socket client, ref HttpRequest request) @trusted
    {
        // Parse path: /artifacts/{hash}
        if (!request.path.startsWith("/artifacts/"))
        {
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        immutable hash = decode(request.path[11 .. $]);
        immutable artifactPath = buildPath(storageDir, hash);
        
        synchronized (storageMutex)
        {
            stats.headRequests++;
        }
        
        if (exists(artifactPath))
        {
            synchronized (storageMutex)
            {
                stats.hits++;
                stats.compute();
            }
            
            if (enableMetrics)
                metricsExporter.recordHit();
            
            sendResponse(client, 200, "OK", null);
            return 200;
        }
        else
        {
            synchronized (storageMutex)
            {
                stats.misses++;
                stats.compute();
            }
            
            if (enableMetrics)
                metricsExporter.recordMiss();
            
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
    }
    
    private int handleDelete(Socket client, ref HttpRequest request) @trusted
    {
        // Parse path: /artifacts/{hash}
        if (!request.path.startsWith("/artifacts/"))
        {
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        immutable hash = decode(request.path[11 .. $]);
        immutable artifactPath = buildPath(storageDir, hash);
        
        if (!exists(artifactPath))
        {
            sendErrorResponse(client, 404, "Not Found");
            return 404;
        }
        
        try
        {
            remove(artifactPath);
            sendResponse(client, 204, "No Content", null);
            return 204;
        }
        catch (Exception e)
        {
            synchronized (storageMutex)
            {
                stats.errors++;
            }
            sendErrorResponse(client, 500, "Internal Server Error");
            return 500;
        }
    }
    
    /// Handle metrics endpoint
    private void handleMetrics(Socket client) @trusted
    {
        if (!enableMetrics)
        {
            sendErrorResponse(client, 404, "Not Found");
            return;
        }
        
        try
        {
            // Update storage metrics
            size_t totalSize = 0;
            foreach (entry; dirEntries(storageDir, SpanMode.shallow))
            {
                if (entry.isFile)
                    totalSize += entry.size;
            }
            
            metricsExporter.recordStorage(totalSize, maxStorageSize);
            
            // Export Prometheus metrics
            immutable metricsText = metricsExporter.exportPrometheus();
            
            string[string] headers;
            headers["Content-Type"] = "text/plain; version=0.0.4";
            
            sendResponse(client, 200, "OK", cast(ubyte[])metricsText, headers);
        }
        catch (Exception e)
        {
            sendErrorResponse(client, 500, "Internal Server Error");
        }
    }
    
    /// Handle health check endpoint
    private void handleHealth(Socket client) @trusted
    {
        import std.json;
        
        try
        {
            JSONValue health;
            health["status"] = "healthy";
            health["uptime"] = Clock.currStdTime() / 10_000_000;
            health["storage_used"] = getCurrentStorageSize();
            health["storage_total"] = maxStorageSize;
            
            synchronized (storageMutex)
            {
                health["cache_hits"] = stats.hits;
                health["cache_misses"] = stats.misses;
                health["hit_rate"] = stats.hitRate;
            }
            
            immutable json = health.toString();
            
            string[string] headers;
            headers["Content-Type"] = "application/json";
            
            sendResponse(client, 200, "OK", cast(ubyte[])json, headers);
        }
        catch (Exception e)
        {
            sendErrorResponse(client, 500, "Internal Server Error");
        }
    }
    
    /// Handle OPTIONS for CORS preflight
    private void handleOptions(Socket client, ref HttpRequest request) @trusted
    {
        immutable origin = request.headers.get("Origin", "");
        auto corsHeaders = cdnManager.getCorsHeaders(origin);
        
        sendResponse(client, 204, "No Content", null, corsHeaders);
    }
    
    /// Extract client IP from socket or X-Forwarded-For header
    private string getClientIp(Socket client, string[string] headers) @trusted
    {
        // Check X-Forwarded-For header first (for proxies)
        immutable forwarded = headers.get("X-Forwarded-For", "");
        if (forwarded.length > 0)
        {
            auto ips = forwarded.split(",");
            if (ips.length > 0)
                return ips[0].strip();
        }
        
        // Fall back to direct socket address
        try
        {
            auto remoteAddr = client.remoteAddress();
            if (auto inet = cast(InternetAddress)remoteAddr)
                return inet.toAddrString();
        }
        catch (Exception) {}
        
        return "unknown";
    }
    
    /// Extract authentication token from headers
    private string extractToken(string[string] headers) pure @safe
    {
        immutable authHeader = headers.get("Authorization", "");
        if (authHeader.startsWith("Bearer "))
            return authHeader[7 .. $];
        
        return "";
    }
    
    /// Get current storage size
    private size_t getCurrentStorageSize() @trusted
    {
        size_t total = 0;
        try
        {
            foreach (entry; dirEntries(storageDir, SpanMode.shallow))
            {
                if (entry.isFile)
                    total += entry.size;
            }
        }
        catch (Exception) {}
        
        return total;
    }
    
    private void sendResponse(
        Socket client,
        int statusCode,
        string statusText,
        const(ubyte)[] body_,
        string[string] additionalHeaders = null
    ) @trusted
    {
        Appender!(ubyte[]) response;
        
        // Status line
        response ~= cast(ubyte[])format("HTTP/1.1 %d %s\r\n", statusCode, statusText);
        
        // Standard headers
        response ~= cast(ubyte[])"Server: Builder-Cache/2.0\r\n";
        response ~= cast(ubyte[])"Connection: close\r\n";
        
        // Additional headers (CDN, CORS, etc.)
        foreach (key, value; additionalHeaders)
        {
            response ~= cast(ubyte[])(key ~ ": " ~ value ~ "\r\n");
        }
        
        if (body_ !is null && body_.length > 0)
        {
            response ~= cast(ubyte[])format("Content-Length: %d\r\n", body_.length);
            if ("Content-Type" !in additionalHeaders)
                response ~= cast(ubyte[])"Content-Type: application/octet-stream\r\n";
        }
        else
        {
            response ~= cast(ubyte[])"Content-Length: 0\r\n";
        }
        
        response ~= cast(ubyte[])"\r\n";
        
        // Body
        if (body_ !is null && body_.length > 0)
            response ~= body_;
        
        client.send(response.data);
    }
    
    private void sendRateLimitResponse(Socket client, Duration retryAfter) @trusted
    {
        string[string] headers;
        headers["Retry-After"] = to!string(retryAfter.total!"seconds");
        headers["X-RateLimit-Limit"] = "100";
        headers["X-RateLimit-Remaining"] = "0";
        headers["X-RateLimit-Reset"] = to!string(Clock.currStdTime() / 10_000_000 + retryAfter.total!"seconds");
        
        immutable body_ = cast(immutable(ubyte)[])("Rate limit exceeded. Please retry after " ~ 
                         to!string(retryAfter.total!"seconds") ~ " seconds.");
        
        sendResponse(client, 429, "Too Many Requests", body_, headers);
    }
    
    private void sendErrorResponse(Socket client, int statusCode, string statusText) @trusted
    {
        sendResponse(client, statusCode, statusText, null);
    }
    
    private void checkEviction() @trusted
    {
        synchronized (storageMutex)
        {
            try
            {
                // Calculate total storage size
                size_t totalSize = 0;
                DirEntry[] entries;
                
                foreach (entry; dirEntries(storageDir, SpanMode.shallow))
                {
                    if (entry.isFile)
                    {
                        totalSize += entry.size;
                        entries ~= entry;
                    }
                }
                
                // Evict if over limit (remove oldest 10%)
                if (totalSize > maxStorageSize)
                {
                    import std.algorithm : sort;
                    import std.array : array;
                    
                    // Sort by access time (oldest first)
                    entries.sort!((a, b) => a.timeLastModified < b.timeLastModified);
                    
                    immutable toEvict = entries.length / 10;
                    foreach (entry; entries[0 .. toEvict])
                    {
                        remove(entry.name);
                    }
                    
                    writefln("Evicted %d artifacts (total size: %.2f MB)", 
                             toEvict, totalSize / 1_000_000.0);
                }
            }
            catch (Exception e)
            {
                writeln("Warning: Eviction check failed: ", e.msg);
            }
        }
    }
}


