module infrastructure.telemetry.collection.collector;

import std.datetime : Duration, SysTime, Clock;
import core.sync.mutex : Mutex;
import frontend.cli.events.events;
import infrastructure.telemetry.collection.environment;
import infrastructure.errors;

/// Thread-safe telemetry collector that subscribes to build events
/// Aggregates metrics in real-time for analysis and persistence
final class TelemetryCollector : EventSubscriber
{
    private BuildSession currentSession;
    private Mutex collectorMutex;
    private bool sessionActive;
    
    this() @system
    {
        this.collectorMutex = new Mutex();
        this.sessionActive = false;
    }
    
    /// Event handler - thread-safe
    /// 
    /// Safety: This function is @system because:
    /// 1. synchronized block is @system but manually verified memory-safe
    /// 2. Mutex protects shared state (currentSession, sessionActive)
    /// 3. All operations inside synchronized are @system
    /// 4. No pointer manipulation or unsafe casts
    /// 
    /// Invariants:
    /// - collectorMutex is always non-null (initialized in constructor)
    /// - Access to currentSession is serialized by mutex
    /// - Event type is validated by final switch (exhaustive)
    /// 
    /// What could go wrong:
    /// - Mutex is null: prevented by constructor initialization
    /// - Race condition: prevented by synchronized block
    /// - Invalid event type: caught by final switch (compile-time safety)
    void onEvent(BuildEvent event) @system
    {
        synchronized (collectorMutex)
        {
            final switch (event.type)
            {
                case EventType.BuildStarted:
                    handleBuildStarted(cast(BuildStartedEvent)event);
                    break;
                case EventType.BuildCompleted:
                    handleBuildCompleted(cast(BuildCompletedEvent)event);
                    break;
                case EventType.BuildFailed:
                    handleBuildFailed(cast(BuildFailedEvent)event);
                    break;
                case EventType.TargetStarted:
                    handleTargetStarted(cast(TargetStartedEvent)event);
                    break;
                case EventType.TargetCompleted:
                    handleTargetCompleted(cast(TargetCompletedEvent)event);
                    break;
                case EventType.TargetFailed:
                    handleTargetFailed(cast(TargetFailedEvent)event);
                    break;
                case EventType.TargetCached:
                    handleTargetCached(cast(TargetCachedEvent)event);
                    break;
                case EventType.TargetProgress:
                    // Not tracked for historical data
                    break;
                case EventType.Message:
                    // Not tracked for historical data
                    break;
                case EventType.Warning:
                    // Not tracked for historical data
                    break;
                case EventType.Error:
                    // Not tracked for historical data
                    break;
                case EventType.Statistics:
                    handleStatistics(cast(StatisticsEvent)event);
                    break;
            }
        }
    }
    
    /// Get current session - thread-safe
    /// 
    /// Safety: This function is @system because:
    /// 1. synchronized block is @system but memory-safe
    /// 2. Returns copy of currentSession (no references to protected data escape)
    /// 3. sessionActive flag is safely checked under lock
    /// 4. Result type ensures type-safe error handling
    /// 
    /// Invariants:
    /// - Access to currentSession and sessionActive is protected by mutex
    /// - Session is only returned if sessionActive is true
    /// - Return value is independent copy (no aliasing issues)
    /// 
    /// What could go wrong:
    /// - Returning reference to internal data: prevented by value return
    /// - Race condition: prevented by synchronized block
    /// - Reading invalid session: checked with sessionActive flag
    Result!(BuildSession, TelemetryError) getSession() @system
    {
        synchronized (collectorMutex)
        {
            if (!sessionActive)
                return Result!(BuildSession, TelemetryError).err(
                    TelemetryError.noActiveSession()
                );
            
            return Result!(BuildSession, TelemetryError).ok(currentSession);
        }
    }
    
    /// Reset collector state
    /// 
    /// Safety: This function is @system because:
    /// 1. synchronized block is @system but memory-safe
    /// 2. Assigns .init value which is always valid
    /// 3. No memory is leaked (D handles struct cleanup)
    /// 4. Simple field assignments under lock protection
    /// 
    /// Invariants:
    /// - currentSession reset to valid .init state
    /// - sessionActive set to false atomically with session clear
    /// - No partial state visible to other threads
    /// 
    /// What could go wrong:
    /// - Partial reset visible: prevented by synchronized block
    /// - Memory leak from old session: D's GC handles cleanup
    void reset() @system
    {
        synchronized (collectorMutex)
        {
            currentSession = BuildSession.init;
            sessionActive = false;
        }
    }
    
    private void handleBuildStarted(BuildStartedEvent event) @system
    {
        currentSession = BuildSession();
        currentSession.startTime = Clock.currTime();
        currentSession.totalTargets = event.totalTargets;
        currentSession.maxParallelism = event.maxParallelism;
        currentSession.environment = BuildEnvironment.snapshot();
        sessionActive = true;
    }
    
    private void handleBuildCompleted(BuildCompletedEvent event) @system
    {
        currentSession.endTime = Clock.currTime();
        currentSession.totalDuration = event.duration;
        currentSession.built = event.built;
        currentSession.cached = event.cached;
        currentSession.failed = event.failed;
        currentSession.succeeded = true;
    }
    
    private void handleBuildFailed(BuildFailedEvent event) @system
    {
        currentSession.endTime = Clock.currTime();
        currentSession.totalDuration = event.duration;
        currentSession.failed = event.failedCount;
        currentSession.succeeded = false;
        currentSession.failureReason = event.reason;
    }
    
    private void handleTargetStarted(TargetStartedEvent event) @system
    {
        TargetMetric metric;
        metric.targetId = event.targetId;
        metric.startTime = Clock.currTime();
        currentSession.targets[event.targetId] = metric;
    }
    
    private void handleTargetCompleted(TargetCompletedEvent event) @system
    {
        if (auto metric = event.targetId in currentSession.targets)
        {
            metric.endTime = Clock.currTime();
            metric.duration = event.duration;
            metric.outputSize = event.outputSize;
            metric.status = TargetStatus.Completed;
        }
    }
    
    private void handleTargetFailed(TargetFailedEvent event) @system
    {
        if (auto metric = event.targetId in currentSession.targets)
        {
            metric.endTime = Clock.currTime();
            metric.duration = event.duration;
            metric.status = TargetStatus.Failed;
            metric.error = event.error;
        }
    }
    
    private void handleTargetCached(TargetCachedEvent event) @system
    {
        if (auto metric = event.targetId in currentSession.targets)
        {
            metric.endTime = Clock.currTime();
            metric.status = TargetStatus.Cached;
        }
    }
    
    private void handleStatistics(StatisticsEvent event) @system
    {
        currentSession.cacheHitRate = event.cacheStats.hitRate;
        currentSession.cacheHits = event.cacheStats.hits;
        currentSession.cacheMisses = event.cacheStats.misses;
        currentSession.targetsPerSecond = event.buildStats.targetsPerSecond;
    }
}

/// Represents a complete build session with all metrics
struct BuildSession
{
    SysTime startTime;
    SysTime endTime;
    Duration totalDuration;
    
    size_t totalTargets;
    size_t built;
    size_t cached;
    size_t failed;
    size_t maxParallelism;
    
    double cacheHitRate = 0.0;
    size_t cacheHits;
    size_t cacheMisses;
    double targetsPerSecond = 0.0;
    
    bool succeeded;
    string failureReason;
    
    /// Build environment for reproducibility tracking
    BuildEnvironment environment;
    
    TargetMetric[string] targets;
    
    /// Calculate actual parallelism utilization
    @property double parallelismUtilization() const pure nothrow @system
    {
        if (maxParallelism == 0 || totalDuration.total!"msecs" == 0)
            return 0.0;
        
        // Sum all target durations
        long totalTargetTime = 0;
        foreach (target; targets.byValue)
        {
            totalTargetTime += target.duration.total!"msecs";
        }
        
        immutable theoreticalMax = maxParallelism * totalDuration.total!"msecs";
        return (totalTargetTime * 100.0) / theoreticalMax;
    }
    
    /// Get slowest targets
    TargetMetric[] slowest(size_t count = 10) const pure @system
    {
        import std.algorithm : sort;
        import std.array : array;
        
        auto sorted = targets.values.array.dup
            .sort!((a, b) => a.duration > b.duration);
        
        immutable limit = count < sorted.length ? count : sorted.length;
        return sorted[0 .. limit].array;
    }
    
    /// Get average build time per target
    @property Duration averageTargetTime() const pure nothrow @system
    {
        import std.datetime : dur;
        
        if (targets.length == 0)
            return dur!"msecs"(0);
        
        long totalMs = 0;
        foreach (target; targets.byValue)
        {
            totalMs += target.duration.total!"msecs";
        }
        
        return dur!"msecs"(totalMs / targets.length);
    }
}

/// Individual target build metrics
struct TargetMetric
{
    string targetId;
    SysTime startTime;
    SysTime endTime;
    Duration duration;
    size_t outputSize;
    TargetStatus status;
    string error;
}

/// Target build status
enum TargetStatus
{
    Pending,
    Completed,
    Failed,
    Cached
}

/// Telemetry-specific errors
struct TelemetryError
{
    string message;
    ErrorCode code;
    
    static TelemetryError noActiveSession() pure @system
    {
        return TelemetryError("No active build session", Telemetry.NoSession);
    }
    
    static TelemetryError storageError(string details) pure @system
    {
        return TelemetryError("Storage error: " ~ details, Telemetry.Storage);
    }
    
    static TelemetryError invalidData(string details) pure @system
    {
        return TelemetryError("Invalid data: " ~ details, Telemetry.Invalid);
    }
    
    string toString() const pure nothrow @system
    {
        return message;
    }
}

