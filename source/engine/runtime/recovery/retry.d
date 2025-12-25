module engine.runtime.recovery.retry;

import std.datetime;
import std.algorithm;
import std.random;
import std.math : pow;
import core.atomic;
import infrastructure.errors;

/// Retry policy configuration
struct RetryPolicy
{
    size_t maxAttempts = 3;
    Duration initialDelay = 100.msecs;
    Duration maxDelay = 30.seconds;
    float backoffMultiplier = 2.0;
    float jitterFactor = 0.1;  // 10% random jitter
    bool exponential = true;
    
    /// Create policy for specific error category
    static RetryPolicy forCategory(ErrorCategory category) pure @system
    {
        with (ErrorCategory) final switch (category)
        {
            case System:
                return RetryPolicy(5, 200.msecs, 60.seconds, 2.0, 0.15, true);
            case Cache:
                return RetryPolicy(3, 100.msecs, 10.seconds, 1.5, 0.1, true);
            case IO:
                return RetryPolicy(3, 50.msecs, 5.seconds, 2.0, 0.05, true);
            case Plugin, LSP, Watch, Config:
                return RetryPolicy(2, 100.msecs, 5.seconds, 1.5, 0.1, true);
            case Build, Parse, Analysis, Graph, Language, Internal:
                return RetryPolicy(1, Duration.zero, Duration.zero, 1.0, 0.0, false);
        }
    }
    
    /// Calculate delay for given attempt with jitter
    Duration delayFor(size_t attempt) const @system
    {
        if (attempt == 0 || !exponential)
            return Duration.zero;
        
        // Exponential: delay = initial * (multiplier ^ (attempt - 1))
        immutable base = initialDelay.total!"msecs";
        immutable exponent = attempt - 1;
        immutable calculated = cast(long)(base * pow(backoffMultiplier, exponent));
        
        // Cap at max delay
        immutable capped = min(calculated, maxDelay.total!"msecs");
        
        // Add jitter: ±jitterFactor * delay
        if (jitterFactor > 0.0)
        {
            // Use deterministic pseudo-random jitter based on attempt number
            immutable seed = attempt * 2654435761UL;  // Golden ratio hash
            immutable normalizedRandom = cast(double)((seed ^ (seed >> 16)) & 0xFFFF) / 0xFFFF;
            immutable jitter = (normalizedRandom * 2.0 - 1.0) * jitterFactor;
            return max(cast(long)(capped * (1.0 + jitter)), 0).msecs;
        }
        
        return capped.msecs;
    }
    
    /// Check if should retry based on attempt count
    bool shouldRetry(size_t attempt) const pure nothrow @nogc @system
    {
        return attempt < maxAttempts;
    }
}

/// Retry statistics for observability
struct RetryStats
{
    size_t totalRetries;
    size_t successfulRetries;
    size_t failedRetries;
    size_t[ErrorCode] retriesByCode;
    Duration totalDelay;
    
    /// Record a retry attempt
    void recordAttempt(ErrorCode code, Duration delay, bool success) @system
    {
        totalRetries++;
        if (success)
            successfulRetries++;
        else
            failedRetries++;
        
        retriesByCode[code] = retriesByCode.get(code, 0) + 1;
        totalDelay += delay;
    }
    
    /// Get success rate
    float successRate() const pure nothrow @nogc @system
    {
        return totalRetries == 0 ? 0.0 : cast(float)successfulRetries / cast(float)totalRetries;
    }
}

/// Retry context - tracks state for single operation
struct RetryContext
{
    string operationId;      // Target ID
    size_t currentAttempt;   // Current attempt number (0-indexed)
    BuildError lastError;    // Last error encountered
    RetryPolicy policy;      // Policy for this operation
    SysTime startTime;       // When retry sequence started
    
    this(string operationId, RetryPolicy policy) @system
    {
        this.operationId = operationId;
        this.policy = policy;
        this.startTime = Clock.currTime();
        this.currentAttempt = 0;
    }
    
    /// Check if should retry
    bool shouldRetry() const pure nothrow @nogc @system
    {
        return policy.shouldRetry(currentAttempt);
    }
    
    /// Get next delay
    Duration nextDelay() const @system
    {
        return policy.delayFor(currentAttempt + 1);
    }
    
    /// Record attempt
    void recordAttempt(BuildError error) @system
    {
        currentAttempt++;
        lastError = error;
    }
    
    /// Get total elapsed time
    Duration elapsed() const @system
    {
        return Clock.currTime() - startTime;
    }
}

/// Retry orchestrator - coordinates retry logic
final class RetryOrchestrator
{
    private RetryStats stats;
    private shared bool enabled;
    private RetryPolicy defaultPolicy;
    private RetryPolicy[ErrorCode] customPolicies;
    
    this(RetryPolicy defaultPolicy = RetryPolicy.init) @system
    {
        this.defaultPolicy = defaultPolicy;
        atomicStore(enabled, true);
        
        // Register transient error codes
        registerTransientErrors();
    }
    
    /// Enable/disable retry system
    void setEnabled(bool value) nothrow @system @nogc
    {
        atomicStore(enabled, value);
    }
    
    /// Check if enabled
    bool isEnabled() const nothrow @system @nogc
    {
        return atomicLoad(enabled);
    }
    
    /// Register custom policy for specific error code
    void registerPolicy(ErrorCode code, RetryPolicy policy) @system
    {
        customPolicies[code] = policy;
    }
    
    /// Get policy for error
    RetryPolicy policyFor(BuildError error) const @system
    {
        // Check custom policy
        if (auto policy = error.code() in customPolicies)
            return *policy;
        
        // Use category-based policy
        return RetryPolicy.forCategory(error.category());
    }
    
    /// Execute operation with retry
    Result!(T, BuildError) withRetry(T)(
        string operationId,
        Result!(T, BuildError) delegate() operation,
        RetryPolicy policy = RetryPolicy.init
    ) @system
    {
        if (!isEnabled() || policy.maxAttempts <= 1)
            return operation();
        
        auto ctx = RetryContext(operationId, policy);
        
        while (true)
        {
            auto result = operation();
            
            if (result.isOk)
            {
                // Success - record if retried
                if (ctx.currentAttempt > 0)
                {
                    stats.recordAttempt(
                        ctx.lastError ? ctx.lastError.code() : ErrorCode.InternalError,
                        ctx.elapsed(),
                        true
                    );
                }
                return result;
            }
            
            auto error = result.unwrapErr();
            ctx.recordAttempt(error);
            
            // Check if recoverable
            if (!error.recoverable())
            {
                // Not recoverable - fail immediately
                return result;
            }
            
            // Check retry limit
            if (!ctx.shouldRetry())
            {
                // Max attempts exceeded
                stats.recordAttempt(error.code(), ctx.elapsed(), false);
                return result;
            }
            
            // Wait before retry
            immutable delay = ctx.nextDelay();
            if (delay > Duration.zero)
            {
                import core.thread : Thread;
                Thread.sleep(delay);
            }
        }
    }
    
    /// Get current statistics
    RetryStats getStats() const @system
    {
        return cast(RetryStats)stats;
    }
    
    /// Reset statistics
    void resetStats() @system
    {
        stats = RetryStats.init;
    }
    
    private void registerTransientErrors() @system
    {
        with (ErrorCode)
        {
            registerPolicy(ProcessTimeout, RetryPolicy(3, 200.msecs, 10.seconds, 2.0, 0.1, true));
            registerPolicy(BuildTimeout, RetryPolicy(2, 1.seconds, 30.seconds, 2.0, 0.15, true));
            registerPolicy(CacheLoadFailed, RetryPolicy(3, 100.msecs, 5.seconds, 1.5, 0.1, true));
            registerPolicy(CacheEvictionFailed, RetryPolicy(2, 50.msecs, 2.seconds, 1.5, 0.05, true));
            registerPolicy(FileReadFailed, RetryPolicy(3, 50.msecs, 2.seconds, 2.0, 0.1, true));
            registerPolicy(FileWriteFailed, RetryPolicy(3, 50.msecs, 2.seconds, 2.0, 0.1, true));
        }
    }
}

/// NOTE: Global retry function removed.
/// Use ResilienceService through dependency injection:
///
/// ```d
/// // Get ResilienceService from ExecutionEngine
/// auto result = resilience.withRetry("myOp", () => doWork(), policy);
/// ```

