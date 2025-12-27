module engine.distributed.worker.recover;

import std.datetime : Duration, MonoTime, Clock, SysTime, seconds, msecs;
import std.algorithm : min;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.protocol;
import engine.distributed.worker.peers;
import engine.runtime.recovery.retry;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Worker-side failure recovery
/// Integrates distributed failures with local retry orchestrator
/// Implements exponential backoff and peer blacklisting
final class WorkerRecovery
{
    private PeerRegistry peers;
    private RetryOrchestrator retryOrchestrator;
    private Mutex mutex;
    private WorkerId selfId;
    
    // Blacklist management
    private BlacklistEntry[WorkerId] blacklist;
    private immutable Duration maxBlacklistDuration = 300.seconds;
    
    // Connection pool health
    private ConnectionHealth[WorkerId] connections;
    
    // Statistics
    private shared size_t totalFailures;
    private shared size_t networkFailures;
    private shared size_t timeoutFailures;
    private shared size_t successfulRetries;
    private shared size_t failedRetries;
    
    this(PeerRegistry peers, WorkerId selfId) @trusted
    {
        this.peers = peers;
        this.selfId = selfId;
        this.retryOrchestrator = new RetryOrchestrator();
        this.mutex = new Mutex();
    }
    
    /// Execute action with retry logic (wraps retry orchestrator with distributed failure handling)
    BuildResult!ActionResult executeWithRetry(ActionRequest request, BuildResult!ActionResult delegate() @system execute) @system
    {
        auto result = retryOrchestrator.withRetry!ActionResult("action-" ~ request.id.toString(), execute, createPolicy(request.priority));
        if (result.isOk) atomicOp!"+="(successfulRetries, 1);
        else { atomicOp!"+="(failedRetries, 1); handleFailure(result.unwrapErr()); }
        return result;
    }
    
    /// Handle peer communication failure
    void handlePeerFailure(WorkerId peer, DistributedError error) @trusted
    {
        atomicOp!"+="(totalFailures, 1);
        if (cast(engine.distributed.protocol.protocol.NetworkError)error !is null)
        { atomicOp!"+="(networkFailures, 1); handleNetworkFailure(peer, error); }
        else { atomicOp!"+="(timeoutFailures, 1); handleTimeoutFailure(peer, error); }
    }
    
    /// Check if peer is blacklisted
    bool isBlacklisted(WorkerId peer) @trusted
    {
        synchronized (mutex)
        {
            if (auto entry = peer in blacklist)
            {
                if (entry.shouldRetry(Clock.currTime))
                {
                    blacklist.remove(peer);
                    slog.info("peer_blacklist_expired")
                        .field("peer_id", peer.value)
                        .field("failures", entry.failureCount)
                        .field("hint", "Peer is being given another chance after backoff period")
                        .emit();
                    return false;
                }
                return true;
            }
            return false;
        }
    }
    
    /// Get retry delay for peer
    Duration getRetryDelay(WorkerId peer) @trusted
    {
        synchronized (mutex)
        {
            if (auto entry = peer in blacklist)
                return entry.nextRetryTime - Clock.currTime;
            return Duration.zero;
        }
    }
    
    /// Get connection health for peer
    ConnectionHealth getConnectionHealth(WorkerId peer) @trusted
    {
        synchronized (mutex)
        {
            if (auto health = peer in connections)
                return *health;
            return ConnectionHealth.init;
        }
    }
    
    /// Get recovery statistics
    struct RecoveryStats
    {
        size_t totalFailures;
        size_t networkFailures;
        size_t timeoutFailures;
        size_t successfulRetries;
        size_t failedRetries;
        size_t blacklistedPeers;
        size_t unhealthyConnections;
        float retrySuccessRate;
    }
    
    RecoveryStats getStats() @trusted
    {
        RecoveryStats stats = {totalFailures: atomicLoad(totalFailures), networkFailures: atomicLoad(networkFailures),
            timeoutFailures: atomicLoad(timeoutFailures), successfulRetries: atomicLoad(successfulRetries), failedRetries: atomicLoad(failedRetries)};
        
        synchronized (mutex)
        {
            stats.blacklistedPeers = blacklist.length;
            foreach (health; connections.values) if (health.state != ConnectionState.Healthy) stats.unhealthyConnections++;
        }
        
        immutable total = stats.successfulRetries + stats.failedRetries;
        if (total > 0) stats.retrySuccessRate = cast(float)stats.successfulRetries / cast(float)total;
        return stats;
    }
    
    /// Reset statistics
    void resetStats() @trusted
    {
        atomicStore(totalFailures, cast(size_t)0);
        atomicStore(networkFailures, cast(size_t)0);
        atomicStore(timeoutFailures, cast(size_t)0);
        atomicStore(successfulRetries, cast(size_t)0);
        atomicStore(failedRetries, cast(size_t)0);
    }
    
    private:
    
    /// Create retry policy based on action priority
    RetryPolicy createPolicy(Priority priority) @safe
    {
        RetryPolicy policy;
        
        final switch (priority)
        {
            case Priority.Critical:
                policy.maxAttempts = 5;
                policy.initialDelay = 100.msecs;
                policy.maxDelay = 5.seconds;
                policy.backoffMultiplier = 1.5;
                break;
            
            case Priority.High:
                policy.maxAttempts = 4;
                policy.initialDelay = 200.msecs;
                policy.maxDelay = 10.seconds;
                policy.backoffMultiplier = 2.0;
                break;
            
            case Priority.Normal:
                policy.maxAttempts = 3;
                policy.initialDelay = 500.msecs;
                policy.maxDelay = 30.seconds;
                policy.backoffMultiplier = 2.0;
                break;
            
            case Priority.Low:
                policy.maxAttempts = 2;
                policy.initialDelay = 1.seconds;
                policy.maxDelay = 60.seconds;
                policy.backoffMultiplier = 2.0;
                break;
        }
        
        return policy;
    }
    
    /// Handle generic action failure
    void handleFailure(BuildError error) @trusted
    {
        immutable category = error.category();
        immutable recoverable = error.recoverable();
        
        slog.warning("action_execution_failed")
            .field("error", error.message())
            .field("category", category.to!string)
            .field("recoverable", recoverable)
            .field("hint", recoverable 
                ? "Action will be retried automatically with exponential backoff"
                : "Non-recoverable error - check worker logs and system resources")
            .emit();
        
        if (category == ErrorCategory.System && !recoverable)
        {
            slog.error("system_error_nonrecoverable")
                .field("error", error.message())
                .field("hint", "Check disk space, memory, and network connectivity. Consider restarting workers")
                .emit();
        }
    }
    
    /// Handle network failure with peer
    void handleNetworkFailure(WorkerId peer, DistributedError error) @trusted
    {
        synchronized (mutex)
        {
            // Mark peer as dead in registry
            peers.markDead(peer);
            
            // Add to blacklist with exponential backoff
            if (auto entry = peer in blacklist)
            {
                entry.failureCount++;
                entry.lastFailure = Clock.currTime;
                
                // Exponential backoff: 2^failures seconds, max maxBlacklistDuration
                immutable backoffSeconds = min(
                    1 << min(entry.failureCount, 8),
                    cast(long)maxBlacklistDuration.total!"seconds"
                );
                entry.nextRetryTime = Clock.currTime + seconds(backoffSeconds);
                
                slog.warning("peer_blacklist_extended")
                    .field("peer_id", peer.value)
                    .field("failures", entry.failureCount)
                    .field("next_retry_seconds", backoffSeconds)
                    .field("hint", "Peer failing repeatedly - check network connectivity and worker health")
                    .emit();
            }
            else
            {
                // First failure - add to blacklist
                blacklist[peer] = BlacklistEntry(
                    peer,
                    Clock.currTime,
                    Clock.currTime + 2.seconds,  // Initial 2 second backoff
                    1
                );
                
                slog.warning("peer_blacklisted")
                    .field("peer_id", peer.value)
                    .field("reason", error.message())
                    .field("initial_backoff_seconds", 2)
                    .field("hint", "First failure - peer will be retried after 2 seconds")
                    .emit();
            }
            
            // Update connection health
            updateConnectionHealth(peer, ConnectionState.Failed);
        }
    }
    
    /// Handle timeout failure with peer
    void handleTimeoutFailure(WorkerId peer, DistributedError error) @trusted
    {
        synchronized (mutex)
        {
            // Update connection health to degraded (not full failure)
            if (auto health = peer in connections)
            {
                health.timeouts++;
                
                if (health.timeouts >= 3)
                {
                    // Too many timeouts - treat as failed
                    handleNetworkFailure(peer, error);
                }
                else
                {
                    updateConnectionHealth(peer, ConnectionState.Degraded);
                    slog.warning("peer_connection_degraded")
                        .field("peer_id", peer.value)
                        .field("timeouts", health.timeouts)
                        .field("hint", health.timeouts >= 2 
                            ? "Multiple timeouts - peer may be overloaded or network is slow"
                            : "Occasional timeout - monitoring connection health")
                        .emit();
                }
            }
            else
            {
                // First timeout
                connections[peer] = ConnectionHealth(
                    peer,
                    ConnectionState.Degraded,
                    Clock.currTime,
                    1,
                    0
                );
            }
        }
    }
    
    /// Update connection health state
    void updateConnectionHealth(WorkerId peer, ConnectionState newState) @trusted
    {
        if (auto health = peer in connections)
        {
            health.state = newState;
            health.lastUpdate = Clock.currTime;
            
            if (newState == ConnectionState.Healthy)
            {
                // Reset counters on recovery
                health.timeouts = 0;
                health.failures = 0;
            }
            else if (newState == ConnectionState.Failed)
            {
                health.failures++;
            }
        }
        else
        {
            connections[peer] = ConnectionHealth(
                peer,
                newState,
                Clock.currTime,
                newState == ConnectionState.Degraded ? 1 : 0,
                newState == ConnectionState.Failed ? 1 : 0
            );
        }
    }
}

/// Blacklist entry for failed peers
struct BlacklistEntry
{
    WorkerId peer;
    SysTime lastFailure;
    SysTime nextRetryTime;
    size_t failureCount;
    
    /// Should we retry this peer now?
    bool shouldRetry(SysTime now) const pure @safe nothrow @nogc
    {
        return now >= nextRetryTime;
    }
}

/// Connection state
enum ConnectionState : ubyte
{
    Healthy,    // Normal operation
    Degraded,   // Slow or occasional timeouts
    Failed      // Connection lost
}

/// Connection health tracking
struct ConnectionHealth
{
    WorkerId peer;
    ConnectionState state;
    SysTime lastUpdate;
    size_t timeouts;
    size_t failures;
    
    /// Calculate health score [0.0, 1.0]
    float healthScore() const pure @safe nothrow @nogc
    {
        final switch (state)
        {
            case ConnectionState.Healthy:
                return 1.0f;
            case ConnectionState.Degraded:
                // Degrade based on timeout count
                return 0.5f / (1.0f + timeouts);
            case ConnectionState.Failed:
                return 0.0f;
        }
    }
}

/// Action retry coordinator
/// Coordinates retries across distributed workers
final class ActionRetryCoordinator
{
    private WorkerRecovery recovery;
    private PeerRegistry peers;
    private Mutex mutex;
    
    // Retry tracking
    private RetryInfo[ActionId] retries;
    
    this(WorkerRecovery recovery, PeerRegistry peers) @trusted
    {
        this.recovery = recovery;
        this.peers = peers;
        this.mutex = new Mutex();
    }
    
    /// Should retry action?
    bool shouldRetry(ActionId action) @trusted
    {
        synchronized (mutex)
        {
            if (auto info = action in retries)
            {
                return info.attempts < info.maxAttempts &&
                       Clock.currTime >= info.nextRetryTime;
            }
            return true;  // First attempt
        }
    }
    
    /// Record retry attempt
    void recordRetry(ActionId action, bool success) @trusted
    {
        synchronized (mutex)
        {
            if (auto info = action in retries)
            {
                info.attempts++;
                
                if (success)
                {
                    retries.remove(action);
                }
                else
                {
                    // Exponential backoff
                    immutable delay = info.baseDelay * (1 << info.attempts);
                    info.nextRetryTime = Clock.currTime + delay;
                }
            }
            else
            {
                // First attempt failed
                retries[action] = RetryInfo(
                    action,
                    1,
                    3,  // Default max attempts
                    Clock.currTime + 1.seconds,
                    1.seconds
                );
            }
        }
    }
    
    /// Get retry information
    RetryInfo getRetryInfo(ActionId action) @trusted
    {
        synchronized (mutex)
        {
            if (auto info = action in retries)
                return *info;
            return RetryInfo.init;
        }
    }
}

/// Retry information for an action
struct RetryInfo
{
    ActionId action;
    size_t attempts;
    size_t maxAttempts;
    SysTime nextRetryTime;
    Duration baseDelay;
}



