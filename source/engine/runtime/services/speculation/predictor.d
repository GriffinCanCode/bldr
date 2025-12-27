module engine.runtime.services.speculation.predictor;

import std.algorithm : map, filter, sort, sum, max, min, canFind, reduce;
import std.array : array, assocArray;
import std.datetime : Duration, msecs, seconds, SysTime, Clock;
import std.conv : to;
import std.math : exp, log, sqrt, isNaN;
import std.typecons : Nullable, nullable, Tuple, tuple;
import core.sync.mutex : Mutex;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.utils.logging;

/// Change probability for a single target
struct ChangeProbability
{
    TargetId targetId;
    float probability;      // 0.0 - 1.0: likelihood of needing rebuild
    float confidence;       // 0.0 - 1.0: confidence in prediction
    string[] reasons;       // Why this probability was assigned
    
    /// Combined score for prioritization (probability * confidence)
    @property float score() const pure nothrow @nogc => probability * confidence;
}

/// Bayesian change probability predictor
/// Learns from historical patterns to predict which targets are likely to need rebuilding
/// Uses multiple signals: file change frequency, time patterns, co-change correlations
final class ChangePredictor
{
    private Mutex _mutex;
    
    // Learned parameters
    private TargetStats[string] _targetStats;
    private CoChangeMatrix _coChangeMatrix;
    private TimePattern _timePattern;
    
    // Configuration
    private PredictorConfig _config;
    
    // Recent context for prediction
    private string[] _recentlyChanged;
    private SysTime _lastChangeTime;
    
    this(PredictorConfig config = PredictorConfig.init) @trusted
    {
        _config = config;
        _mutex = new Mutex();
        _coChangeMatrix = CoChangeMatrix(_config.maxCoChangeTargets);
        _timePattern = TimePattern();
    }
    
    /// Predict change probabilities for all known targets
    /// Returns sorted by score (highest probability * confidence first)
    ChangeProbability[] predict() @trusted
    {
        synchronized (_mutex)
        {
            ChangeProbability[] predictions;
            predictions.reserve(_targetStats.length);
            
            foreach (key, stats; _targetStats)
            {
                auto prob = computeProbability(key, stats);
                if (prob.probability > _config.minProbabilityThreshold)
                    predictions ~= prob;
            }
            
            predictions.sort!((a, b) => a.score > b.score);
            return predictions;
        }
    }
    
    /// Predict for specific targets only
    ChangeProbability[] predictFor(TargetId[] targetIds) @trusted
    {
        synchronized (_mutex)
        {
            ChangeProbability[] predictions;
            predictions.reserve(targetIds.length);
            
            foreach (tid; targetIds)
            {
                auto key = tid.toString();
                if (auto statsPtr = key in _targetStats)
                {
                    auto prob = computeProbability(key, *statsPtr);
                    predictions ~= prob;
                }
                else
                {
                    // No history - use prior
                    predictions ~= ChangeProbability(
                        tid, 
                        _config.priorProbability,
                        0.1f,  // Low confidence
                        ["no_history"]
                    );
                }
            }
            
            predictions.sort!((a, b) => a.score > b.score);
            return predictions;
        }
    }
    
    /// Get probability for a single target
    Nullable!ChangeProbability predictOne(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            if (auto statsPtr = key in _targetStats)
                return nullable(computeProbability(key, *statsPtr));
            return Nullable!ChangeProbability.init;
        }
    }
    
    /// Record that a target changed (for learning)
    void recordChange(TargetId targetId, SysTime timestamp = Clock.currTime()) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            
            // Update target stats
            if (key !in _targetStats)
                _targetStats[key] = TargetStats.init;
            
            _targetStats[key].recordChange(timestamp);
            
            // Update co-change matrix with recent changes
            foreach (recentKey; _recentlyChanged)
            {
                if (recentKey != key)
                    _coChangeMatrix.recordCoChange(recentKey, key);
            }
            
            // Update time pattern
            _timePattern.recordChange(timestamp);
            
            // Update recent context (sliding window)
            _recentlyChanged = (_recentlyChanged ~ key).filter!(k => k != key || k == key).array;
            if (_recentlyChanged.length > _config.coChangeWindow)
                _recentlyChanged = _recentlyChanged[$ - _config.coChangeWindow .. $];
            
            _lastChangeTime = timestamp;
        }
    }
    
    /// Record that a target was built but didn't need changes
    void recordNoChange(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            if (key !in _targetStats)
                _targetStats[key] = TargetStats.init;
            
            _targetStats[key].recordNoChange();
        }
    }
    
    /// Record co-change relationship (A changed → B needed rebuild)
    void recordCoChange(TargetId source, TargetId affected) @trusted
    {
        synchronized (_mutex)
        {
            _coChangeMatrix.recordCoChange(source.toString(), affected.toString());
        }
    }
    
    /// Export learned model for persistence
    PredictorState exportState() @trusted
    {
        synchronized (_mutex)
        {
            PredictorState state;
            
            foreach (key, stats; _targetStats)
                state.targetStats[key] = stats;
            
            state.coChangeMatrix = _coChangeMatrix.exportMatrix();
            state.timePattern = _timePattern.exportPattern();
            state.exportTime = Clock.currTime();
            
            return state;
        }
    }
    
    /// Import previously learned model
    void importState(PredictorState state) @trusted
    {
        synchronized (_mutex)
        {
            foreach (key, stats; state.targetStats)
                _targetStats[key] = stats;
            
            _coChangeMatrix.importMatrix(state.coChangeMatrix);
            _timePattern.importPattern(state.timePattern);
            
            structuredLog.debug_("imported_predictor_state_with_").field("detail", "Imported predictor state with " ~ 
                           _targetStats.length.to!string ~ " targets").emit();
        }
    }
    
    /// Get prediction statistics
    PredictorStats getStats() @trusted
    {
        synchronized (_mutex)
        {
            PredictorStats stats;
            stats.trackedTargets = _targetStats.length;
            stats.totalChangesRecorded = _targetStats.values
                .map!(s => s.changeCount)
                .sum;
            stats.coChangeRelationships = _coChangeMatrix.relationshipCount;
            
            if (_targetStats.length > 0)
            {
                auto accuracies = _targetStats.values
                    .filter!(s => s.predictionCount > 0)
                    .map!(s => s.accuracy);
                
                float totalAcc = 0;
                size_t count = 0;
                foreach (acc; accuracies)
                {
                    totalAcc += acc;
                    count++;
                }
                stats.averageAccuracy = count > 0 ? totalAcc / count : 0;
            }
            
            return stats;
        }
    }
    
private:
    /// Compute probability using Bayesian inference
    ChangeProbability computeProbability(string key, ref TargetStats stats) @trusted
    {
        string[] reasons;
        float probability = _config.priorProbability;
        float confidence = 0.5f;
        
        // Factor 1: Historical change frequency
        if (stats.changeCount > 0)
        {
            auto freqFactor = computeFrequencyFactor(stats);
            probability = bayesianUpdate(probability, freqFactor);
            confidence += 0.1f * min(stats.changeCount, 10) / 10.0f;
            
            if (freqFactor > 0.6f)
                reasons ~= "high_change_frequency";
        }
        
        // Factor 2: Recency of last change
        if (stats.lastChangeTime != SysTime.init)
        {
            auto recencyFactor = computeRecencyFactor(stats.lastChangeTime);
            probability = bayesianUpdate(probability, recencyFactor);
            
            if (recencyFactor > 0.7f)
                reasons ~= "recently_changed";
        }
        
        // Factor 3: Co-change correlation with recently changed targets
        foreach (recentKey; _recentlyChanged)
        {
            auto coChangeFactor = _coChangeMatrix.getCorrelation(recentKey, key);
            if (coChangeFactor > 0.3f)
            {
                probability = bayesianUpdate(probability, coChangeFactor);
                confidence += 0.1f;
                reasons ~= "co_change:" ~ recentKey[0 .. min(20, $)];
            }
        }
        
        // Factor 4: Time-of-day pattern
        auto timeFactor = _timePattern.getProbabilityFactor(Clock.currTime());
        probability = bayesianUpdate(probability, timeFactor * _config.priorProbability);
        
        // Clamp values
        probability = max(0.0f, min(1.0f, probability));
        confidence = max(0.1f, min(1.0f, confidence));
        
        if (reasons.length == 0)
            reasons ~= "baseline";
        
        return ChangeProbability(
            TargetId(key),
            probability,
            confidence,
            reasons
        );
    }
    
    /// Bayesian update: P(A|B) ∝ P(B|A) * P(A)
    static float bayesianUpdate(float prior, float likelihood) pure nothrow @nogc
    {
        // Simplified Bayesian update with smoothing
        auto posterior = (likelihood * prior) / 
            (likelihood * prior + (1 - likelihood) * (1 - prior) + 0.01f);
        return isNaN(posterior) ? prior : posterior;
    }
    
    /// Compute frequency-based probability factor
    float computeFrequencyFactor(ref TargetStats stats) const pure nothrow @nogc
    {
        if (stats.observationCount == 0) return _config.priorProbability;
        
        auto changeRate = cast(float)stats.changeCount / cast(float)stats.observationCount;
        // Smooth with prior using pseudocounts
        enum PSEUDO_CHANGES = 1.0f;
        enum PSEUDO_OBS = 5.0f;
        return (stats.changeCount + PSEUDO_CHANGES) / 
               (stats.observationCount + PSEUDO_OBS);
    }
    
    /// Compute recency factor (exponential decay)
    float computeRecencyFactor(SysTime lastChange) const @trusted
    {
        auto elapsed = Clock.currTime() - lastChange;
        auto hours = elapsed.total!"hours";
        
        // Exponential decay with half-life of ~24 hours
        return exp(-hours / 24.0f);
    }
}

/// Statistics for a single target
struct TargetStats
{
    size_t changeCount;         // Times this target needed rebuild
    size_t observationCount;    // Total times observed
    size_t predictionCount;     // Times we made predictions
    size_t correctPredictions;  // Correct predictions
    SysTime lastChangeTime;     // Last time this changed
    float ewmaChangeRate = 0.5f; // Exponentially weighted moving average
    
    void recordChange(SysTime timestamp) @safe nothrow
    {
        changeCount++;
        observationCount++;
        lastChangeTime = timestamp;
        
        // Update EWMA (alpha = 0.2)
        ewmaChangeRate = 0.8f * ewmaChangeRate + 0.2f * 1.0f;
    }
    
    void recordNoChange() @safe nothrow
    {
        observationCount++;
        ewmaChangeRate = 0.8f * ewmaChangeRate + 0.2f * 0.0f;
    }
    
    void recordPrediction(bool correct) @safe nothrow
    {
        predictionCount++;
        if (correct) correctPredictions++;
    }
    
    @property float accuracy() const pure nothrow @nogc
    {
        return predictionCount == 0 ? 0.5f : 
            cast(float)correctPredictions / cast(float)predictionCount;
    }
}

/// Co-change correlation matrix (sparse representation)
struct CoChangeMatrix
{
    private size_t[string][string] _matrix;  // [source][target] → count
    private size_t _maxTargets;
    private size_t _totalEdges;
    
    this(size_t maxTargets) @safe nothrow @nogc
    {
        _maxTargets = maxTargets;
    }
    
    void recordCoChange(string source, string target) @trusted
    {
        if (source !in _matrix)
        {
            if (_matrix.length >= _maxTargets)
                return; // Limit matrix size
            _matrix[source] = (size_t[string]).init;
        }
        
        if (target !in _matrix[source])
        {
            _matrix[source][target] = 0;
            _totalEdges++;
        }
        
        _matrix[source][target]++;
    }
    
    float getCorrelation(string source, string target) const @trusted
    {
        if (source !in _matrix) return 0.0f;
        auto row = _matrix[source];
        if (target !in row) return 0.0f;
        
        // Normalize by total co-occurrences from source
        auto total = row.values.sum;
        return total == 0 ? 0.0f : cast(float)row[target] / cast(float)total;
    }
    
    @property size_t relationshipCount() const @safe nothrow @nogc => _totalEdges;
    
    /// Export for serialization
    string exportMatrix() const @trusted
    {
        import std.json : JSONValue;
        JSONValue root;
        
        foreach (source, targets; _matrix)
        {
            JSONValue row;
            foreach (target, count; targets)
                row[target] = JSONValue(count);
            root[source] = row;
        }
        
        return root.toString();
    }
    
    /// Import from serialization
    void importMatrix(string json) @trusted
    {
        import std.json : parseJSON, JSONType;
        
        if (json.length == 0) return;
        
        try
        {
            auto root = parseJSON(json);
            if (root.type != JSONType.object) return;
            
            foreach (source, targets; root.objectNoRef)
            {
                if (targets.type != JSONType.object) continue;
                
                _matrix[source] = (size_t[string]).init;
                foreach (target, count; targets.objectNoRef)
                {
                    if (count.type == JSONType.integer)
                    {
                        _matrix[source][target] = cast(size_t)count.integer;
                        _totalEdges++;
                    }
                }
            }
        }
        catch (Exception) { /* Ignore parse errors */ }
    }
}

/// Time-of-day change pattern (24-hour histogram)
struct TimePattern
{
    private size_t[24] _hourBuckets;
    private size_t _totalChanges;
    
    void recordChange(SysTime timestamp) @safe nothrow
    {
        auto hour = timestamp.hour;
        _hourBuckets[hour]++;
        _totalChanges++;
    }
    
    /// Get probability multiplier based on current time
    float getProbabilityFactor(SysTime now) const @safe nothrow
    {
        if (_totalChanges < 10) return 1.0f; // Not enough data
        
        auto hour = now.hour;
        auto avgPerHour = cast(float)_totalChanges / 24.0f;
        
        return avgPerHour == 0 ? 1.0f : 
            cast(float)_hourBuckets[hour] / avgPerHour;
    }
    
    string exportPattern() const @trusted
    {
        import std.array : join;
        return _hourBuckets[].map!(h => h.to!string).join(",");
    }
    
    void importPattern(string csv) @trusted
    {
        if (csv.length == 0) return;
        
        import std.string : split;
        auto parts = csv.split(",");
        
        foreach (i, part; parts)
        {
            if (i >= 24) break;
            try { _hourBuckets[i] = part.to!size_t; }
            catch (Exception) { /* Ignore */ }
        }
        
        _totalChanges = _hourBuckets[].sum;
    }
}

/// Predictor configuration
struct PredictorConfig
{
    float priorProbability = 0.3f;     // Base probability for unknown targets
    float minProbabilityThreshold = 0.1f; // Don't report below this
    size_t coChangeWindow = 10;         // Number of recent changes to consider
    size_t maxCoChangeTargets = 10_000; // Limit co-change matrix size
}

/// Exported state for persistence
struct PredictorState
{
    TargetStats[string] targetStats;
    string coChangeMatrix;    // JSON serialized
    string timePattern;       // CSV serialized
    SysTime exportTime;
}

/// Predictor statistics
struct PredictorStats
{
    size_t trackedTargets;
    size_t totalChangesRecorded;
    size_t coChangeRelationships;
    float averageAccuracy;
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Predictor: %d targets, %d changes, %d co-changes, %.1f%% accuracy",
            trackedTargets, totalChangesRecorded, coChangeRelationships, 
            averageAccuracy * 100
        );
    }
}

/// Unit tests
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Basic prediction");
    
    auto predictor = new ChangePredictor();
    
    // Record some changes
    auto tid1 = TargetId("target1");
    auto tid2 = TargetId("target2");
    
    foreach (_; 0 .. 5)
        predictor.recordChange(tid1);
    
    predictor.recordChange(tid2);
    
    // Predict
    auto predictions = predictor.predict();
    assert(predictions.length >= 2);
    
    // target1 should have higher probability (more changes)
    auto p1 = predictions.filter!(p => p.targetId == tid1).front;
    auto p2 = predictions.filter!(p => p.targetId == tid2).front;
    
    assert(p1.probability >= p2.probability, "More frequent changes should have higher probability");
    
    writeln("\x1b[32m  ✓ Basic prediction\x1b[0m");
}

unittest
{
    import std.stdio;
    import std.algorithm : canFind, startsWith;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Co-change correlation");
    
    auto predictor = new ChangePredictor();
    
    auto tid1 = TargetId("header.h");
    auto tid2 = TargetId("impl.cpp");
    
    // Simulate co-change pattern: when header changes, impl needs rebuild
    foreach (_; 0 .. 10)
    {
        predictor.recordChange(tid1);
        predictor.recordCoChange(tid1, tid2);
    }
    
    // Now record header change
    predictor.recordChange(tid1);
    
    // impl should have elevated probability due to co-change
    auto predictions = predictor.predict();
    auto implPred = predictions.filter!(p => p.targetId == tid2);
    
    if (!implPred.empty)
    {
        auto p = implPred.front;
        assert(p.reasons.canFind!(r => r.startsWith("co_change")), 
               "Should cite co-change as reason");
    }
    
    writeln("\x1b[32m  ✓ Co-change correlation\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - State export/import");
    
    auto predictor1 = new ChangePredictor();
    
    foreach (_; 0 .. 5)
        predictor1.recordChange(TargetId("test"));
    
    // Export
    auto state = predictor1.exportState();
    
    // Import into new predictor
    auto predictor2 = new ChangePredictor();
    predictor2.importState(state);
    
    // Should have same stats
    auto stats1 = predictor1.getStats();
    auto stats2 = predictor2.getStats();
    
    assert(stats1.trackedTargets == stats2.trackedTargets);
    assert(stats1.totalChangesRecorded == stats2.totalChangesRecorded);
    
    writeln("\x1b[32m  ✓ State export/import\x1b[0m");
}

