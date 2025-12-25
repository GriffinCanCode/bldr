module infrastructure.resilience.integrations.cache;

import std.datetime;
import engine.caching.distributed.remote.transport : HttpTransport;
import engine.caching.distributed.remote.protocol : RemoteCacheConfig;
import infrastructure.resilience;
import infrastructure.errors;

/// Resilient remote cache transport wrapper
/// Wraps HttpTransport with circuit breaker and rate limiting
/// 
/// NOTE: This provides CLIENT-SIDE resilience for cache clients.
/// The cache server itself has its own server-side rate limiter
/// at engine.caching.distributed.remote.limiter
final class ResilientCacheTransport
{
    private HttpTransport transport;
    private NetworkResilience resilience;
    private string endpoint;
    
    this(RemoteCacheConfig config, NetworkResilience resilience = null) @trusted
    {
        this.transport = new HttpTransport(config);
        this.endpoint = config.url;
        
        // Use provided resilience service or create new one
        if (resilience is null)
        {
            this.resilience = new NetworkResilience(PolicyPresets.network());
        }
        else
        {
            this.resilience = resilience;
        }
        
        // Register with network-optimized policy
        this.resilience.registerEndpoint(endpoint, PolicyPresets.network());
    }
    
    /// Execute GET request with resilience
    BuildResult!(ubyte[]) get(string contentHash) @trusted
    {
        return resilience.execute!(ubyte[])(
            endpoint,
            () => transport.get(contentHash),
            Priority.Normal,
            30.seconds
        );
    }
    
    /// Execute PUT request with resilience
    VoidBuildResult put(string contentHash, const(ubyte)[] data) @trusted
    {
        // PUT operations are lower priority to not block reads
        auto result = resilience.execute!bool(
            endpoint,
            () @trusted {
                auto putResult = transport.put(contentHash, data);
                if (putResult.isErr)
                    return BuildResult!bool.err(putResult.unwrapErr());
                return BuildResult!bool.ok(true);
            },
            Priority.Low,
            60.seconds
        );
        
        if (result.isErr)
            return VoidBuildResult.err(result.unwrapErr());
        return VoidBuildResult.ok();
    }
    
    /// Execute HEAD request with resilience  
    BuildResult!bool head(string contentHash) @trusted
    {
        // HEAD is lightweight - use high priority
        return resilience.execute!bool(
            endpoint,
            () => transport.head(contentHash),
            Priority.High,
            10.seconds
        );
    }
    
    /// Execute DELETE request with resilience
    VoidBuildResult remove(string contentHash) @trusted
    {
        auto result = resilience.execute!bool(
            endpoint,
            () @trusted {
                auto delResult = transport.remove(contentHash);
                if (delResult.isErr)
                    return BuildResult!bool.err(delResult.unwrapErr());
                return BuildResult!bool.ok(true);
            },
            Priority.Low,
            30.seconds
        );
        
        if (result.isErr)
            return VoidBuildResult.err(result.unwrapErr());
        return VoidBuildResult.ok();
    }
    
    /// Get circuit breaker state
    BreakerState getBreakerState() @trusted
    {
        return resilience.getBreakerState(endpoint);
    }
    
    /// Get rate limiter metrics
    LimiterMetrics getMetrics() @trusted
    {
        return resilience.getLimiterMetrics(endpoint);
    }
    
    /// Adjust rate based on cache server health
    void adjustRate(float healthScore) @trusted
    {
        resilience.adjustRate(endpoint, healthScore);
    }
    
    /// Get underlying transport (for migration)
    HttpTransport getTransport() @trusted
    {
        return transport;
    }
}

