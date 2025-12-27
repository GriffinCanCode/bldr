module infrastructure.resilience.coordination.network;

import std.datetime;
import core.sync.mutex;
import infrastructure.resilience.core.breaker;
import infrastructure.resilience.core.limiter;
import infrastructure.resilience.policies.policy;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Network resilience coordinator - manages circuit breakers and rate limiters
/// for distributed network communication (distinct from build recovery)
/// 
/// Named "NetworkResilience" to avoid conflict with engine.runtime.services.resilience
/// which handles build recovery (retry/checkpoint/resume)
final class NetworkResilience
{
    private CircuitBreaker[string] breakers;
    private RateLimiter[string] limiters;
    private ResiliencePolicy[string] policies;
    private Mutex mutex;
    private ResiliencePolicy defaultPolicy;
    
    /// Statistics callback
    void delegate(string endpoint, BreakerState state, LimiterMetrics metrics) @safe onMetricsUpdate;
    
    this(ResiliencePolicy defaultPolicy = PolicyPresets.standard()) @trusted
    {
        this.defaultPolicy = defaultPolicy;
        this.mutex = new Mutex();
    }
    
    /// Register endpoint with custom policy
    void registerEndpoint(string endpoint, ResiliencePolicy policy) @trusted
    {
        synchronized (mutex)
        {
            policies[endpoint] = policy;
            
            if (policy.enableBreaker)
            {
                auto breaker = new CircuitBreaker(endpoint, policy.breakerConfig);
                
                // Hook up state change events
                breaker.onStateChange = (BreakerEvent event) @trusted {
                    handleBreakerStateChange(event);
                };
                
                breakers[endpoint] = breaker;
            }
            
            if (policy.enableLimiter)
            {
                auto limiter = new RateLimiter(endpoint, policy.limiterConfig);
                
                // Hook up rate limit events
                limiter.onRateLimitHit = (string ep, Priority p) @trusted {
                    handleRateLimitHit(ep, p);
                };
                
                limiters[endpoint] = limiter;
            }
        }
        
        structuredLog.info("registered_network_resilience_policies_f").field("detail", "Registered network resilience policies for: " ~ endpoint).emit();
    }
    
    /// Execute operation with full resilience (circuit breaker + rate limiter)
    BuildResult!T execute(T)(
        string endpoint,
        BuildResult!T delegate() @trusted operation,
        Priority priority = Priority.Normal,
        Duration timeout = 10.seconds
    ) @trusted
    {
        // Get or create policies for endpoint
        ensureEndpointRegistered(endpoint);
        
        CircuitBreaker breaker;
        RateLimiter limiter;
        
        synchronized (mutex)
        {
            breaker = breakers.get(endpoint, null);
            limiter = limiters.get(endpoint, null);
        }
        
        // Apply rate limiting first
        if (limiter !is null)
        {
            auto limitResult = limiter.acquire(priority, timeout);
            if (limitResult.isErr)
                return Err!(T, BuildError)(limitResult.unwrapErr());
        }
        
        // Apply circuit breaker
        if (breaker !is null)
        {
            return breaker.execute!T(operation);
        }
        
        // No breaker - execute directly
        return operation();
    }
    
    /// Execute with only circuit breaker (no rate limiting)
    BuildResult!T executeWithBreaker(T)(
        string endpoint,
        BuildResult!T delegate() @trusted operation
    ) @trusted
    {
        ensureEndpointRegistered(endpoint);
        
        CircuitBreaker breaker;
        synchronized (mutex)
        {
            breaker = breakers.get(endpoint, null);
        }
        
        if (breaker !is null)
            return breaker.execute!T(operation);
        
        return operation();
    }
    
    /// Execute with only rate limiter (no circuit breaker)
    BuildResult!T executeWithLimiter(T)(
        string endpoint,
        BuildResult!T delegate() @trusted operation,
        Priority priority = Priority.Normal,
        Duration timeout = 10.seconds
    ) @trusted
    {
        ensureEndpointRegistered(endpoint);
        
        RateLimiter limiter;
        synchronized (mutex)
        {
            limiter = limiters.get(endpoint, null);
        }
        
        if (limiter !is null)
            return limiter.execute!T(operation, priority, timeout);
        
        return operation();
    }
    
    /// Adjust rate for endpoint based on health
    void adjustRate(string endpoint, float healthScore) @trusted
    {
        RateLimiter limiter;
        synchronized (mutex)
        {
            limiter = limiters.get(endpoint, null);
        }
        
        if (limiter !is null)
        {
            limiter.adjustRate(healthScore);
            structuredLog.debug_("adjusted_rate_for_").field("detail", "Adjusted rate for " ~ endpoint ~ 
                " based on health: " ~ healthScore.to!string).emit();
        }
    }
    
    /// Get circuit breaker state for endpoint
    BreakerState getBreakerState(string endpoint) @trusted
    {
        synchronized (mutex)
        {
            if (auto breaker = endpoint in breakers)
                return (*breaker).getState();
        }
        return BreakerState.Closed;
    }
    
    /// Manually set breaker state (for admin/testing)
    void setBreakerState(string endpoint, BreakerState state) @trusted
    {
        synchronized (mutex)
        {
            if (auto breaker = endpoint in breakers)
                (*breaker).setState(state);
        }
    }
    
    /// Get rate limiter metrics for endpoint
    LimiterMetrics getLimiterMetrics(string endpoint) @trusted
    {
        synchronized (mutex)
        {
            if (auto limiter = endpoint in limiters)
                return (*limiter).getMetrics();
        }
        return LimiterMetrics.init;
    }
    
    /// Get circuit breaker statistics
    void getBreakerStatistics(
        string endpoint,
        out size_t totalRequests,
        out size_t failures,
        out float failureRate
    ) @trusted
    {
        synchronized (mutex)
        {
            if (auto breaker = endpoint in breakers)
            {
                (*breaker).getStatistics(totalRequests, failures, failureRate);
            }
        }
    }
    
    /// Get all endpoint statistics
    EndpointStats[] getAllStats() @trusted
    {
        EndpointStats[] stats;
        
        synchronized (mutex)
        {
            foreach (endpoint; breakers.byKey)
            {
                EndpointStats stat;
                stat.endpoint = endpoint;
                
                if (auto breaker = endpoint in breakers)
                {
                    stat.breakerState = (*breaker).getState();
                    (*breaker).getStatistics(
                        stat.totalRequests,
                        stat.failures,
                        stat.failureRate
                    );
                }
                
                if (auto limiter = endpoint in limiters)
                {
                    stat.limiterMetrics = (*limiter).getMetrics();
                }
                
                stats ~= stat;
            }
        }
        
        return stats;
    }
    
    /// Reset statistics for endpoint
    void resetStats(string endpoint) @trusted
    {
        synchronized (mutex)
        {
            if (auto limiter = endpoint in limiters)
                (*limiter).resetMetrics();
        }
    }
    
    /// Remove endpoint (cleanup)
    void unregisterEndpoint(string endpoint) @trusted
    {
        synchronized (mutex)
        {
            breakers.remove(endpoint);
            limiters.remove(endpoint);
            policies.remove(endpoint);
        }
        
        structuredLog.info("unregistered_endpoint_").field("detail", "Unregistered endpoint: " ~ endpoint).emit();
    }
    
    /// Ensure endpoint is registered with default policy
    private void ensureEndpointRegistered(string endpoint) @trusted
    {
        synchronized (mutex)
        {
            if (endpoint !in policies)
            {
                // Auto-register with default policy
                policies[endpoint] = defaultPolicy;
                
                if (defaultPolicy.enableBreaker)
                {
                    auto breaker = new CircuitBreaker(endpoint, defaultPolicy.breakerConfig);
                    breaker.onStateChange = (BreakerEvent event) @trusted {
                        handleBreakerStateChange(event);
                    };
                    breakers[endpoint] = breaker;
                }
                
                if (defaultPolicy.enableLimiter)
                {
                    auto limiter = new RateLimiter(endpoint, defaultPolicy.limiterConfig);
                    limiter.onRateLimitHit = (string ep, Priority p) @trusted {
                        handleRateLimitHit(ep, p);
                    };
                    limiters[endpoint] = limiter;
                }
            }
        }
    }
    
    /// Handle circuit breaker state changes
    private void handleBreakerStateChange(BreakerEvent event) @trusted
    {
        // When circuit opens, throttle rate limiter
        if (event.newState == BreakerState.Open)
        {
            adjustRate(event.endpoint, 0.2);  // Reduce to 20% of normal
        }
        // When circuit closes, restore rate
        else if (event.newState == BreakerState.Closed)
        {
            adjustRate(event.endpoint, 1.0);  // Restore to 100%
        }
        // Half-open: cautious rate
        else if (event.newState == BreakerState.HalfOpen)
        {
            adjustRate(event.endpoint, 0.5);  // 50% of normal
        }
        
        emitMetricsUpdate(event.endpoint);
    }
    
    /// Handle rate limit hits
    private void handleRateLimitHit(string endpoint, Priority priority) @trusted
    {
        // Could trigger additional actions like:
        // - Alert on sustained rate limiting
        // - Adjust circuit breaker sensitivity
        // - Log for capacity planning
        
        emitMetricsUpdate(endpoint);
    }
    
    /// Emit metrics update event
    private void emitMetricsUpdate(string endpoint) @trusted
    {
        if (onMetricsUpdate is null)
            return;
        
        try
        {
            BreakerState state;
            LimiterMetrics metrics;
            
            synchronized (mutex)
            {
                if (auto breaker = endpoint in breakers)
                    state = (*breaker).getState();
                
                if (auto limiter = endpoint in limiters)
                    metrics = (*limiter).getMetrics();
            }
            
            onMetricsUpdate(endpoint, state, metrics);
        }
        catch (Exception e)
        {
            structuredLog.error("error_in_metrics_callback_").field("detail", "Error in metrics callback: " ~ e.msg).emit();
        }
    }
}

/// Combined endpoint statistics
struct EndpointStats
{
    string endpoint;
    BreakerState breakerState;
    size_t totalRequests;
    size_t failures;
    float failureRate;
    LimiterMetrics limiterMetrics;
}

/// Convert float to string
private string to(T : string)(float value) @safe
{
    import std.format : format;
    return format("%.2f", value);
}

