module infrastructure.resilience.integrations.protocol;

import std.datetime;
import engine.distributed.protocol.transport;
import engine.distributed.protocol.protocol;
import infrastructure.resilience;
import infrastructure.errors;
import infrastructure.resilience.core.limiter : RateLimiterPriority = Priority;

/// Resilient distributed protocol transport wrapper
/// Wraps protocol Transport with circuit breaker and rate limiting
final class ResilientProtocolTransport : Transport
{
    private Transport inner;
    private NetworkResilience resilience;
    private string endpoint;
    
    this(Transport inner, string endpoint, NetworkResilience resilience = null) @trusted
    {
        this.inner = inner;
        this.endpoint = endpoint;
        
        // Use provided resilience service or create new one
        if (resilience is null)
        {
            this.resilience = new NetworkResilience(PolicyPresets.highThroughput());
        }
        else
        {
            this.resilience = resilience;
        }
        
        // Register with high-throughput policy for worker communication
        this.resilience.registerEndpoint(endpoint, PolicyPresets.highThroughput());
    }
    
    /// Send HeartBeat with resilience
    Result!DistributedError sendHeartBeat(WorkerId recipient, HeartBeat message) @trusted
    {
        // Heartbeats are critical - high priority
        auto result = resilience.execute!bool(
            endpoint,
            () @trusted {
                auto sendResult = inner.sendHeartBeat(recipient, message);
                if (sendResult.isErr)
                    return BuildResult!bool.err(cast(BuildError)sendResult.unwrapErr());
                return BuildResult!bool.ok(true);
            },
            RateLimiterPriority.High,
            5.seconds
        );
        
        if (result.isErr)
        {
            // Convert BuildError back to DistributedError
            return Result!DistributedError.err(
                new DistributedError("HeartBeat failed: " ~ result.unwrapErr().message())
            );
        }
        
        return Result!DistributedError.ok();
    }
    
    /// Send StealRequest with resilience
    Result!DistributedError sendStealRequest(WorkerId recipient, StealRequest message) @trusted
    {
        // Work stealing is normal priority
        auto result = resilience.execute!bool(
            endpoint,
            () @trusted {
                auto sendResult = inner.sendStealRequest(recipient, message);
                if (sendResult.isErr)
                    return BuildResult!bool.err(cast(BuildError)sendResult.unwrapErr());
                return BuildResult!bool.ok(true);
            },
            RateLimiterPriority.Normal,
            10.seconds
        );
        
        if (result.isErr)
        {
            return Result!DistributedError.err(
                new DistributedError("StealRequest failed: " ~ result.unwrapErr().message())
            );
        }
        
        return Result!DistributedError.ok();
    }
    
    /// Send StealResponse with resilience
    Result!DistributedError sendStealResponse(WorkerId recipient, StealResponse message) @trusted
    {
        // Response to steal - high priority to unblock requester
        auto result = resilience.execute!bool(
            endpoint,
            () @trusted {
                auto sendResult = inner.sendStealResponse(recipient, message);
                if (sendResult.isErr)
                    return BuildResult!bool.err(cast(BuildError)sendResult.unwrapErr());
                return BuildResult!bool.ok(true);
            },
            RateLimiterPriority.High,
            5.seconds
        );
        
        if (result.isErr)
        {
            return Result!DistributedError.err(
                new DistributedError("StealResponse failed: " ~ result.unwrapErr().message())
            );
        }
        
        return Result!DistributedError.ok();
    }
    
    /// Receive StealResponse with resilience
    Result!(Envelope!StealResponse, DistributedError) receiveStealResponse(Duration timeout) @trusted
    {
        // Receive doesn't go through rate limiter (it's passive)
        // But still use circuit breaker
        auto result = resilience.executeWithBreaker!(Envelope!StealResponse)(
            endpoint,
            () @trusted {
                auto recvResult = inner.receiveStealResponse(timeout);
                if (recvResult.isErr)
                    return BuildResult!(Envelope!StealResponse).err(cast(BuildError)recvResult.unwrapErr());
                return BuildResult!(Envelope!StealResponse).ok(recvResult.unwrap());
            }
        );
        
        if (result.isErr)
        {
            return Result!(Envelope!StealResponse, DistributedError).err(
                new DistributedError("receiveStealResponse failed: " ~ result.unwrapErr().message())
            );
        }
        
        return Result!(Envelope!StealResponse, DistributedError).ok(result.unwrap());
    }
    
    /// Check if connected
    bool isConnected() @trusted
    {
        return inner.isConnected();
    }
    
    /// Close transport
    void close() @trusted
    {
        inner.close();
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
    
    /// Adjust rate based on connection health
    void adjustRate(float healthScore) @trusted
    {
        resilience.adjustRate(endpoint, healthScore);
    }
}

/// Factory for creating resilient transports
struct ResilientTransportFactory
{
    /// Create resilient transport from URL
    static Result!(Transport, DistributedError) create(
        string url,
        NetworkResilience resilience = null
    ) @system
    {
        // Create base transport
        auto transportResult = TransportFactory.create(url);
        if (transportResult.isErr)
            return transportResult;
        
        auto baseTransport = transportResult.unwrap();
        
        // Wrap with resilience
        auto resilientTransport = new ResilientProtocolTransport(
            baseTransport,
            url,
            resilience
        );
        
        return Ok!(Transport, DistributedError)(cast(Transport)resilientTransport);
    }
}

