module engine.distributed.worker.adaptive;

import std.datetime : Duration, MonoTime, msecs, seconds;
import std.algorithm : min, max, clamp;
import std.math : exp, log, isNaN;
import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.utils.logging;

/// Adaptive threshold tuning configuration
struct AdaptiveConfig
{
    /// Learning rate for EWMA (0.0-1.0, higher = faster adaptation)
    float alpha = 0.15;
    
    /// Minimum success rate threshold (below this, increase minLocalQueue)
    float lowSuccessThreshold = 0.20;
    
    /// High success rate threshold (above this, can decrease minLocalQueue)
    float highSuccessThreshold = 0.60;
    
    /// Latency threshold in microseconds (above this, increase timeout)
    long highLatencyThresholdUs = 50_000;  // 50ms
    
    /// Low latency threshold (below this, can decrease timeout)
    long lowLatencyThresholdUs = 10_000;   // 10ms
    
    /// Evaluation window size (samples before adjustment)
    size_t evaluationWindow = 50;
    
    /// Cooldown between adjustments (prevent oscillation)
    Duration adjustmentCooldown = 5.seconds;
    
    /// Bounds for minLocalQueue
    size_t minLocalQueueLower = 1;
    size_t minLocalQueueUpper = 16;
    
    /// Bounds for stealThreshold (0.0-1.0)
    float stealThresholdLower = 0.2;
    float stealThresholdUpper = 0.8;
    
    /// Bounds for stealTimeout
    Duration stealTimeoutLower = 25.msecs;
    Duration stealTimeoutUpper = 500.msecs;
    
    /// Bounds for retryBackoff
    Duration retryBackoffLower = 10.msecs;
    Duration retryBackoffUpper = 200.msecs;
}

/// Current adaptive threshold state
struct ThresholdState
{
    size_t minLocalQueue = 2;
    float stealThreshold = 0.5;
    Duration stealTimeout = 100.msecs;
    Duration retryBackoff = 50.msecs;
    
    /// For debugging/monitoring
    string toString() const
    {
        import std.format : format;
        return format("minLocalQueue=%d stealThreshold=%.2f timeout=%dms backoff=%dms",
            minLocalQueue, stealThreshold, 
            stealTimeout.total!"msecs", retryBackoff.total!"msecs");
    }
}

/// EWMA statistics for a single metric
private struct EwmaStat
{
    float value = 0;
    float variance = 0;
    size_t samples = 0;
    
    /// Update with new observation
    void update(float observation, float alpha) pure nothrow @nogc
    {
        if (samples == 0) { value = observation; variance = 0; }
        else
        {
            immutable diff = observation - value;
            value += alpha * diff;
            variance = (1 - alpha) * (variance + alpha * diff * diff);
        }
        samples++;
    }
    
    /// Get standard deviation
    float stddev() const pure nothrow @nogc => variance > 0 ? sqrt(variance) : 0;
    
    private static float sqrt(float x) pure nothrow @nogc
    {
        if (x <= 0) return 0;
        float r = x;
        foreach (_; 0 .. 10) r = (r + x / r) / 2;  // Newton-Raphson
        return r;
    }
}

/// Adaptive work-stealing threshold tuner
/// Monitors steal performance and dynamically adjusts thresholds
final class AdaptiveThresholds
{
    private AdaptiveConfig config;
    private Mutex mutex;
    
    // EWMA statistics
    private EwmaStat successRate;
    private EwmaStat latencyUs;
    private EwmaStat networkErrorRate;
    private EwmaStat timeoutRate;
    
    // Current state
    private ThresholdState state;
    private MonoTime lastAdjustment;
    private size_t samplesSinceAdjustment;
    
    // Adjustment history for analysis
    private AdjustmentRecord[8] history;
    private size_t historyIdx;
    
    // Callbacks
    void delegate(ThresholdState oldState, ThresholdState newState) @safe onAdjustment;
    
    this(AdaptiveConfig config = AdaptiveConfig.init, ThresholdState initial = ThresholdState.init) @trusted
    {
        this.config = config;
        this.state = initial;
        this.mutex = new Mutex();
        this.lastAdjustment = MonoTime.currTime;
    }
    
    /// Record steal attempt outcome
    void recordAttempt(bool success, long latencyUs, bool networkError = false, bool timeout = false) @trusted
    {
        synchronized (mutex)
        {
            successRate.update(success ? 1.0 : 0.0, config.alpha);
            this.latencyUs.update(cast(float)latencyUs, config.alpha);
            networkErrorRate.update(networkError ? 1.0 : 0.0, config.alpha);
            timeoutRate.update(timeout ? 1.0 : 0.0, config.alpha);
            
            samplesSinceAdjustment++;
            
            if (shouldEvaluate()) evaluate();
        }
    }
    
    /// Get current threshold state (thread-safe copy)
    ThresholdState getState() @trusted
    {
        synchronized (mutex) return state;
    }
    
    /// Get current EWMA statistics
    AdaptiveStats getStats() @trusted
    {
        synchronized (mutex)
        {
            return AdaptiveStats(
                successRate.value, successRate.stddev,
                latencyUs.value, latencyUs.stddev,
                networkErrorRate.value, timeoutRate.value,
                successRate.samples, samplesSinceAdjustment
            );
        }
    }
    
    /// Get adjustment history
    AdjustmentRecord[] getHistory() @trusted
    {
        synchronized (mutex)
        {
            AdjustmentRecord[] result;
            foreach (i; 0 .. history.length)
            {
                immutable idx = (historyIdx + i) % history.length;
                if (history[idx].timestamp != MonoTime.init)
                    result ~= history[idx];
            }
            return result;
        }
    }
    
    /// Force evaluation (for testing or manual trigger)
    void forceEvaluate() @trusted
    {
        synchronized (mutex) evaluate();
    }
    
    /// Reset statistics (but preserve current thresholds)
    void resetStats() @trusted
    {
        synchronized (mutex)
        {
            successRate = EwmaStat.init;
            latencyUs = EwmaStat.init;
            networkErrorRate = EwmaStat.init;
            timeoutRate = EwmaStat.init;
            samplesSinceAdjustment = 0;
        }
    }
    
    private:
    
    /// Check if we should evaluate and potentially adjust
    bool shouldEvaluate() @trusted
    {
        if (samplesSinceAdjustment < config.evaluationWindow) return false;
        
        immutable elapsed = MonoTime.currTime - lastAdjustment;
        return elapsed >= config.adjustmentCooldown;
    }
    
    /// Evaluate current performance and adjust thresholds
    void evaluate() @trusted
    {
        immutable oldState = state;
        bool adjusted = false;
        AdjustmentReason reason = AdjustmentReason.None;
        
        // Adjust minLocalQueue based on success rate
        if (successRate.value < config.lowSuccessThreshold && successRate.samples >= 10)
        {
            // Low success rate: increase minLocalQueue (be more conservative)
            immutable newVal = min(state.minLocalQueue + 1, config.minLocalQueueUpper);
            if (newVal != state.minLocalQueue)
            {
                state.minLocalQueue = newVal;
                adjusted = true;
                reason = AdjustmentReason.LowSuccessRate;
                structuredLog.debug_("adaptive_increased_minlocalqueue_to_").field("detail", "Adaptive: Increased minLocalQueue to " ~ 
                    state.minLocalQueue.stringof ~ " due to low success rate").emit();
            }
        }
        else if (successRate.value > config.highSuccessThreshold && successRate.samples >= 20)
        {
            // High success rate: can decrease minLocalQueue (be more aggressive)
            immutable newVal = max(state.minLocalQueue - 1, config.minLocalQueueLower);
            if (newVal != state.minLocalQueue)
            {
                state.minLocalQueue = newVal;
                adjusted = true;
                reason = AdjustmentReason.HighSuccessRate;
            }
        }
        
        // Adjust timeout based on latency
        if (latencyUs.value > config.highLatencyThresholdUs && latencyUs.samples >= 10)
        {
            // High latency: increase timeout
            immutable currentMs = state.stealTimeout.total!"msecs";
            immutable newMs = min(cast(long)(currentMs * 1.5), config.stealTimeoutUpper.total!"msecs");
            if (newMs != currentMs)
            {
                state.stealTimeout = newMs.msecs;
                immutable backoffMs = cast(long)(state.retryBackoff.total!"msecs" * 1.25);
                state.retryBackoff = min(backoffMs.msecs, config.retryBackoffUpper);
                adjusted = true;
                if (reason == AdjustmentReason.None) reason = AdjustmentReason.HighLatency;
            }
        }
        else if (latencyUs.value < config.lowLatencyThresholdUs && latencyUs.samples >= 20)
        {
            // Low latency: can decrease timeout
            immutable currentMs = state.stealTimeout.total!"msecs";
            immutable newMs = max(cast(long)(currentMs * 0.8), config.stealTimeoutLower.total!"msecs");
            if (newMs != currentMs)
            {
                state.stealTimeout = newMs.msecs;
                immutable backoffMs = cast(long)(state.retryBackoff.total!"msecs" * 0.9);
                state.retryBackoff = max(backoffMs.msecs, config.retryBackoffLower);
                adjusted = true;
                if (reason == AdjustmentReason.None) reason = AdjustmentReason.LowLatency;
            }
        }
        
        // Adjust stealThreshold based on combined metrics
        if (networkErrorRate.value > 0.3 || timeoutRate.value > 0.2)
        {
            // High error/timeout rates: increase threshold (steal less often)
            state.stealThreshold = min(state.stealThreshold + 0.05, config.stealThresholdUpper);
            adjusted = true;
            if (reason == AdjustmentReason.None) reason = AdjustmentReason.HighErrorRate;
        }
        else if (networkErrorRate.value < 0.05 && timeoutRate.value < 0.05 && successRate.value > 0.5)
        {
            // Low errors and good success: decrease threshold (steal more eagerly)
            state.stealThreshold = max(state.stealThreshold - 0.03, config.stealThresholdLower);
            adjusted = true;
            if (reason == AdjustmentReason.None) reason = AdjustmentReason.LowErrorRate;
        }
        
        if (adjusted)
        {
            lastAdjustment = MonoTime.currTime;
            samplesSinceAdjustment = 0;
            
            // Record in history
            history[historyIdx] = AdjustmentRecord(
                MonoTime.currTime, reason, oldState, state,
                successRate.value, latencyUs.value
            );
            historyIdx = (historyIdx + 1) % history.length;
            
            // Notify callback
            if (onAdjustment !is null)
            {
                try { onAdjustment(oldState, state); }
                catch (Exception e) { structuredLog.error("adaptive_callback_error_").field("detail", "Adaptive callback error: " ~ e.msg).emit(); }
            }
        }
        else samplesSinceAdjustment = 0;  // Reset even without adjustment
    }
}

/// Adjustment reason for debugging/analysis
enum AdjustmentReason
{
    None,
    LowSuccessRate,
    HighSuccessRate,
    HighLatency,
    LowLatency,
    HighErrorRate,
    LowErrorRate
}

/// Record of a threshold adjustment
struct AdjustmentRecord
{
    MonoTime timestamp;
    AdjustmentReason reason;
    ThresholdState before;
    ThresholdState after;
    float successRate;
    float latencyUs;
    
    string toString() const
    {
        import std.format : format;
        return format("[%s] %s -> %s (success=%.1f%% latency=%.1fms)",
            reason, before.toString(), after.toString(),
            successRate * 100, latencyUs / 1000);
    }
}

/// Adaptive statistics snapshot
struct AdaptiveStats
{
    float successRate;
    float successStddev;
    float avgLatencyUs;
    float latencyStddev;
    float networkErrorRate;
    float timeoutRate;
    size_t totalSamples;
    size_t samplesSinceAdjust;
    
    /// Calculate coefficient of variation for latency
    float latencyCv() const pure nothrow @nogc 
    {
        return avgLatencyUs > 0 ? latencyStddev / avgLatencyUs : 0;
    }
    
    string toString() const
    {
        import std.format : format;
        return format(
            "success=%.1f%%±%.1f%% latency=%.1fms±%.1fms errors=%.1f%% timeouts=%.1f%% samples=%d",
            successRate * 100, successStddev * 100,
            avgLatencyUs / 1000, latencyStddev / 1000,
            networkErrorRate * 100, timeoutRate * 100,
            totalSamples
        );
    }
}

// ===================== UNIT TESTS =====================

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - EwmaStat basic");
    
    EwmaStat stat;
    stat.update(1.0, 0.5);
    assert(stat.value == 1.0);
    assert(stat.samples == 1);
    
    stat.update(0.0, 0.5);
    assert(stat.value == 0.5);  // (1.0 + 0.0) / 2 with alpha=0.5
    assert(stat.samples == 2);
    
    writeln("\x1b[32m  ✓ EwmaStat basic\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Default config");
    
    AdaptiveConfig cfg;
    assert(cfg.alpha > 0 && cfg.alpha < 1);
    assert(cfg.lowSuccessThreshold == 0.20);
    assert(cfg.minLocalQueueLower < cfg.minLocalQueueUpper);
    
    writeln("\x1b[32m  ✓ Default config\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Initial state");
    
    auto adaptive = new AdaptiveThresholds();
    auto state = adaptive.getState();
    
    assert(state.minLocalQueue == 2);
    assert(state.stealThreshold == 0.5);
    assert(state.stealTimeout == 100.msecs);
    
    writeln("\x1b[32m  ✓ Initial state\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Low success rate increases minLocalQueue");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 10;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.lowSuccessThreshold = 0.20;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    
    // Record many failures (success rate < 20%)
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(false, 1000);
    
    auto state = adaptive.getState();
    assert(state.minLocalQueue > 2, "minLocalQueue should increase with low success rate");
    
    writeln("\x1b[32m  ✓ Low success rate increases minLocalQueue\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - High latency increases timeout");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 10;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.highLatencyThresholdUs = 50_000;
    
    ThresholdState initial;
    initial.stealTimeout = 100.msecs;
    
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record high latency (>50ms)
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(true, 80_000);  // 80ms
    
    auto state = adaptive.getState();
    assert(state.stealTimeout > 100.msecs, "stealTimeout should increase with high latency");
    
    writeln("\x1b[32m  ✓ High latency increases timeout\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Stats tracking");
    
    auto adaptive = new AdaptiveThresholds();
    
    adaptive.recordAttempt(true, 5000);
    adaptive.recordAttempt(false, 10000);
    adaptive.recordAttempt(true, 8000);
    
    auto stats = adaptive.getStats();
    assert(stats.totalSamples == 3);
    assert(stats.successRate > 0.5 && stats.successRate < 0.8);
    
    writeln("\x1b[32m  ✓ Stats tracking\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Bounds enforcement");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.minLocalQueueUpper = 4;
    
    ThresholdState initial;
    initial.minLocalQueue = 4;
    
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Try to increase beyond upper bound
    foreach (_; 0 .. 20)
        adaptive.recordAttempt(false, 1000);
    
    auto state = adaptive.getState();
    assert(state.minLocalQueue <= cfg.minLocalQueueUpper, "Should not exceed upper bound");
    
    writeln("\x1b[32m  ✓ Bounds enforcement\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Callback notification");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    
    bool callbackInvoked = false;
    ThresholdState capturedOld, capturedNew;
    
    adaptive.onAdjustment = (old, newState) {
        callbackInvoked = true;
        capturedOld = old;
        capturedNew = newState;
    };
    
    // Trigger adjustment via low success
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(false, 1000);
    
    assert(callbackInvoked, "Callback should be invoked on adjustment");
    
    writeln("\x1b[32m  ✓ Callback notification\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive Thresholds - Reset stats preserves thresholds");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    
    ThresholdState initial;
    initial.minLocalQueue = 5;
    
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record some data
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(true, 5000);
    
    auto statsBefore = adaptive.getStats();
    assert(statsBefore.totalSamples == 10);
    
    adaptive.resetStats();
    
    auto statsAfter = adaptive.getStats();
    assert(statsAfter.totalSamples == 0);
    
    auto state = adaptive.getState();
    assert(state.minLocalQueue == 5, "Thresholds should be preserved after reset");
    
    writeln("\x1b[32m  ✓ Reset stats preserves thresholds\x1b[0m");
}

