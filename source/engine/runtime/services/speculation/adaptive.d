module engine.runtime.services.speculation.adaptive;

import std.algorithm : map, filter, sort, sum, min, max, clamp;
import std.array : array;
import std.datetime : Duration, msecs, seconds, hours, SysTime, Clock;
import std.conv : to;
import std.math : exp, log, sqrt, abs, isNaN;
import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.utils.logging;

/// Per-target speculation profile tracking hit rates and optimal thresholds
struct TargetSpecProfile
{
    size_t speculationAttempts;     // Total speculation attempts
    size_t speculationHits;         // Successful speculations (promoted)
    size_t speculationMisses;       // Wasted speculations (aborted/unused)
    float currentThreshold = 0.7f;  // Adaptive threshold for this target
    float ewmaHitRate = 0.5f;       // Exponentially weighted moving average
    Duration totalTimeSaved;        // Cumulative time saved
    Duration totalTimeWasted;       // Cumulative time wasted
    SysTime lastSpeculation;        // Last speculation timestamp
    
    /// Hit rate for this target
    float hitRate() const pure nothrow @nogc
        => speculationAttempts == 0 ? 0.5f : cast(float)speculationHits / speculationAttempts;
    
    /// ROI for this target (time saved / time wasted)
    float roi() const nothrow
    {
        auto wasted = totalTimeWasted.total!"msecs";
        return wasted == 0 ? float.infinity : cast(float)totalTimeSaved.total!"msecs" / wasted;
    }
    
    /// Record speculation result and update threshold
    void record(bool hit, Duration duration) @safe nothrow
    {
        speculationAttempts++;
        if (hit)
        {
            speculationHits++;
            totalTimeSaved += duration;
        }
        else
        {
            speculationMisses++;
            totalTimeWasted += duration;
        }
        lastSpeculation = Clock.currTime();
        
        // Update EWMA hit rate (alpha=0.3 for faster adaptation)
        enum ALPHA = 0.3f;
        ewmaHitRate = ALPHA * (hit ? 1.0f : 0.0f) + (1 - ALPHA) * ewmaHitRate;
    }
}

/// Adaptive threshold configuration
struct AdaptiveConfig
{
    float baseThreshold = 0.7f;           // Starting threshold
    float minThreshold = 0.3f;            // Floor - never go below
    float maxThreshold = 0.95f;           // Ceiling - never exceed
    float adaptationRate = 0.1f;          // How quickly to adjust
    size_t minSamplesForAdaptation = 5;   // Min samples before adapting
    float targetHitRate = 0.75f;          // Desired hit rate
    float roiFloor = 1.0f;                // Min acceptable ROI
    Duration decayHalfLife = 24.hours;    // Threshold decay toward base
}

/// Profile-guided speculation optimizer
/// Dynamically adjusts per-target thresholds based on historical accuracy
final class AdaptiveSpeculator
{
    private Mutex _mutex;
    private TargetSpecProfile[string] _profiles;
    private AdaptiveConfig _config;
    private AdaptiveStats _globalStats;
    
    this(AdaptiveConfig config = AdaptiveConfig.init) @trusted
    {
        _config = config;
        _mutex = new Mutex();
    }
    
    /// Get adaptive threshold for a target
    /// Returns adjusted threshold based on target's hit rate history
    float getThreshold(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto profilePtr = key in _profiles;
            
            if (profilePtr is null)
                return _config.baseThreshold;
            
            auto profile = *profilePtr;
            
            // Not enough data - use base threshold
            if (profile.speculationAttempts < _config.minSamplesForAdaptation)
                return _config.baseThreshold;
            
            // Compute adaptive threshold
            return computeAdaptiveThreshold(profile);
        }
    }
    
    /// Record speculation outcome for a target
    void recordOutcome(TargetId targetId, bool hit, Duration duration) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            
            if (key !in _profiles)
                _profiles[key] = TargetSpecProfile();
            
            _profiles[key].record(hit, duration);
            
            // Update global stats
            _globalStats.totalAttempts++;
            if (hit)
            {
                _globalStats.totalHits++;
                _globalStats.totalTimeSaved += duration;
            }
            else
            {
                _globalStats.totalMisses++;
                _globalStats.totalTimeWasted += duration;
            }
            
            // Adapt threshold for this target
            if (_profiles[key].speculationAttempts >= _config.minSamplesForAdaptation)
                adaptThreshold(key);
        }
    }
    
    /// Get profile for a target (for analysis)
    TargetSpecProfile getProfile(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            return _profiles.get(key, TargetSpecProfile());
        }
    }
    
    /// Get all profiles sorted by hit rate
    TargetSpecProfile[] getProfilesByHitRate() @trusted
    {
        synchronized (_mutex)
        {
            return _profiles.values.sort!((a, b) => a.hitRate > b.hitRate).array;
        }
    }
    
    /// Get targets that should have tighter thresholds (low hit rate)
    string[] getLowPerformers(float hitRateThreshold = 0.5f) @trusted
    {
        synchronized (_mutex)
        {
            return _profiles.byKeyValue
                .filter!(kv => kv.value.speculationAttempts >= _config.minSamplesForAdaptation)
                .filter!(kv => kv.value.hitRate < hitRateThreshold)
                .map!(kv => kv.key)
                .array;
        }
    }
    
    /// Get targets performing well (high hit rate)
    string[] getHighPerformers(float hitRateThreshold = 0.8f) @trusted
    {
        synchronized (_mutex)
        {
            return _profiles.byKeyValue
                .filter!(kv => kv.value.speculationAttempts >= _config.minSamplesForAdaptation)
                .filter!(kv => kv.value.hitRate >= hitRateThreshold)
                .map!(kv => kv.key)
                .array;
        }
    }
    
    /// Get global statistics
    AdaptiveStats getStats() @trusted
    {
        synchronized (_mutex) { return _globalStats; }
    }
    
    /// Should we speculate on this target given current prediction confidence?
    bool shouldSpeculate(TargetId targetId, float predictionConfidence) @trusted
    {
        auto threshold = getThreshold(targetId);
        return predictionConfidence >= threshold;
    }
    
    /// Export state for persistence
    AdaptiveState exportState() @trusted
    {
        synchronized (_mutex)
        {
            AdaptiveState state;
            foreach (key, profile; _profiles)
                state.profiles[key] = profile;
            state.globalStats = _globalStats;
            state.exportTime = Clock.currTime();
            return state;
        }
    }
    
    /// Import previously saved state
    void importState(AdaptiveState state) @trusted
    {
        synchronized (_mutex)
        {
            foreach (key, profile; state.profiles)
                _profiles[key] = profile;
            _globalStats = state.globalStats;
            
            structuredLog.debug_("adaptive_speculation_imported_state")
                .field("targets", _profiles.length)
                .emit();
        }
    }
    
    /// Decay thresholds toward base (call periodically)
    void decayThresholds() @trusted
    {
        synchronized (_mutex)
        {
            auto now = Clock.currTime();
            
            foreach (ref profile; _profiles)
            {
                if (profile.lastSpeculation == SysTime.init)
                    continue;
                
                auto elapsed = now - profile.lastSpeculation;
                auto hoursElapsed = elapsed.total!"hours";
                auto halfLifeHours = _config.decayHalfLife.total!"hours";
                
                if (halfLifeHours > 0)
                {
                    // Exponential decay toward base threshold
                    auto decayFactor = exp(-cast(float)hoursElapsed / halfLifeHours);
                    auto delta = profile.currentThreshold - _config.baseThreshold;
                    profile.currentThreshold = _config.baseThreshold + delta * decayFactor;
                }
            }
        }
    }
    
private:
    /// Compute adaptive threshold based on profile
    float computeAdaptiveThreshold(ref TargetSpecProfile profile) const pure nothrow @nogc
    {
        // Use EWMA hit rate for smoother adaptation
        auto hitRate = profile.ewmaHitRate;
        
        // If hit rate is below target, raise threshold (more conservative)
        // If hit rate is above target, lower threshold (more aggressive)
        auto delta = _config.targetHitRate - hitRate;
        
        // Apply adaptation with damping
        auto adjustment = delta * _config.adaptationRate;
        auto newThreshold = profile.currentThreshold + adjustment;
        
        // Clamp to bounds
        return clamp(newThreshold, _config.minThreshold, _config.maxThreshold);
    }
    
    /// Update threshold for a target based on recent performance
    void adaptThreshold(string key) @trusted
    {
        auto profilePtr = key in _profiles;
        if (profilePtr is null) return;
        
        auto profile = *profilePtr;
        auto newThreshold = computeAdaptiveThreshold(profile);
        
        // Update profile threshold
        _profiles[key].currentThreshold = newThreshold;
        
        // Log significant adaptations
        auto delta = abs(newThreshold - profile.currentThreshold);
        if (delta > 0.05f)
        {
            structuredLog.debug_("adaptive_threshold_adjusted")
                .field("target", key)
                .field("old_threshold", profile.currentThreshold)
                .field("new_threshold", newThreshold)
                .field("hit_rate", profile.hitRate)
                .emit();
        }
    }
}

/// Global adaptive statistics
struct AdaptiveStats
{
    size_t totalAttempts;
    size_t totalHits;
    size_t totalMisses;
    Duration totalTimeSaved;
    Duration totalTimeWasted;
    
    float globalHitRate() const pure nothrow @nogc @trusted
        => totalAttempts == 0 ? 0.0f : cast(float)totalHits / totalAttempts;
    
    float globalROI() const nothrow @trusted
    {
        auto wasted = totalTimeWasted.total!"msecs";
        return wasted == 0 ? float.infinity : cast(float)totalTimeSaved.total!"msecs" / wasted;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Adaptive: %d attempts, %.1f%% hit rate, ROI=%.2fx, saved=%dms, wasted=%dms",
            totalAttempts, globalHitRate * 100, globalROI,
            totalTimeSaved.total!"msecs", totalTimeWasted.total!"msecs"
        );
    }
}

/// Serializable state for persistence
struct AdaptiveState
{
    TargetSpecProfile[string] profiles;
    AdaptiveStats globalStats;
    SysTime exportTime;
}

/// Bayesian threshold optimizer using Thompson Sampling
/// More sophisticated approach for exploration vs exploitation
struct ThompsonSampler
{
    private float alpha = 1.0f;  // Successes + prior
    private float beta = 1.0f;   // Failures + prior
    
    /// Record outcome
    void record(bool success) pure nothrow @nogc
    {
        if (success) alpha += 1.0f;
        else beta += 1.0f;
    }
    
    /// Sample from Beta distribution (simplified)
    float sample() const pure nothrow @nogc
    {
        // Mean of Beta distribution as simplified sampling
        return alpha / (alpha + beta);
    }
    
    /// Get confidence interval
    float upperBound(float confidence = 0.95f) const pure nothrow @nogc
    {
        // Wilson score interval upper bound approximation
        auto n = alpha + beta - 2;  // Total samples
        auto p = (alpha - 1) / n;   // Observed proportion
        
        if (n < 1) return 1.0f;
        
        // z for 95% confidence ≈ 1.96
        enum z = 1.96f;
        auto z2 = z * z;
        
        auto center = (p + z2 / (2 * n)) / (1 + z2 / n);
        auto spread = z * sqrt((p * (1 - p) + z2 / (4 * n)) / n) / (1 + z2 / n);
        
        return min(1.0f, center + spread);
    }
}

/// Unit tests
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.adaptive - Threshold adaptation");
    
    auto adaptive = new AdaptiveSpeculator();
    auto tid = TargetId("test_target");
    
    // Record some outcomes
    foreach (_; 0 .. 10)
        adaptive.recordOutcome(tid, true, 100.msecs);  // 10 hits
    
    foreach (_; 0 .. 2)
        adaptive.recordOutcome(tid, false, 50.msecs);  // 2 misses
    
    auto profile = adaptive.getProfile(tid);
    assert(profile.speculationAttempts == 12);
    assert(profile.speculationHits == 10);
    assert(profile.hitRate > 0.8f);
    
    // High hit rate should lower threshold (more aggressive)
    auto threshold = adaptive.getThreshold(tid);
    assert(threshold < 0.7f);  // Below base
    
    writeln("\x1b[32m  ✓ Threshold adaptation\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.adaptive - Should speculate decision");
    
    auto adaptive = new AdaptiveSpeculator();
    auto goodTarget = TargetId("good");
    auto badTarget = TargetId("bad");
    
    // Good performer: 90% hit rate
    foreach (_; 0 .. 9)
        adaptive.recordOutcome(goodTarget, true, 100.msecs);
    adaptive.recordOutcome(goodTarget, false, 100.msecs);
    
    // Bad performer: 30% hit rate  
    foreach (_; 0 .. 3)
        adaptive.recordOutcome(badTarget, true, 100.msecs);
    foreach (_; 0 .. 7)
        adaptive.recordOutcome(badTarget, false, 100.msecs);
    
    // Good target should speculate at lower confidence
    assert(adaptive.shouldSpeculate(goodTarget, 0.6f));
    
    // Bad target should require higher confidence
    assert(!adaptive.shouldSpeculate(badTarget, 0.7f));
    assert(adaptive.shouldSpeculate(badTarget, 0.9f));
    
    writeln("\x1b[32m  ✓ Should speculate decision\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.adaptive - State export/import");
    
    AdaptiveState state;
    
    // Create and populate
    {
        auto adaptive = new AdaptiveSpeculator();
        foreach (_; 0 .. 5)
            adaptive.recordOutcome(TargetId("test"), true, 100.msecs);
        
        state = adaptive.exportState();
        assert("test" in state.profiles);
    }
    
    // Import into new instance
    {
        auto adaptive = new AdaptiveSpeculator();
        adaptive.importState(state);
        
        auto profile = adaptive.getProfile(TargetId("test"));
        assert(profile.speculationHits == 5);
    }
    
    writeln("\x1b[32m  ✓ State export/import\x1b[0m");
}

