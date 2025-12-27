module engine.caching.distributed.remote.cdn;

import std.digest.sha : sha256Of;
import std.digest : toHexString;
import std.digest.hmac;
import std.conv : to;
import std.string : format;
import std.datetime : Clock, SysTime, Duration, hours;
import std.datetime.date : DateTime;
import std.base64 : Base64URL;
import std.uri : encode;
import std.json : JSONValue, JSONType;
import std.uuid : randomUUID;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging;

/// CDN configuration
struct CdnConfig
{
    bool enabled = false;
    string provider;        // "cloudfront", "cloudflare", "fastly", "custom"
    string domain;          // CDN domain
    string signingKey;      // Secret key for signed URLs
    string apiKey;          // API key for purge/invalidation requests
    string apiSecret;       // API secret for CloudFlare/Fastly
    string distributionId;  // CloudFront distribution ID or CloudFlare zone ID
    Duration defaultTtl = 24.hours;
    bool requireSignedUrls = false;
    string[] allowedOrigins;  // CORS origins
    
    /// Check if configuration is valid
    bool isValid() const pure @safe nothrow
    {
        if (!enabled)
            return true;
        
        return domain.length > 0;
    }
}

/// CDN integration manager
final class CdnManager
{
    private CdnConfig config;
    
    /// Constructor
    this(CdnConfig config) @safe
    {
        this.config = config;
    }
    
    /// Generate cache control headers
    string[string] getCacheHeaders(string contentHash, bool immutable_ = true) const @safe
    {
        string[string] headers;
        
        if (!config.enabled)
            return headers;
        
        if (immutable_)
        {
            // Content-addressable artifacts are immutable
            headers["Cache-Control"] = "public, max-age=31536000, immutable";
            headers["Expires"] = generateExpiry(365 * 24.hours);
        }
        else
        {
            // Mutable resources
            headers["Cache-Control"] = format("public, max-age=%d", config.defaultTtl.total!"seconds");
            headers["Expires"] = generateExpiry(config.defaultTtl);
        }
        
        // ETag for conditional requests
        headers["ETag"] = "\"" ~ contentHash ~ "\"";
        
        // Vary header for compression negotiation
        headers["Vary"] = "Accept-Encoding";
        
        return headers;
    }
    
    /// Generate signed URL for CloudFront
    BuildResult!string generateCloudFrontUrl(
        string path,
        Duration validity = 1.hours
    ) const @trusted
    {
        if (!config.enabled || config.provider != "cloudfront")
            return Err!(string, BuildError)(
                Errors.config("CloudFront not configured", ErrorCode.ConfigError).build());
        
        immutable expiry = Clock.currStdTime() / 10_000_000 + validity.total!"seconds";
        
        // CloudFront signed URL format:
        // URL?Expires=<expiry>&Signature=<signature>&Key-Pair-Id=<keypair>
        
        immutable baseUrl = "https://" ~ config.domain ~ path;
        immutable policy = format("CloudFront-Expires=%d", expiry);
        immutable signature = signUrl(policy);
        
        immutable signedUrl = format("%s?%s&Signature=%s&Key-Pair-Id=%s",
            baseUrl, policy, signature, "APKAIDPUN4QMG7VUQPSA");
        
        return Ok!(string, BuildError)(signedUrl);
    }
    
    /// Generate signed URL for Cloudflare
    BuildResult!string generateCloudflareUrl(
        string path,
        Duration validity = 1.hours
    ) const @trusted
    {
        if (!config.enabled || config.provider != "cloudflare")
            return Err!(string, BuildError)(
                Errors.config("Cloudflare not configured", ErrorCode.ConfigError).build());
        
        immutable expiry = Clock.currStdTime() / 10_000_000 + validity.total!"seconds";
        immutable baseUrl = "https://" ~ config.domain ~ path;
        
        // Cloudflare signed URL format
        immutable toSign = path ~ to!string(expiry);
        immutable signature = signUrl(toSign);
        
        immutable signedUrl = format("%s?verify=%s&exp=%d", 
            baseUrl, signature, expiry);
        
        return Ok!(string, BuildError)(signedUrl);
    }
    
    /// Get CORS headers
    string[string] getCorsHeaders(string origin) const pure @safe
    {
        string[string] headers;
        
        if (!config.enabled)
            return headers;
        
        // Check if origin is allowed
        bool allowed = false;
        foreach (allowedOrigin; config.allowedOrigins)
        {
            if (allowedOrigin == "*" || allowedOrigin == origin)
            {
                allowed = true;
                break;
            }
        }
        
        if (allowed)
        {
            headers["Access-Control-Allow-Origin"] = origin;
            headers["Access-Control-Allow-Methods"] = "GET, PUT, HEAD, DELETE";
            headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type";
            headers["Access-Control-Max-Age"] = "86400"; // 24 hours
            headers["Access-Control-Expose-Headers"] = "ETag, Content-Length";
        }
        
        return headers;
    }
    
    /// Verify signed URL
    BuildResult!bool verifySignedUrl(
        string path,
        string signature,
        long expiry
    ) const @trusted
    {
        // Check expiry
        immutable now = Clock.currStdTime() / 10_000_000;
        if (now > expiry)
            return Err!(bool, BuildError)(
                Errors.cache("Signed URL expired", ErrorCode.CacheUnauthorized).build());
        
        // Verify signature
        immutable expected = signUrl(path ~ to!string(expiry));
        if (signature != expected)
            return Err!(bool, BuildError)(
                Errors.cache("Invalid signature", ErrorCode.CacheUnauthorized).build());
        
        return Ok!(bool, BuildError)(true);
    }
    
    /// Generate CDN purge request (for cache invalidation)
    VoidBuildResult purgePath(string path) @trusted
    {
        if (!config.enabled)
            return Ok!BuildError();
        
        switch (config.provider)
        {
            case "cloudfront":
                return purgeCloudFront(path);
            case "cloudflare":
                return purgeCloudflare(path);
            case "fastly":
                return purgeFastly(path);
            default:
                return VoidBuildResult.err(
                    Errors.config("CDN provider '" ~ config.provider ~ "' not supported for purging", ErrorCode.NotSupported).build());
        }
    }
    
    /// Purge path from CloudFront
    private VoidBuildResult purgeCloudFront(string path) @trusted
    {
        import std.json : JSONValue, toJSON, parseJSON;
        import std.uuid : randomUUID;
        import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown, SocketOptionLevel, SocketOption;
        import std.datetime : Duration, seconds;
        import std.digest.sha : sha256Of;
        import std.digest.hmac : hmac, HMAC;
        import std.base64 : Base64;
        import std.datetime.timezone : UTC;
        
        if (config.distributionId.length == 0 || config.apiKey.length == 0)
            return VoidBuildResult.err(
                Errors.config("CloudFront distribution ID or API key not configured", ErrorCode.ConfigError).build());
        
        // Create invalidation request
        JSONValue invalidation;
        JSONValue paths;
        paths["Quantity"] = 1;
        paths["Items"] = [path];
        
        invalidation["Paths"] = paths;
        invalidation["CallerReference"] = randomUUID().toString();
        
        JSONValue request;
        request["InvalidationBatch"] = invalidation;
        
        immutable url = format("https://cloudfront.amazonaws.com/2020-05-31/distribution/%s/invalidation",
            config.distributionId);
        immutable requestBody = request.toJSON();
        
        // Execute HTTP POST with AWS Signature Version 4
        auto httpResult = executeAwsRequest("POST", url, requestBody, config.apiKey, config.apiSecret);
        
        if (httpResult.isErr)
        {
            structuredLog.error("cloudfront_purge_failed")
                .field("error", formatError(httpResult.unwrapErr()))
                .emit();
            return VoidBuildResult.err(httpResult.unwrapErr());
        }
        
        structuredLog.info("cloudfront_purge_success")
            .field("path", path)
            .emit();
        return Ok!BuildError();
    }
    
    /// Purge path from Cloudflare
    private VoidBuildResult purgeCloudflare(string path) @trusted
    {
        import std.json : JSONValue, toJSON, parseJSON;
        
        if (config.distributionId.length == 0 || config.apiKey.length == 0)
            return VoidBuildResult.err(
                Errors.config("Cloudflare zone ID or API key not configured", ErrorCode.ConfigError).build());
        
        // Create purge request
        JSONValue request;
        request["files"] = [format("https://%s%s", config.domain, path)];
        
        immutable url = format("https://api.cloudflare.com/client/v4/zones/%s/purge_cache",
            config.distributionId);
        
        // Execute HTTP POST with Bearer token
        string[string] headers = [
            "Authorization": "Bearer " ~ config.apiKey,
            "Content-Type": "application/json"
        ];
        
        auto httpResult = executeHttpRequest("POST", url, request.toJSON(), headers);
        
        if (httpResult.isErr)
        {
            structuredLog.error("cloudflare_purge_failed")
                .field("error", formatError(httpResult.unwrapErr()))
                .emit();
            return VoidBuildResult.err(httpResult.unwrapErr());
        }
        
        // Parse response to verify success
        try
        {
            auto response = parseJSON(cast(string)httpResult.unwrap());
            if ("success" in response && response["success"].type == JSONType.true_)
            {
                structuredLog.info("cloudflare_purge_success")
                    .field("path", path)
                    .emit();
                return Ok!BuildError();
            }
            else
            {
                auto errorMsg = "errors" in response ? response["errors"].toString() : "Unknown error";
                structuredLog.error("cloudflare_purge_error")
                    .field("error", errorMsg)
                    .emit();
                return VoidBuildResult.err(
                    Errors.generic("Cloudflare purge failed: " ~ errorMsg, ErrorCode.NetworkError).build());
            }
        }
        catch (Exception e)
        {
            return VoidBuildResult.err(
                Errors.generic("Failed to parse Cloudflare response: " ~ e.msg, ErrorCode.NetworkError).build());
        }
    }
    
    /// Purge path from Fastly
    private VoidBuildResult purgeFastly(string path) @trusted
    {
        if (config.apiKey.length == 0)
            return VoidBuildResult.err(
                Errors.config("Fastly API key not configured", ErrorCode.ConfigError).build());
        
        immutable url = format("https://api.fastly.com/purge/%s%s",
            config.domain, path);
        
        // Execute HTTP POST with Fastly-Key header
        string[string] headers = [
            "Fastly-Key": config.apiKey,
            "Accept": "application/json"
        ];
        
        auto httpResult = executeHttpRequest("POST", url, "", headers);
        
        if (httpResult.isErr)
        {
            structuredLog.error("fastly_purge_failed")
                .field("error", formatError(httpResult.unwrapErr()))
                .emit();
            return VoidBuildResult.err(httpResult.unwrapErr());
        }
        
        // Fastly returns 200 with {"status":"ok"} on success
        try
        {
            import std.json : parseJSON, JSONType;
            auto response = parseJSON(cast(string)httpResult.unwrap());
            if ("status" in response && response["status"].str == "ok")
            {
                structuredLog.info("fastly_purge_success")
                    .field("path", path)
                    .emit();
                return Ok!BuildError();
            }
            else
            {
                auto errorMsg = response.toString();
                structuredLog.error("fastly_purge_error")
                    .field("error", errorMsg)
                    .emit();
                return VoidBuildResult.err(
                    Errors.generic("Fastly purge failed: " ~ errorMsg, ErrorCode.NetworkError).build());
            }
        }
        catch (Exception e)
        {
            return VoidBuildResult.err(
                Errors.generic("Failed to parse Fastly response: " ~ e.msg, ErrorCode.NetworkError).build());
        }
    }
    
    private string signUrl(string data) const @trusted
    {
        import std.digest.hmac : hmac;
        import std.digest.sha : SHA256;
        
        if (config.signingKey.length == 0)
            return "";
        
        // HMAC-SHA256 signature
        auto h = hmac!SHA256(cast(ubyte[])config.signingKey);
        h.put(cast(ubyte[])data);
        auto hash = h.finish();
        return Base64URL.encode(hash);
    }
    
    private string generateExpiry(Duration duration) const @trusted
    {
        import std.datetime.systime : SysTime;
        import std.datetime.timezone : UTC;
        
        auto expiry = Clock.currTime(UTC()) + duration;
        
        // RFC 7231 HTTP date format (RFC 822/1123 format)
        return expiry.toISOExtString();
    }
    
    /// Execute generic HTTP request with headers
    private BuildResult!(ubyte[]) executeHttpRequest(
        string method,
        string url,
        string body_,
        string[string] headers
    ) @trusted
    {
        import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown, SocketOptionLevel, SocketOption;
        import std.datetime : seconds;
        import std.uri : decode;
        import std.string : indexOf, toLower;
        
        // Parse URL
        auto urlParts = parseHttpUrl(url);
        if (urlParts.host.length == 0)
            return Err!(ubyte[], BuildError)(
                Errors.config("Invalid URL: " ~ url, ErrorCode.ConfigError).build());
        
        try
        {
            // Create socket and connect
            auto addr = new InternetAddress(urlParts.host, urlParts.port);
            auto socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 30.seconds);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 30.seconds);
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            // Build HTTP request
            immutable requestStr = buildHttpRequestString(method, urlParts.path, urlParts.host, body_, headers);
            
            // Send request
            immutable sent = socket.send(requestStr);
            if (sent != requestStr.length)
            {
                return Err!(ubyte[], BuildError)(
                    Errors.network("Failed to send complete request", ErrorCode.NetworkError));
            }
            
            // Receive response
            ubyte[] responseData;
            ubyte[4096] buffer;
            while (true)
            {
                auto received = socket.receive(buffer);
                if (received <= 0)
                    break;
                responseData ~= buffer[0 .. received];
                
                // Check if we've received complete response (simple heuristic)
                if (responseData.length >= 4 && 
                    responseData[$ - 4 .. $] == ['\r', '\n', '\r', '\n'])
                    break;
            }
            
            // Parse HTTP response
            auto response = parseHttpResponse(responseData);
            
            if (response.statusCode >= 200 && response.statusCode < 300)
                return Ok!(ubyte[], BuildError)(cast(ubyte[])response.body_);
            else
            {
                return Err!(ubyte[], BuildError)(
                    Errors.network(format("HTTP error %d: %s", response.statusCode, response.body_), ErrorCode.NetworkError));
            }
        }
        catch (Exception e)
        {
            return Err!(ubyte[], BuildError)(
                Errors.network("HTTP request failed: " ~ e.msg, ErrorCode.NetworkError));
        }
    }
    
    /// Execute AWS request with Signature Version 4
    private BuildResult!(ubyte[]) executeAwsRequest(
        string method,
        string url,
        string body_,
        string accessKey,
        string secretKey
    ) @trusted
    {
        import std.digest.sha : sha256Of, SHA256;
        import std.digest.hmac : hmac;
        import std.datetime.timezone : UTC;
        import std.string : toLower;
        import std.array : replace;
        
        // AWS Signature Version 4 signing
        immutable timestamp = Clock.currTime(UTC()).toISOExtString()[0 .. 16].replace(":", "").replace("-", "");
        immutable date = timestamp[0 .. 8];
        
        string[string] headers = [
            "Content-Type": "application/json",
            "X-Amz-Date": timestamp,
            "Host": "cloudfront.amazonaws.com"
        ];
        
        // Compute canonical request
        immutable payloadHash = sha256Of(cast(ubyte[])body_).toHexString().toLower().idup;
        immutable canonicalRequest = format("%s\n%s\n\n%s\n\n%s\n%s",
            method,
            "/2020-05-31/distribution/" ~ config.distributionId ~ "/invalidation",
            "content-type:application/json\nhost:cloudfront.amazonaws.com\nx-amz-date:" ~ timestamp,
            "content-type;host;x-amz-date",
            payloadHash
        );
        
        // Compute string to sign
        immutable canonicalHash = sha256Of(cast(ubyte[])canonicalRequest).toHexString().toLower().idup;
        immutable stringToSign = format("AWS4-HMAC-SHA256\n%s\n%s/us-east-1/cloudfront/aws4_request\n%s",
            timestamp, date, canonicalHash);
        
        // Compute signature
        auto kDate = hmac!SHA256(cast(ubyte[])("AWS4" ~ secretKey), cast(ubyte[])date);
        auto kRegion = hmac!SHA256(kDate[], cast(ubyte[])"us-east-1");
        auto kService = hmac!SHA256(kRegion[], cast(ubyte[])"cloudfront");
        auto kSigning = hmac!SHA256(kService[], cast(ubyte[])"aws4_request");
        auto signature = hmac!SHA256(kSigning[], cast(ubyte[])stringToSign);
        
        // Add authorization header
        headers["Authorization"] = format(
            "AWS4-HMAC-SHA256 Credential=%s/%s/us-east-1/cloudfront/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=%s",
            accessKey, date, signature.toHexString().toLower()
        );
        
        return executeHttpRequest(method, url, body_, headers);
    }
    
    /// Parse HTTP URL into components
    private struct HttpUrlParts
    {
        string host;
        ushort port;
        string path;
    }
    
    private HttpUrlParts parseHttpUrl(string url) pure @safe
    {
        import std.string : indexOf, startsWith;
        
        HttpUrlParts parts;
        parts.port = 80;
        
        string remaining = url;
        
        // Strip protocol
        if (remaining.startsWith("https://"))
        {
            remaining = remaining[8 .. $];
            parts.port = 443;
        }
        else if (remaining.startsWith("http://"))
        {
            remaining = remaining[7 .. $];
        }
        
        // Extract host and path
        immutable slashPos = remaining.indexOf('/');
        if (slashPos >= 0)
        {
            parts.host = remaining[0 .. slashPos];
            parts.path = remaining[slashPos .. $];
        }
        else
        {
            parts.host = remaining;
            parts.path = "/";
        }
        
        // Extract port if specified
        immutable colonPos = parts.host.indexOf(':');
        if (colonPos >= 0)
        {
            parts.port = to!ushort(parts.host[colonPos + 1 .. $]);
            parts.host = parts.host[0 .. colonPos];
        }
        
        return parts;
    }
    
    /// Build HTTP request string
    private string buildHttpRequestString(
        string method,
        string path,
        string host,
        string body_,
        string[string] headers
    ) pure @safe
    {
        import std.array : Appender;
        
        Appender!string req;
        
        // Request line
        req ~= method;
        req ~= " ";
        req ~= path;
        req ~= " HTTP/1.1\r\n";
        
        // Host header
        req ~= "Host: ";
        req ~= host;
        req ~= "\r\n";
        
        // Custom headers
        foreach (name, value; headers)
        {
            req ~= name;
            req ~= ": ";
            req ~= value;
            req ~= "\r\n";
        }
        
        // Content-Length if body present
        if (body_.length > 0)
        {
            req ~= "Content-Length: ";
            req ~= body_.length.to!string;
            req ~= "\r\n";
        }
        
        // End headers
        req ~= "\r\n";
        
        // Body
        if (body_.length > 0)
            req ~= body_;
        
        return req.data;
    }
    
    /// Parse HTTP response
    private struct HttpResponse
    {
        int statusCode;
        string body_;
    }
    
    private HttpResponse parseHttpResponse(const ubyte[] data) pure @trusted
    {
        import std.string : indexOf, lineSplitter;
        import std.algorithm : splitter;
        import std.array : array;
        
        HttpResponse response;
        response.statusCode = 500;
        
        immutable dataStr = cast(string)data;
        
        // Find end of headers
        immutable headersEnd = dataStr.indexOf("\r\n\r\n");
        if (headersEnd < 0)
            return response;
        
        // Parse status line
        immutable firstLine = dataStr.lineSplitter().front;
        auto parts = firstLine.splitter(' ').array;
        if (parts.length >= 2)
        {
            try
            {
                response.statusCode = parts[1].to!int;
            }
            catch (Exception) {}
        }
        
        // Extract body
        if (headersEnd + 4 < dataStr.length)
            response.body_ = dataStr[headersEnd + 4 .. $];
        
        return response;
    }
}

/// CDN optimization utilities
struct CdnUtil
{
    /// Generate optimal cache key for CDN
    /// Includes compression encoding to avoid serving wrong variant
    static string generateCacheKey(
        string path,
        string acceptEncoding,
        string contentHash
    ) pure @safe
    {
        import std.string : indexOf;
        
        string encoding = "none";
        
        if (acceptEncoding.indexOf("zstd") >= 0)
            encoding = "zstd";
        else if (acceptEncoding.indexOf("br") >= 0)
            encoding = "br";
        else if (acceptEncoding.indexOf("gzip") >= 0)
            encoding = "gzip";
        
        return path ~ ":" ~ encoding ~ ":" ~ contentHash;
    }
    
    /// Parse cache key back to components
    static CacheKeyComponents parseCacheKey(string key) pure @safe
    {
        import std.string : split;
        
        auto parts = key.split(":");
        
        CacheKeyComponents result;
        if (parts.length >= 3)
        {
            result.path = parts[0];
            result.encoding = parts[1];
            result.contentHash = parts[2];
        }
        
        return result;
    }
    
    /// Check if request should bypass CDN (e.g., for mutations)
    static bool shouldBypassCache(string method, string path) pure @safe nothrow @nogc
    {
        // PUT, DELETE should bypass cache
        if (method == "PUT" || method == "DELETE" || method == "POST")
            return true;
        
        // Admin endpoints should bypass cache
        if (path.length >= 6 && path[0..6] == "/admin")
            return true;
        
        return false;
    }
}

/// Cache key components
struct CacheKeyComponents
{
    string path;
    string encoding;
    string contentHash;
}

/// Edge caching strategy
enum EdgeStrategy
{
    Aggressive,  // Cache everything, long TTL
    Conservative,  // Cache only immutable, short TTL
    Balanced,    // Default strategy
    Custom       // User-defined
}

/// Edge configuration for fine-grained control
struct EdgeConfig
{
    EdgeStrategy strategy = EdgeStrategy.Balanced;
    Duration ttl;
    bool enableStaleWhileRevalidate = true;
    Duration staleWhileRevalidateDuration = 1.hours;
    bool enableStaleIfError = true;
    Duration staleIfErrorDuration = 24.hours;
    
    /// Get Cache-Control header value
    string toCacheControl() const pure @safe
    {
        import std.array : Appender;
        
        Appender!string result;
        result ~= "public";
        
        if (ttl.total!"seconds" > 0)
        {
            result ~= ", max-age=";
            result ~= to!string(ttl.total!"seconds");
        }
        
        if (enableStaleWhileRevalidate)
        {
            result ~= ", stale-while-revalidate=";
            result ~= to!string(staleWhileRevalidateDuration.total!"seconds");
        }
        
        if (enableStaleIfError)
        {
            result ~= ", stale-if-error=";
            result ~= to!string(staleIfErrorDuration.total!"seconds");
        }
        
        final switch (strategy)
        {
            case EdgeStrategy.Aggressive:
                result ~= ", immutable";
                break;
            case EdgeStrategy.Conservative:
                result ~= ", must-revalidate";
                break;
            case EdgeStrategy.Balanced:
            case EdgeStrategy.Custom:
                break;
        }
        
        return result.data;
    }
}

