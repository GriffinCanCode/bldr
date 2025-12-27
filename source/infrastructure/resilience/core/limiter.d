module infrastructure.resilience.core.limiter;

import std.datetime;
import std.algorithm : min;
import core.atomic;
import core.sync.mutex;
import core.sync.semaphore;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Rate limit configuration
struct LimiterConfig
{
    /// Maximum requests per second
    size_t ratePerSecond = 100;
    
    /// Burst capacity (max tokens)
    size_t burstCapacity = 200;
    
    /// Enable adaptive rate adjustment
    bool adaptive = true;
    
    /// Minimum rate when throttled (fraction of nominal)
    float minRate = 0.1;
    
    /// Maximum rate when healthy (fraction of nominal)
    float maxRate = 1.5;
    
    /// How quickly to adjust rate (0.0-1.0)
    float adjustmentSpeed = 0.05;
    
    /// Priority threshold (requests with priority >= this bypass some limits)
    ubyte priorityThreshold = 200;
}

/// Request priority
enum Priority : ubyte
{
    Low = 0,
    Normal = 100,
    High = 200,
    Critical = 255
}

/// Rate limiter metrics
struct LimiterMetrics
{
    size_t totalRequests;
    size_t accepted;
    size_t rejected;
    size_t highPriorityAccepted;
    Duration totalWaitTime;
    float currentRate;
    float avgWaitTimeMs;
    
    /// Get acceptance rate
    float acceptanceRate() const pure nothrow @nogc @safe
    {
        return totalRequests > 0 
            ? cast(float)accepted / cast(float)totalRequests 
            : 1.0f;
    }
    
    /// Get rejection rate  
    float rejectionRate() const pure nothrow @nogc @safe
    {
        return totalRequests > 0
            ? cast(float)rejected / cast(float)totalRequests
            : 0.0f;
    }
}

/// Token bucket rate limiter with adaptive control
final class RateLimiter
{
    private string endpoint;
    private LimiterConfig config;
    private Mutex mutex;
    
    // Token bucket state
    private float tokens;
    private MonoTime lastRefill;
    private float currentRate;  // Adaptive rate
    
    // Metrics
    private LimiterMetrics metrics;
    
    /// Event callback for rate limit hits
    void delegate(string endpoint, Priority priority) @safe onRateLimitHit;
    
    this(string endpoint, LimiterConfig config = LimiterConfig.init) @trusted
    {
        this.endpoint = endpoint;
        this.config = config;
        this.mutex = new Mutex();
        this.tokens = cast(float)config.burstCapacity;
        this.lastRefill = MonoTime.currTime();
        this.currentRate = cast(float)config.ratePerSecond;
    }
    
    /// Acquire permission to make request
    VoidBuildResult acquire(
        Priority priority = Priority.Normal,
        Duration timeout = Duration.zero
    ) @trusted
    {
        immutable startTime = MonoTime.currTime();
        
        synchronized (mutex)
        {
            metrics.totalRequests++;
            
            // High priority requests bypass queue when tokens available
            if (priority >= config.priorityThreshold && tokens >= 1.0)
            {
                tokens -= 1.0;
                metrics.accepted++;
                metrics.highPriorityAccepted++;
                return Ok!BuildError();
            }
            
            // Refill tokens based on elapsed time
            refillTokens();
            
            // Check if tokens available
            if (tokens >= 1.0)
            {
                tokens -= 1.0;
                metrics.accepted++;
                return Ok!BuildError();
            }
            
            // No tokens available
            if (timeout == Duration.zero)
            {
                metrics.rejected++;
                emitRateLimitHit(priority);
                
                return VoidBuildResult.err(
                    Errors.system("Rate limit exceeded for endpoint: " ~ endpoint, ErrorCode.NetworkError)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
        }
        
        // Wait for token with timeout
        return waitForToken(timeout, priority, startTime);
    }
    
    /// Try to acquire without blocking
    bool tryAcquire(Priority priority = Priority.Normal) @trusted
    {
        synchronized (mutex)
        {
            metrics.totalRequests++;
            refillTokens();
            
            if (tokens >= 1.0)
            {
                tokens -= 1.0;
                metrics.accepted++;
                if (priority >= config.priorityThreshold)
                    metrics.highPriorityAccepted++;
                return true;
            }
            
            metrics.rejected++;
            emitRateLimitHit(priority);
            return false;
        }
    }
    
    /// Execute operation with rate limiting
    BuildResult!T execute(T)(
        BuildResult!T delegate() @trusted operation,
        Priority priority = Priority.Normal,
        Duration timeout = 10.seconds
    ) @trusted
    {
        auto acquireResult = acquire(priority, timeout);
        if (acquireResult.isErr)
            return Err!(T, BuildError)(acquireResult.unwrapErr());
        
        return operation();
    }
    
    /// Adjust rate based on service health (adaptive control)
    void adjustRate(float healthScore) @trusted
    {
        if (!config.adaptive)
            return;
        
        synchronized (mutex)
        {
            // Health score: 1.0 = healthy, 0.0 = unhealthy
            // Target rate scales between minRate and maxRate
            immutable targetMultiplier = 
                config.minRate + (config.maxRate - config.minRate) * healthScore;
            immutable targetRate = config.ratePerSecond * targetMultiplier;
            
            // Exponential smoothing for gradual adjustment
            currentRate = currentRate * (1.0 - config.adjustmentSpeed) + 
                          targetRate * config.adjustmentSpeed;
            
            // Clamp to valid range
            immutable minAbsolute = config.ratePerSecond * config.minRate;
            immutable maxAbsolute = config.ratePerSecond * config.maxRate;
            
            if (currentRate < minAbsolute)
                currentRate = minAbsolute;
            else if (currentRate > maxAbsolute)
                currentRate = maxAbsolute;
            
            metrics.currentRate = currentRate;
        }
    }
    
    /// Get current metrics
    LimiterMetrics getMetrics() @trusted
    {
        synchronized (mutex)
        {
            metrics.currentRate = currentRate;
            
            if (metrics.accepted > 0)
            {
                metrics.avgWaitTimeMs = 
                    cast(float)metrics.totalWaitTime.total!"msecs" / 
                    cast(float)metrics.accepted;
            }
            
            return metrics;
        }
    }
    
    /// Reset metrics
    void resetMetrics() @trusted
    {
        synchronized (mutex)
        {
            metrics = LimiterMetrics.init;
            metrics.currentRate = currentRate;
        }
    }
    
    /// Get available tokens
    float availableTokens() @trusted
    {
        synchronized (mutex)
        {
            refillTokens();
            return tokens;
        }
    }
    
    /// Refill token bucket based on time elapsed
    private void refillTokens() @trusted
    {
        immutable now = MonoTime.currTime();
        immutable elapsed = now - lastRefill;
        immutable elapsedSeconds = elapsed.total!"hnsecs" / 10_000_000.0;
        
        // Calculate tokens to add
        immutable tokensToAdd = elapsedSeconds * currentRate;
        
        if (tokensToAdd > 0.0)
        {
            tokens = min(tokens + tokensToAdd, cast(float)config.burstCapacity);
            lastRefill = now;
        }
    }
    
    /// Wait for token availability with timeout
    private VoidBuildResult waitForToken(
        Duration timeout, 
        Priority priority,
        MonoTime startTime
    ) @trusted
    {
        immutable deadline = MonoTime.currTime() + timeout;
        
        while (MonoTime.currTime() < deadline)
        {
            // Calculate time until next token
            synchronized (mutex)
            {
                refillTokens();
                
                if (tokens >= 1.0)
                {
                    tokens -= 1.0;
                    metrics.accepted++;
                    if (priority >= config.priorityThreshold)
                        metrics.highPriorityAccepted++;
                    
                    immutable waitTime = MonoTime.currTime() - startTime;
                    metrics.totalWaitTime += waitTime;
                    return Ok!BuildError();
                }
            }
            
            // Sleep briefly before retry
            import core.thread : Thread;
            Thread.sleep(10.msecs);
        }
        
        synchronized (mutex)
        {
            metrics.rejected++;
        }
        
        emitRateLimitHit(priority);
        
        return VoidBuildResult.err(
            Errors.system("Rate limit timeout for endpoint: " ~ endpoint, ErrorCode.NetworkError)
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
    
    /// Emit rate limit hit event
    private void emitRateLimitHit(Priority priority) @trusted
    {
        structuredLog.debug_("rate_limit_hit_").field("detail", "Rate limit hit: " ~ endpoint ~ 
            " (priority: " ~ priority.to!string ~ ")").emit();
        
        if (onRateLimitHit !is null)
        {
            try
            {
                onRateLimitHit(endpoint, priority);
            }
            catch (Exception e)
            {
                structuredLog.error("error_in_rate_limiter_callback_").field("detail", "Error in rate limiter callback: " ~ e.msg).emit();
            }
        }
    }
}

/// Sliding window rate limiter (alternative implementation)
/// More accurate than token bucket but higher overhead
final class SlidingWindowLimiter
{
    private string endpoint;
    private size_t limit;
    private Duration window;
    private Mutex mutex;
    
    private struct Request
    {
        SysTime timestamp;
        Priority priority;
    }
    
    private Request[] requests;
    private LimiterMetrics metrics;
    
    this(string endpoint, size_t limit, Duration window) @trusted
    {
        this.endpoint = endpoint;
        this.limit = limit;
        this.window = window;
        this.mutex = new Mutex();
        this.requests.reserve(limit * 2);
    }
    
    /// Acquire permission
    VoidBuildResult acquire(Priority priority = Priority.Normal) @trusted
    {
        synchronized (mutex)
        {
            metrics.totalRequests++;
            
            // Remove expired requests
            immutable now = Clock.currTime();
            immutable cutoff = now - window;
            
            size_t writeIdx = 0;
            foreach (req; requests)
            {
                if (req.timestamp > cutoff)
                {
                    requests[writeIdx] = req;
                    writeIdx++;
                }
            }
            requests.length = writeIdx;
            
            // Check limit
            if (requests.length >= limit)
            {
                // High priority gets preference
                if (priority >= Priority.High)
                {
                    // Remove oldest low priority request if any
                    foreach (i, req; requests)
                    {
                        if (req.priority < Priority.High)
                        {
                            requests[i] = requests[$-1];
                            requests.length--;
                            break;
                        }
                    }
                }
                
                if (requests.length >= limit)
                {
                    metrics.rejected++;
                    return VoidBuildResult.err(
                        Errors.system("Rate limit exceeded (sliding window): " ~ endpoint, ErrorCode.NetworkError)
                            .withLocation(__FILE__, __LINE__)
                            .build()
                    );
                }
            }
            
            // Add new request
            requests ~= Request(now, priority);
            metrics.accepted++;
            
            if (priority >= Priority.High)
                metrics.highPriorityAccepted++;
            
            return Ok!BuildError();
        }
    }
    
    /// Get metrics
    LimiterMetrics getMetrics() @trusted
    {
        synchronized (mutex)
        {
            return metrics;
        }
    }
}

/// Convert priority to string
private string to(T : string)(Priority p) pure @safe nothrow
{
    final switch (p)
    {
        case Priority.Low: return "LOW";
        case Priority.Normal: return "NORMAL";
        case Priority.High: return "HIGH";
        case Priority.Critical: return "CRITICAL";
    }
}

