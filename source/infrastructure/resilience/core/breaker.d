module infrastructure.resilience.core.breaker;

import std.datetime;
import std.algorithm : sum, map;
import std.array : array;
import core.atomic;
import core.sync.mutex;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Circuit breaker state
enum BreakerState : ubyte
{
    Closed = 0,    /// Normal operation
    Open = 1,      /// Failing - reject requests
    HalfOpen = 2   /// Testing recovery
}

/// Circuit breaker configuration
struct BreakerConfig
{
    /// Failure threshold (percentage) to open circuit
    float failureThreshold = 0.5;
    
    /// Minimum requests before considering failure rate
    size_t minRequests = 10;
    
    /// Rolling window size for tracking
    Duration windowSize = 30.seconds;
    
    /// Timeout before attempting recovery
    Duration timeout = 60.seconds;
    
    /// Max requests to test in HALF_OPEN state
    size_t halfOpenMaxRequests = 3;
    
    /// Success threshold to close from HALF_OPEN
    float successThreshold = 0.8;
    
    /// Consider only specific error codes as failures
    bool onlyCountNetworkErrors = true;
}

/// Request result for circuit breaker tracking
enum RequestResult : ubyte
{
    Success,
    Failure,
    Timeout
}

/// Circuit breaker event
struct BreakerEvent
{
    string endpoint;
    BreakerState previousState;
    BreakerState newState;
    SysTime timestamp;
    string reason;
}

/// Rolling window for tracking request outcomes
private struct RollingWindow
{
    private struct Bucket
    {
        SysTime timestamp;
        size_t successes;
        size_t failures;
        size_t timeouts;
    }
    
    private Bucket[] buckets;
    private size_t maxBuckets;
    private size_t currentIndex;
    private Mutex mutex;
    
    this(size_t maxBuckets) @trusted
    {
        this.maxBuckets = maxBuckets;
        this.buckets = new Bucket[maxBuckets];
        this.currentIndex = 0;
        this.mutex = new Mutex();
        
        // Initialize buckets
        immutable now = Clock.currTime();
        foreach (ref bucket; buckets)
            bucket.timestamp = now;
    }
    
    /// Record a request outcome
    void record(RequestResult result) @trusted
    {
        synchronized (mutex)
        {
            immutable now = Clock.currTime();
            auto bucket = &buckets[currentIndex];
            
            // Create new bucket if current is old
            if (now - bucket.timestamp > 1.seconds)
            {
                currentIndex = (currentIndex + 1) % maxBuckets;
                bucket = &buckets[currentIndex];
                *bucket = Bucket.init;
                bucket.timestamp = now;
            }
            
            final switch (result)
            {
                case RequestResult.Success:
                    bucket.successes++;
                    break;
                case RequestResult.Failure:
                    bucket.failures++;
                    break;
                case RequestResult.Timeout:
                    bucket.timeouts++;
                    break;
            }
        }
    }
    
    /// Get statistics for window
    void getStats(out size_t totalRequests, out size_t failures, Duration window) @trusted
    {
        synchronized (mutex)
        {
            immutable now = Clock.currTime();
            totalRequests = 0;
            failures = 0;
            
            foreach (ref bucket; buckets)
            {
                if (now - bucket.timestamp <= window)
                {
                    totalRequests += bucket.successes + bucket.failures + bucket.timeouts;
                    failures += bucket.failures + bucket.timeouts;
                }
            }
        }
    }
    
    /// Reset all data
    void reset() @trusted
    {
        synchronized (mutex)
        {
            foreach (ref bucket; buckets)
                bucket = Bucket.init;
            currentIndex = 0;
        }
    }
}

/// Circuit breaker implementation
final class CircuitBreaker
{
    private string endpoint;
    private BreakerConfig config;
    private shared BreakerState state;
    private RollingWindow window;
    private SysTime lastStateChange;
    private Mutex mutex;
    private size_t halfOpenSuccesses;
    private size_t halfOpenRequests;
    
    /// Event callback for state changes
    void delegate(BreakerEvent) @safe onStateChange;
    
    this(string endpoint, BreakerConfig config = BreakerConfig.init) @trusted
    {
        this.endpoint = endpoint;
        this.config = config;
        atomicStore(state, BreakerState.Closed);
        this.window = RollingWindow(cast(size_t)(config.windowSize.total!"seconds"));
        this.lastStateChange = Clock.currTime();
        this.mutex = new Mutex();
    }
    
    /// Execute operation with circuit breaker protection
    BuildResult!T execute(T)(
        BuildResult!T delegate() @trusted operation
    ) @trusted
    {
        // Check if circuit allows request
        auto allowResult = allowRequest();
        if (allowResult.isErr)
            return Err!(T, BuildError)(allowResult.unwrapErr());
        
        // Execute operation
        immutable startTime = MonoTime.currTime();
        auto result = operation();
        immutable duration = MonoTime.currTime() - startTime;
        
        // Record outcome
        recordResult(result, duration);
        
        return result;
    }
    
    /// Check if request is allowed
    private VoidBuildResult allowRequest() @trusted
    {
        immutable currentState = atomicLoad(state);
        
        final switch (currentState)
        {
            case BreakerState.Closed:
                return Ok!BuildError();
            
            case BreakerState.Open:
                // Check if timeout has elapsed
                synchronized (mutex)
                {
                    if (Clock.currTime() - lastStateChange >= config.timeout)
                    {
                        transitionTo(BreakerState.HalfOpen, "Timeout elapsed, testing recovery");
                        return Ok!BuildError();
                    }
                }
                
                return VoidBuildResult.err(
                    Errors.system("Circuit breaker open for endpoint: " ~ endpoint, Network.Error)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            
            case BreakerState.HalfOpen:
                synchronized (mutex)
                {
                    if (halfOpenRequests >= config.halfOpenMaxRequests)
                    {
                        return VoidBuildResult.err(
                            Errors.system("Circuit breaker half-open, max test requests reached: " ~ endpoint, Network.Error)
                                .withLocation(__FILE__, __LINE__)
                                .build()
                        );
                    }
                    halfOpenRequests++;
                }
                return Ok!BuildError();
        }
    }
    
    /// Record request result
    private void recordResult(T)(Result!(T, BuildError) result, Duration duration) @trusted
    {
        immutable currentState = atomicLoad(state);
        RequestResult outcome;
        
        if (result.isOk)
        {
            outcome = RequestResult.Success;
            window.record(outcome);
            
            if (currentState == BreakerState.HalfOpen)
            {
                synchronized (mutex)
                {
                    halfOpenSuccesses++;
                    checkHalfOpenTransition();
                }
            }
        }
        else
        {
            auto error = result.unwrapErr();
            
            // Determine if this error should count as failure
            immutable shouldCount = config.onlyCountNetworkErrors
                ? isNetworkError(error)
                : true;
            
            if (shouldCount)
            {
                outcome = duration > config.timeout 
                    ? RequestResult.Timeout 
                    : RequestResult.Failure;
                
                window.record(outcome);
                
                if (currentState == BreakerState.HalfOpen)
                {
                    // Any failure in HALF_OPEN reopens circuit
                    transitionTo(BreakerState.Open, "Failure during recovery test");
                }
                else if (currentState == BreakerState.Closed)
                {
                    checkFailureThreshold();
                }
            }
        }
    }
    
    /// Check if should open circuit due to failures
    private void checkFailureThreshold() @trusted
    {
        size_t totalRequests;
        size_t failures;
        window.getStats(totalRequests, failures, config.windowSize);
        
        if (totalRequests < config.minRequests)
            return;
        
        immutable failureRate = cast(float)failures / cast(float)totalRequests;
        
        if (failureRate >= config.failureThreshold)
        {
            import std.format : format;
            transitionTo(
                BreakerState.Open, 
                format("Failure rate %.2f exceeds threshold %.2f", 
                    failureRate, config.failureThreshold)
            );
        }
    }
    
    /// Check if should close from HALF_OPEN
    private void checkHalfOpenTransition() @trusted
    {
        if (halfOpenRequests < config.halfOpenMaxRequests)
            return;
        
        immutable successRate = cast(float)halfOpenSuccesses / cast(float)halfOpenRequests;
        
        if (successRate >= config.successThreshold)
        {
            transitionTo(BreakerState.Closed, "Recovery successful");
            window.reset();
        }
        else
        {
            transitionTo(BreakerState.Open, "Recovery failed");
        }
    }
    
    /// Transition to new state
    private void transitionTo(BreakerState newState, string reason) @trusted
    {
        synchronized (mutex)
        {
            immutable oldState = atomicLoad(state);
            if (oldState == newState)
                return;
            
            atomicStore(state, newState);
            lastStateChange = Clock.currTime();
            
            // Reset half-open counters
            if (newState == BreakerState.HalfOpen)
            {
                halfOpenSuccesses = 0;
                halfOpenRequests = 0;
            }
            
            // Emit event
            BreakerEvent event;
            event.endpoint = endpoint;
            event.previousState = oldState;
            event.newState = newState;
            event.timestamp = Clock.currTime();
            event.reason = reason;
            
            structuredLog.info("circuit_breaker_state_change_").field("detail", "Circuit breaker state change: " ~ endpoint ~ 
                " " ~ oldState.to!string ~ " → " ~ newState.to!string ~ 
                " (" ~ reason ~ ")").emit();
            
            if (onStateChange !is null)
            {
                try
                {
                    onStateChange(event);
                }
                catch (Exception e)
                {
                    structuredLog.error("error_in_circuit_breaker_callback_").field("detail", "Error in circuit breaker callback: " ~ e.msg).emit();
                }
            }
        }
    }
    
    /// Get current state
    BreakerState getState() const @trusted nothrow @nogc
    {
        return atomicLoad(state);
    }
    
    /// Force state change (for testing/manual intervention)
    void setState(BreakerState newState) @trusted
    {
        transitionTo(newState, "Manual state change");
    }
    
    /// Get current statistics
    void getStatistics(
        out size_t totalRequests, 
        out size_t failures,
        out float failureRate
    ) @trusted
    {
        window.getStats(totalRequests, failures, config.windowSize);
        failureRate = totalRequests > 0 
            ? cast(float)failures / cast(float)totalRequests 
            : 0.0f;
    }
    
    /// Check if error is network-related
    private static bool isNetworkError(BuildError error) pure @trusted nothrow
    {
        if (cast(NetworkError)error !is null)
            return true;
        
        immutable code = error.code();
        return code == cast(ErrorCode) Network.Error ||
               code == cast(ErrorCode) Distributed.CoordinatorTimeout ||
               code == cast(ErrorCode) Distributed.WorkerTimeout ||
               code == cast(ErrorCode) System.ProcessTimeout ||
               code == cast(ErrorCode) Distributed.ArtifactTransferFailed;
    }
}

/// Convert enum to string
private string to(T : string)(BreakerState state) pure @safe nothrow
{
    final switch (state)
    {
        case BreakerState.Closed: return "CLOSED";
        case BreakerState.Open: return "OPEN";
        case BreakerState.HalfOpen: return "HALF_OPEN";
    }
}

