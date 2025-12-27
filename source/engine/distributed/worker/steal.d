module engine.distributed.worker.steal;

import std.datetime : Duration, MonoTime, msecs, seconds;
import std.algorithm : min, max;
import std.random : uniform;
import core.atomic;
import core.thread : Thread;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.protocol : NetworkError, DistributedError;
import engine.distributed.protocol.transport;
import engine.distributed.worker.peers;
import engine.distributed.worker.adaptive;
import infrastructure.errors : BuildError, Result, Ok, Err;
import infrastructure.utils.logging;

/// Work-stealing strategy
enum StealStrategy
{
    Random,         // Random victim selection
    LeastLoaded,    // Target least loaded peer
    MostLoaded,     // Target most loaded peer
    PowerOfTwo,     // Power-of-two-choices (default)
    Adaptive        // Dynamically adjust based on success rate
}

/// Work-stealing configuration
struct StealConfig
{
    StealStrategy strategy = StealStrategy.PowerOfTwo;
    Duration stealTimeout = 100.msecs;      // Timeout for steal attempt
    Duration retryBackoff = 50.msecs;       // Backoff between retries
    size_t maxRetries = 3;                  // Max steal attempts
    size_t minLocalQueue = 2;               // Min local work before stealing
    float stealThreshold = 0.5;             // Load threshold to trigger steal
    bool enableAdaptive = false;            // Enable adaptive threshold tuning
    AdaptiveConfig adaptiveConfig;          // Adaptive tuning configuration
}

/// Work-stealing metrics
struct StealMetrics
{
    shared size_t attempts;         // Total steal attempts
    shared size_t successes;        // Successful steals
    shared size_t failures;         // Failed steals
    shared size_t timeouts;         // Timed out steals
    shared size_t networkErrors;    // Network errors
    
    /// Calculate success rate
    float successRate() const @trusted nothrow @nogc
    {
        immutable total = atomicLoad(attempts);
        if (total == 0)
            return 0.0;
        
        immutable success = atomicLoad(successes);
        return cast(float)success / cast(float)total;
    }
}

/// Work-stealing engine
/// Implements distributed work-stealing protocol between peers
final class StealEngine
{
    private PeerRegistry peers;
    private StealConfig config;
    private StealMetrics metrics;
    private WorkerId selfId;
    private AdaptiveThresholds adaptive;
    
    this(WorkerId selfId, PeerRegistry peers, StealConfig config = StealConfig.init) @safe
    {
        this.selfId = selfId;
        this.peers = peers;
        this.config = config;
        
        if (config.enableAdaptive)
        {
            ThresholdState initial = {
                minLocalQueue: config.minLocalQueue,
                stealThreshold: config.stealThreshold,
                stealTimeout: config.stealTimeout,
                retryBackoff: config.retryBackoff
            };
            this.adaptive = new AdaptiveThresholds(config.adaptiveConfig, initial);
        }
    }
    
    /// Attempt to steal work from a peer (returns ActionRequest if successful, null otherwise)
    ActionRequest steal(Transport transport) @trusted
    {
        atomicOp!"+="(metrics.attempts, 1);
        auto victimResult = selectVictim();
        if (victimResult.isErr) { atomicOp!"+="(metrics.failures, 1); recordAdaptive(false, 0, false, false); return null; }
        
        auto victimId = victimResult.unwrap();
        immutable effectiveRetries = config.maxRetries;
        immutable effectiveBackoff = getEffectiveBackoff();
        immutable effectiveTimeout = getEffectiveTimeout();
        
        foreach (attempt; 0 .. effectiveRetries)
        {
            immutable startTime = MonoTime.currTime;
            auto result = tryStealWithTimeout(victimId, transport, effectiveTimeout);
            immutable latencyUs = (MonoTime.currTime - startTime).total!"usecs";
            
            if (result.isOk)
            {
                if (auto action = result.unwrap())
                {
                    atomicOp!"+="(metrics.successes, 1);
                    recordAdaptive(true, latencyUs, false, false);
                    structuredLog.debug_("stole_work_from_").field("detail", "Stole work from " ~ victimId.toString()).emit();
                    return action;
                }
            }
            else
            {
                auto err = result.unwrapErr();
                immutable isNetworkErr = cast(NetworkError)err !is null;
                immutable isTimeout = err.msg.length > 0 && err.msg[0..min(7, err.msg.length)] == "Steal t";
                
                if (isNetworkErr) { atomicOp!"+="(metrics.networkErrors, 1); recordAdaptive(false, latencyUs, true, false); peers.markDead(victimId); break; }
                if (isTimeout) { atomicOp!"+="(metrics.timeouts, 1); recordAdaptive(false, latencyUs, false, true); }
            }
            
            if (attempt < effectiveRetries - 1) Thread.sleep(effectiveBackoff * (1 << attempt));
        }
        atomicOp!"+="(metrics.failures, 1);
        recordAdaptive(false, 0, false, false);
        return null;
    }
    
    /// Handle steal request from another worker (returns StealResponse with action if available)
    StealResponse handleStealRequest(StealRequest req, ActionRequest delegate() @system tryStealLocal) @system
    {
        structuredLog.debug_("processing_steal_request_from_").field("detail", "Processing steal request from " ~ req.thief.toString()).emit();
        auto action = tryStealLocal();
        structuredLog.debug_("log_event").field("message", action !is null ? "Giving work to " ~ req.thief.toString() : "No work to give to " ~ req.thief.toString()).emit();
        return StealResponse(selfId, req.thief, action !is null, action);
    }
    
    /// Get metrics
    StealMetrics getMetrics() @trusted const nothrow @nogc
    {
        return metrics;
    }
    
    /// Reset metrics
    void resetMetrics() @trusted nothrow @nogc
    {
        atomicStore(metrics.attempts, cast(size_t)0);
        atomicStore(metrics.successes, cast(size_t)0);
        atomicStore(metrics.failures, cast(size_t)0);
        atomicStore(metrics.timeouts, cast(size_t)0);
        atomicStore(metrics.networkErrors, cast(size_t)0);
    }
    
    /// Get adaptive threshold state (null if not enabled)
    ThresholdState getAdaptiveState() @trusted
    {
        return adaptive !is null ? adaptive.getState() : ThresholdState.init;
    }
    
    /// Get adaptive statistics (null if not enabled)
    AdaptiveStats getAdaptiveStats() @trusted
    {
        return adaptive !is null ? adaptive.getStats() : AdaptiveStats.init;
    }
    
    /// Check if adaptive tuning is enabled
    bool isAdaptiveEnabled() @trusted const nothrow @nogc
    {
        return adaptive !is null;
    }
    
    /// Get effective minLocalQueue (respects adaptive adjustments)
    size_t getEffectiveMinLocalQueue() @trusted
    {
        return adaptive !is null ? adaptive.getState().minLocalQueue : config.minLocalQueue;
    }
    
    /// Get effective stealThreshold (respects adaptive adjustments)
    float getEffectiveStealThreshold() @trusted
    {
        return adaptive !is null ? adaptive.getState().stealThreshold : config.stealThreshold;
    }
    
    private:
    
    /// Select victim based on strategy
    Result!(WorkerId, DistributedError) selectVictim() @trusted
    {
        final switch (config.strategy)
        {
            case StealStrategy.Random:
                return selectRandom();
            
            case StealStrategy.LeastLoaded:
                return selectLeastLoaded();
            
            case StealStrategy.MostLoaded:
                return selectMostLoaded();
            
            case StealStrategy.PowerOfTwo:
                return peers.selectVictim();  // Uses power-of-two-choices
            
            case StealStrategy.Adaptive:
                return selectAdaptive();
        }
    }
    
    /// Random victim selection
    Result!(WorkerId, DistributedError) selectRandom() @trusted
    {
        auto alivePeers = peers.getAlivePeers();
        
        if (alivePeers.length == 0)
            return Err!(WorkerId, DistributedError)(
                new DistributedError("No alive peers"));
        
        immutable idx = uniform(0, alivePeers.length);
        return Ok!(WorkerId, DistributedError)(alivePeers[idx].id);
    }
    
    /// Select least loaded peer
    Result!(WorkerId, DistributedError) selectLeastLoaded() @trusted
    {
        auto alivePeers = peers.getAlivePeers();
        if (alivePeers.length == 0) return Err!(WorkerId, DistributedError)(new DistributedError("No alive peers"));
        
        PeerInfo best = alivePeers[0];
        foreach (peer; alivePeers[1 .. $]) if (atomicLoad(peer.loadFactor) < atomicLoad(best.loadFactor)) best = peer;
        return Ok!(WorkerId, DistributedError)(best.id);
    }
    
    /// Select most loaded peer (best victim)
    Result!(WorkerId, DistributedError) selectMostLoaded() @trusted
    {
        auto alivePeers = peers.getAlivePeers();
        if (alivePeers.length == 0) return Err!(WorkerId, DistributedError)(new DistributedError("No alive peers"));
        
        PeerInfo best = alivePeers[0];
        foreach (peer; alivePeers[1 .. $]) if (atomicLoad(peer.queueDepth) > atomicLoad(best.queueDepth)) best = peer;
        if (atomicLoad(best.queueDepth) < 4) return Err!(WorkerId, DistributedError)(new DistributedError("No suitable victims"));
        return Ok!(WorkerId, DistributedError)(best.id);
    }
    
    /// Adaptive strategy - switch based on success rate
    Result!(WorkerId, DistributedError) selectAdaptive() @trusted
    {
        return metrics.successRate() < 0.3 ? selectMostLoaded() : peers.selectVictim(); // If success rate is low, try most loaded (more aggressive), otherwise use power-of-two (balanced)
    }
    
    /// Get effective timeout (respects adaptive adjustments)
    Duration getEffectiveTimeout() @trusted
    {
        return adaptive !is null ? adaptive.getState().stealTimeout : config.stealTimeout;
    }
    
    /// Get effective backoff (respects adaptive adjustments)
    Duration getEffectiveBackoff() @trusted
    {
        return adaptive !is null ? adaptive.getState().retryBackoff : config.retryBackoff;
    }
    
    /// Record attempt to adaptive system
    void recordAdaptive(bool success, long latencyUs, bool networkErr, bool timeout) @trusted
    {
        if (adaptive !is null) adaptive.recordAttempt(success, latencyUs, networkErr, timeout);
    }
    
    /// Try steal with specific timeout
    Result!(ActionRequest, DistributedError) tryStealWithTimeout(WorkerId victimId, Transport transport, Duration timeout) @trusted
    {
        return trySteal(victimId, transport, timeout);
    }
    
    /// Try to steal from specific victim
    Result!(ActionRequest, DistributedError) trySteal(WorkerId victimId, Transport transport, Duration timeout = Duration.init) @trusted
    {
        immutable effectiveTimeout = timeout == Duration.init ? config.stealTimeout : timeout;
        
        // Get victim address
        auto peerResult = peers.getPeer(victimId);
        if (peerResult.isErr)
            return Err!(ActionRequest, DistributedError)(peerResult.unwrapErr());
        
        auto peer = peerResult.unwrap();
        
        // Create steal request
        StealRequest req;
        req.thief = selfId;
        req.victim = victimId;
        req.minPriority = Priority.Low;
        
        auto startTime = MonoTime.currTime;
        
        try
        {
            // Send steal request via transport
            auto sendResult = transport.sendStealRequest(victimId, req);
            if (sendResult.isErr)
            {
                peers.markDead(victimId);
                return Err!(ActionRequest, DistributedError)(
                    new DistributedError("Failed to send steal request"));
            }
            
            // Wait for response with timeout
            auto receiveResult = transport.receiveStealResponse(effectiveTimeout);
            if (receiveResult.isErr)
            {
                immutable elapsed = MonoTime.currTime - startTime;
                if (elapsed >= effectiveTimeout)
                    return Err!(ActionRequest, DistributedError)(new DistributedError("Steal timeout"));
                return Err!(ActionRequest, DistributedError)(receiveResult.unwrapErr());
            }
            
            auto envelope = receiveResult.unwrap();
            auto response = envelope.payload;
            
            // Check if victim had work to give
            if (response.hasWork && response.action !is null)
            {
                structuredLog.debug_("successfully_stole_work_from_").field("detail", "Successfully stole work from " ~ victimId.toString()).emit();
                return Ok!(ActionRequest, DistributedError)(response.action);
            }
            return Ok!(ActionRequest, DistributedError)(null);  // Victim had no work
        }
        catch (Exception e)
        {
            structuredLog.error("steal_attempt_failed_").field("detail", "Steal attempt failed: " ~ e.msg).emit();
            peers.markDead(victimId);
            return Err!(ActionRequest, DistributedError)(
                new DistributedError("Steal exception: " ~ e.msg));
        }
    }
}

/// Exponential backoff for failed steal attempts
/// Reduces contention and network load
struct BackoffStrategy
{
    private size_t attempt;
    private Duration baseDelay = 10.msecs;
    private Duration maxDelay = 1000.msecs;
    
    this(Duration baseDelay, Duration maxDelay) pure @safe nothrow @nogc
    {
        this.baseDelay = baseDelay;
        this.maxDelay = maxDelay;
        this.attempt = 0;
    }
    
    /// Create with default parameters
    static BackoffStrategy create() pure @safe nothrow @nogc
    {
        return BackoffStrategy(10.msecs, 1000.msecs);
    }
    
    /// Get next backoff duration
    Duration next() @safe nothrow @nogc
    {
        immutable delay = min(
            baseDelay * (1 << attempt),
            maxDelay
        );
        
        attempt++;
        return delay;
    }
    
    /// Reset backoff
    void reset() pure @safe nothrow @nogc
    {
        attempt = 0;
    }
    
    /// Get current attempt count
    size_t currentAttempt() const pure @safe nothrow @nogc
    {
        return attempt;
    }
}



