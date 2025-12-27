module engine.runtime.services.speculation.speculator;

import std.algorithm : map, filter, sort, min;
import std.array : array;
import std.datetime : Duration, msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;
import std.typecons : Nullable, nullable;
import core.atomic;
import core.sync.mutex : Mutex;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.config.schema.schema : TargetId;
import engine.economics.estimator : CostEstimator, ExecutionHistory;
import infrastructure.utils.logging;

/// Speculation decision based on cache hit probability
/// Single responsibility: decide IF a node should be speculatively executed
/// based on historical cache hit rates from the economics module
struct SpeculationDecision
{
    TargetId targetId;
    float cacheHitProbability;
    bool shouldSpeculate;
    string reason;
}

/// Callback types for speculative execution lifecycle
alias ConfirmCallback = void delegate() @system;
alias AbortCallback = void delegate() @system;

/// Speculative executor - decides when to speculate based on cache hit probability
/// 
/// ## Responsibility (SOC)
/// This class is ONLY responsible for:
/// 1. Deciding WHETHER to speculate (based on cache hit probability threshold)
/// 2. Tracking active speculations and their callbacks
/// 3. Triggering confirm/abort callbacks when speculation resolves
/// 
/// Actual execution is delegated to the caller or SpeculativeEngine.
/// Cache hit estimation is delegated to CostEstimator (economics module).
final class SpeculativeExecutor
{
    private CostEstimator _estimator;
    private Mutex _mutex;
    private float _speculationThreshold;
    
    // Active speculation tracking
    private SpeculationContext[string] _activeSpeculations;
    private shared size_t _speculationsStarted;
    private shared size_t _speculationsConfirmed;
    private shared size_t _speculationsAborted;
    
    /// Create with custom threshold (default 85%)
    this(CostEstimator estimator, float threshold = 0.85f) @trusted
    {
        _estimator = estimator;
        _speculationThreshold = threshold;
        _mutex = new Mutex();
        atomicStore(_speculationsStarted, cast(size_t)0);
        atomicStore(_speculationsConfirmed, cast(size_t)0);
        atomicStore(_speculationsAborted, cast(size_t)0);
    }
    
    /// Get/set speculation threshold (0.0 - 1.0)
    @property float speculationThreshold() const @safe nothrow @nogc => _speculationThreshold;
    @property void speculationThreshold(float value) @safe nothrow @nogc
    {
        _speculationThreshold = value < 0 ? 0 : (value > 1 ? 1 : value);
    }
    
    /// Check if a node should be speculatively executed
    /// Returns true if cache hit probability >= threshold
    bool shouldSpeculate(BuildNode node) @system
    {
        if (node is null) return false;
        return _estimator.estimateCacheHitProbabilityForNode(node) >= _speculationThreshold;
    }
    
    /// Get detailed speculation decision with reasoning
    SpeculationDecision getDecision(BuildNode node) @system
    {
        SpeculationDecision decision;
        decision.targetId = node.id;
        decision.cacheHitProbability = _estimator.estimateCacheHitProbabilityForNode(node);
        decision.shouldSpeculate = decision.cacheHitProbability >= _speculationThreshold;
        
        if (decision.shouldSpeculate)
            decision.reason = "cache_hit_prob=" ~ (cast(int)(decision.cacheHitProbability * 100)).to!string ~ 
                             "% >= threshold=" ~ (cast(int)(_speculationThreshold * 100)).to!string ~ "%";
        else
            decision.reason = "cache_hit_prob=" ~ (cast(int)(decision.cacheHitProbability * 100)).to!string ~ 
                             "% < threshold=" ~ (cast(int)(_speculationThreshold * 100)).to!string ~ "%";
        
        return decision;
    }
    
    /// Get speculation candidates from a set of nodes
    /// Returns nodes sorted by cache hit probability (highest first)
    TargetId[] getCandidates(BuildNode[] nodes, size_t maxCount = 10) @system
    {
        auto candidates = nodes
            .filter!(n => n !is null && n.status == BuildStatus.Pending)
            .map!(n => tuple(n.id, _estimator.estimateCacheHitProbabilityForNode(n)))
            .filter!(t => t[1] >= _speculationThreshold)
            .array;
        
        candidates.sort!((a, b) => a[1] > b[1]);
        
        return candidates[0 .. min(maxCount, candidates.length)]
            .map!(t => t[0])
            .array;
    }
    
    /// Begin speculative execution with confirm/abort callbacks
    /// The caller is responsible for actually executing the node
    /// This method tracks the speculation for later resolution
    void executeSpeculatively(
        BuildNode node,
        ConfirmCallback onConfirm,
        AbortCallback onAbort
    ) @system
    {
        if (node is null) return;
        
        synchronized (_mutex)
        {
            auto key = node.id.toString();
            
            // Don't duplicate
            if (key in _activeSpeculations)
            {
                structuredLog.debug_("speculator_already_speculating_").field("detail", "Speculator: already speculating " ~ key).emit();
                return;
            }
            
            _activeSpeculations[key] = SpeculationContext(
                node.id,
                onConfirm,
                onAbort,
                StopWatch(AutoStart.yes)
            );
            
            atomicOp!"+="(_speculationsStarted, 1);
            structuredLog.debug_("speculator_started_speculation_for_").field("detail", "Speculator: started speculation for " ~ key).emit();
        }
    }
    
    /// Confirm speculation succeeded - cache hit validated
    void confirmSpeculation(TargetId targetId) @system
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto ctxPtr = key in _activeSpeculations;
            
            if (ctxPtr is null)
            {
                structuredLog.debug_("speculator_no_active_speculation_for_").field("detail", "Speculator: no active speculation for " ~ key).emit();
                return;
            }
            
            auto ctx = *ctxPtr;
            _activeSpeculations.remove(key);
            
            atomicOp!"+="(_speculationsConfirmed, 1);
            structuredLog.debug_("speculator_confirmed_").field("detail", "Speculator: confirmed " ~ key ~ 
                           " in " ~ ctx.timer.peek().total!"msecs".to!string ~ "ms").emit();
            
            if (ctx.onConfirm !is null)
                ctx.onConfirm();
        }
    }
    
    /// Abort speculation - inputs changed or cache miss
    void abortSpeculation(TargetId targetId, string reason = "") @system
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto ctxPtr = key in _activeSpeculations;
            
            if (ctxPtr is null) return;
            
            auto ctx = *ctxPtr;
            _activeSpeculations.remove(key);
            
            atomicOp!"+="(_speculationsAborted, 1);
            structuredLog.debug_("speculator_aborted_").field("detail", "Speculator: aborted " ~ key ~ 
                           (reason.length > 0 ? " (" ~ reason ~ ")" : "")).emit();
            
            if (ctx.onAbort !is null)
                ctx.onAbort();
        }
    }
    
    /// Check if speculation is active for a target
    bool isSpeculating(TargetId targetId) @system
    {
        synchronized (_mutex)
        {
            return (targetId.toString() in _activeSpeculations) !is null;
        }
    }
    
    /// Abort all active speculations
    void abortAll(string reason = "shutdown") @system
    {
        synchronized (_mutex)
        {
            foreach (key, ctx; _activeSpeculations)
            {
                atomicOp!"+="(_speculationsAborted, 1);
                if (ctx.onAbort !is null)
                    ctx.onAbort();
            }
            _activeSpeculations.clear();
            structuredLog.debug_("speculator_aborted_all_speculations_").field("detail", "Speculator: aborted all speculations (" ~ reason ~ ")").emit();
        }
    }
    
    /// Get speculation statistics
    SpeculatorStats getStats() const @system
    {
        SpeculatorStats stats;
        stats.started = atomicLoad(_speculationsStarted);
        stats.confirmed = atomicLoad(_speculationsConfirmed);
        stats.aborted = atomicLoad(_speculationsAborted);
        stats.threshold = _speculationThreshold;
        return stats;
    }
    
    /// Get the underlying cost estimator (for external coordination)
    @property CostEstimator estimator() @safe nothrow => _estimator;
}

/// Internal context for tracking active speculations
private struct SpeculationContext
{
    TargetId targetId;
    ConfirmCallback onConfirm;
    AbortCallback onAbort;
    StopWatch timer;
}

/// Statistics for the speculator
struct SpeculatorStats
{
    size_t started;
    size_t confirmed;
    size_t aborted;
    float threshold;
    
    @property size_t active() const pure nothrow @nogc => started - confirmed - aborted;
    
    @property float confirmRate() const pure nothrow @nogc @safe
    {
        auto resolved = confirmed + aborted;
        return resolved == 0 ? 0.0f : cast(float)confirmed / cast(float)resolved;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format("Speculator: %d started, %d confirmed (%.1f%%), %d aborted, threshold=%.0f%%",
            started, confirmed, confirmRate * 100, aborted, threshold * 100);
    }
}

/// Create a speculative executor from execution history
SpeculativeExecutor createSpeculator(ExecutionHistory history, float threshold = 0.85f) @trusted
{
    auto estimator = new CostEstimator(history);
    return new SpeculativeExecutor(estimator, threshold);
}

/// Create a speculative executor with existing estimator
SpeculativeExecutor createSpeculator(CostEstimator estimator, float threshold = 0.85f) @trusted
{
    return new SpeculativeExecutor(estimator, threshold);
}

/// Helper: tuple for sorting
private auto tuple(T...)(T args) { import std.typecons : Tuple; return Tuple!T(args); }

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.speculator - SpeculatorStats");
    
    SpeculatorStats stats;
    stats.started = 10;
    stats.confirmed = 7;
    stats.aborted = 2;
    stats.threshold = 0.85f;
    
    assert(stats.active == 1);
    assert(stats.confirmRate > 0.77f && stats.confirmRate < 0.78f); // 7/9 ≈ 0.778
    
    auto formatted = stats.format();
    assert(formatted.length > 0);
    
    writeln("\x1b[32m  ✓ Stats calculation\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.speculator - Threshold bounds");
    
    auto history = new ExecutionHistory();
    auto speculator = createSpeculator(history, 0.85f);
    
    assert(speculator.speculationThreshold == 0.85f);
    
    // Test bounds
    speculator.speculationThreshold = -0.5f;
    assert(speculator.speculationThreshold == 0.0f);
    
    speculator.speculationThreshold = 1.5f;
    assert(speculator.speculationThreshold == 1.0f);
    
    speculator.speculationThreshold = 0.9f;
    assert(speculator.speculationThreshold == 0.9f);
    
    writeln("\x1b[32m  ✓ Threshold bounds\x1b[0m");
}

