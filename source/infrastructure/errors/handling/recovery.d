module infrastructure.errors.handling.recovery;

import std.datetime;
import infrastructure.errors.types.types;
import infrastructure.errors.handling.codes;

/// Recovery strategy for handling errors
interface RecoveryStrategy
{
    /// Attempt to recover from an error
    /// Returns true if recovery was successful
    bool recover(BuildError error);
    
    /// Get human-readable description of this strategy
    string description() const;
}

/// Retry strategy with exponential backoff
class RetryStrategy : RecoveryStrategy
{
    private size_t maxAttempts;
    private Duration initialDelay;
    private float backoffMultiplier;
    private size_t[ErrorCode] attemptCounts;  // Track attempts per error code
    
    this(size_t maxAttempts = 3, Duration initialDelay = 1.seconds, float backoffMultiplier = 2.0)
    {
        this.maxAttempts = maxAttempts;
        this.initialDelay = initialDelay;
        this.backoffMultiplier = backoffMultiplier;
    }
    
    bool recover(BuildError error)
    {
        if (!error.recoverable())
            return false;
        
        // Get current attempt count for this error type
        auto errorCode = error.code();
        size_t currentAttempt = attemptCounts.get(errorCode, 0);
        
        // Check if we've exceeded max attempts
        if (currentAttempt >= maxAttempts)
        {
            // Reset counter for future errors
            attemptCounts.remove(errorCode);
            return false;
        }
        
        // Increment attempt counter
        attemptCounts[errorCode] = currentAttempt + 1;
        
        // Calculate delay with exponential backoff
        import std.math : pow;
        import core.thread : Thread;
        
        double multiplier = pow(backoffMultiplier, cast(double)currentAttempt);
        Duration delay = initialDelay * cast(long)multiplier;
        
        // Apply the delay
        Thread.sleep(delay);
        
        // Return true to indicate retry should be attempted
        return true;
    }
    
    /// Reset attempt counters (useful for testing or fresh starts)
    void reset()
    {
        attemptCounts.clear();
    }
    
    /// Get current attempt count for an error code
    size_t getAttemptCount(ErrorCode code) const
    {
        return attemptCounts.get(code, 0);
    }
    
    string description() const
    {
        import std.conv;
        return "Retry up to " ~ maxAttempts.to!string ~ " times with exponential backoff (initial delay: " ~ 
               initialDelay.to!string ~ ", multiplier: " ~ backoffMultiplier.to!string ~ ")";
    }
}

/// Fallback strategy - try alternative approach
class FallbackStrategy : RecoveryStrategy
{
    private bool delegate() fallbackAction;
    
    this(bool delegate() fallbackAction)
    {
        this.fallbackAction = fallbackAction;
    }
    
    bool recover(BuildError error)
    {
        try
        {
            return fallbackAction();
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    string description() const
    {
        return "Attempt fallback operation";
    }
}

/// Ignore strategy - log and continue
class IgnoreStrategy : RecoveryStrategy
{
    private bool delegate(BuildError) shouldIgnore;
    
    this(bool delegate(BuildError) shouldIgnore = null)
    {
        this.shouldIgnore = shouldIgnore;
    }
    
    bool recover(BuildError error)
    {
        if (shouldIgnore is null)
            return true;
        
        return shouldIgnore(error);
    }
    
    string description() const
    {
        return "Ignore error and continue";
    }
}

/// Recovery manager - applies strategies to errors
class RecoveryManager
{
    private RecoveryStrategy[ErrorCode] strategies;
    
    /// Register a strategy for specific error code
    void registerStrategy(ErrorCode code, RecoveryStrategy strategy)
    {
        strategies[code] = strategy;
    }
    
    /// Register a strategy for multiple error codes
    void registerStrategyForCodes(ErrorCode[] codes, RecoveryStrategy strategy)
    {
        foreach (code; codes)
            strategies[code] = strategy;
    }
    
    /// Attempt to recover from an error
    bool attemptRecovery(BuildError error)
    {
        auto strategy = strategies.get(error.code(), null);
        
        if (strategy is null)
            return false;
        
        return strategy.recover(error);
    }
    
    /// Get recovery strategy for an error
    RecoveryStrategy getStrategy(ErrorCode code)
    {
        return strategies.get(code, null);
    }
}

/// Default recovery manager with common strategies
RecoveryManager createDefaultRecoveryManager()
{
    auto manager = new RecoveryManager();
    
    // Retry transient errors
    auto retryStrategy = new RetryStrategy(3, 1.seconds, 2.0);
    manager.registerStrategyForCodes([
        ErrorCode.BuildTimeout,
        ErrorCode.ProcessTimeout,
        ErrorCode.CacheLoadFailed
    ], retryStrategy);
    
    return manager;
}

/// Execute function with automatic error recovery
auto withRecovery(T)(T delegate() fn, RecoveryManager manager = null)
{
    import infrastructure.errors.handling.result;
    
    if (manager is null)
        manager = createDefaultRecoveryManager();
    
    size_t attempts = 0;
    enum maxAttempts = 3;
    
    while (attempts < maxAttempts)
    {
        try
        {
            return BuildResult!T.ok(fn());
        }
        catch (Exception e)
        {
            // Convert exception to BuildError
            auto error = new InternalError(e.msg);
            
            if (attempts < maxAttempts - 1 && manager.attemptRecovery(error))
            {
                attempts++;
                continue;
            }
            
            return BuildResult!T.err(error);
        }
    }
    
    return BuildResult!T.err(new InternalError("Max recovery attempts exceeded"));
}

unittest
{
    import std.stdio : writeln;
    import core.time : msecs;
    
    writeln("Testing RetryStrategy...");
    
    // Create a retry strategy with short delays for testing
    auto strategy = new RetryStrategy(3, 10.msecs, 2.0);
    
    // Create a cache error (recoverable)
    auto cacheError = new CacheError("Cache temporarily unavailable", ErrorCode.CacheLoadFailed);
    
    // First retry should succeed
    assert(strategy.recover(cacheError));
    assert(strategy.getAttemptCount(ErrorCode.CacheLoadFailed) == 1);
    
    // Second retry should succeed
    assert(strategy.recover(cacheError));
    assert(strategy.getAttemptCount(ErrorCode.CacheLoadFailed) == 2);
    
    // Third retry should succeed
    assert(strategy.recover(cacheError));
    assert(strategy.getAttemptCount(ErrorCode.CacheLoadFailed) == 3);
    
    // Fourth retry should fail (max attempts reached)
    assert(!strategy.recover(cacheError));
    assert(strategy.getAttemptCount(ErrorCode.CacheLoadFailed) == 0);  // Counter reset
    
    // Test reset functionality
    strategy.reset();
    auto newError = new CacheError("Another cache error", ErrorCode.CacheLoadFailed);
    assert(strategy.recover(newError));
    assert(strategy.getAttemptCount(ErrorCode.CacheLoadFailed) == 1);
    
    // Test non-recoverable error
    auto parseError = new ParseError("test.txt", "Syntax error", ErrorCode.ParseFailed);
    assert(!strategy.recover(parseError));  // Parse errors are not recoverable
    
    writeln("RetryStrategy tests passed!");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("Testing RecoveryManager...");
    
    auto manager = createDefaultRecoveryManager();
    
    // Test that default strategies are registered
    assert(manager.getStrategy(ErrorCode.BuildTimeout) !is null);
    assert(manager.getStrategy(ErrorCode.CacheLoadFailed) !is null);
    
    // Test recovery attempt
    auto cacheError = new CacheError("Cache error", ErrorCode.CacheLoadFailed);
    bool recovered = manager.attemptRecovery(cacheError);
    assert(recovered);  // Should succeed first time
    
    writeln("RecoveryManager tests passed!");
}

