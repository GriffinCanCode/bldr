module engine.runtime.services.speculation.history;

import std.algorithm : map, filter, sort, sum, min, max;
import std.array : array, join;
import std.datetime : Duration, msecs, seconds, hours, SysTime, Clock;
import std.math : abs;
import std.conv : to;
import std.file : exists, mkdirRecurse, write, readText, remove;
import std.path : buildPath;
import std.json : JSONValue, parseJSON, JSONType, JSONException;
import core.sync.mutex : Mutex;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.utils.logging;
import infrastructure.errors;
import engine.runtime.services.speculation.predictor : PredictorState, TargetStats;

/// Change event record
struct ChangeEvent
{
    TargetId targetId;
    SysTime timestamp;
    ChangeType changeType;
    string[] affectedFiles;
    Duration buildDuration;
    bool wasSpeculated;       // Was this speculatively built?
    bool speculationValid;    // If speculated, was it valid?
}

/// Type of change
enum ChangeType : ubyte
{
    SourceModified,    // Source file changed
    DependencyChanged, // Dependency output changed
    ConfigChanged,     // Build config changed
    Manual,            // Forced rebuild
    Unknown
}

/// Session information for tracking developer patterns
struct BuildSession
{
    SysTime startTime;
    SysTime endTime;
    size_t changesCount;
    size_t successfulBuilds;
    size_t failedBuilds;
    size_t speculativeHits;
    size_t speculativeMisses;
    
    @property Duration duration() const @safe nothrow
    {
        return endTime - startTime;
    }
    
    @property float speculationHitRate() const pure nothrow @nogc
    {
        auto total = speculativeHits + speculativeMisses;
        return total == 0 ? 0.0f : cast(float)speculativeHits / cast(float)total;
    }
}

/// History tracker - persists and analyzes change patterns
/// Feeds the ChangePredictor with historical data for learning
final class HistoryTracker
{
    package string _cacheDir;  // Package-visible for service integration
    private Mutex _mutex;
    
    // In-memory state
    private ChangeEvent[] _recentEvents;
    private BuildSession _currentSession;
    private PredictorState _predictorState;
    
    // Configuration
    private HistoryConfig _config;
    
    // Statistics
    private HistoryStats _stats;
    
    this(string cacheDir = ".builder-cache/speculation", HistoryConfig config = HistoryConfig.init) @trusted
    {
        _cacheDir = cacheDir;
        _config = config;
        _mutex = new Mutex();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        _currentSession.startTime = Clock.currTime();
        
        load();
    }
    
    /// Record a change event
    void recordChange(
        TargetId targetId,
        ChangeType changeType,
        string[] affectedFiles = [],
        Duration buildDuration = Duration.zero,
        bool wasSpeculated = false,
        bool speculationValid = false
    ) @trusted
    {
        synchronized (_mutex)
        {
            ChangeEvent event;
            event.targetId = targetId;
            event.timestamp = Clock.currTime();
            event.changeType = changeType;
            event.affectedFiles = affectedFiles.dup;
            event.buildDuration = buildDuration;
            event.wasSpeculated = wasSpeculated;
            event.speculationValid = speculationValid;
            
            _recentEvents ~= event;
            _currentSession.changesCount++;
            
            // Update statistics
            _stats.totalChanges++;
            if (wasSpeculated)
            {
                if (speculationValid)
                {
                    _currentSession.speculativeHits++;
                    _stats.speculativeHits++;
                }
                else
                {
                    _currentSession.speculativeMisses++;
                    _stats.speculativeMisses++;
                }
            }
            
            // Update predictor state
            updatePredictorState(event);
            
            // Trim events if over limit
            if (_recentEvents.length > _config.maxRecentEvents)
                _recentEvents = _recentEvents[$ - _config.maxRecentEvents .. $];
            
            // Auto-save periodically
            if (_stats.totalChanges % _config.saveInterval == 0)
                save();
        }
    }
    
    /// Record a successful build
    void recordBuildSuccess(TargetId targetId, Duration duration) @trusted
    {
        synchronized (_mutex)
        {
            _currentSession.successfulBuilds++;
            _stats.totalBuilds++;
            
            auto key = targetId.toString();
            if (key !in _predictorState.targetStats)
                _predictorState.targetStats[key] = TargetStats.init;
        }
    }
    
    /// Record a failed build
    void recordBuildFailure(TargetId targetId, string error) @trusted
    {
        synchronized (_mutex)
        {
            _currentSession.failedBuilds++;
            _stats.totalBuilds++;
        }
    }
    
    /// Get predictor state for the ChangePredictor
    PredictorState getPredictorState() @trusted
    {
        synchronized (_mutex)
        {
            return _predictorState;
        }
    }
    
    /// Update predictor state from external source
    void updatePredictorState(PredictorState state) @trusted
    {
        synchronized (_mutex)
        {
            _predictorState = state;
        }
    }
    
    /// Get recent events (for analysis)
    ChangeEvent[] getRecentEvents(size_t maxCount = 100) @trusted
    {
        synchronized (_mutex)
        {
            auto count = min(maxCount, _recentEvents.length);
            return _recentEvents[$ - count .. $].dup;
        }
    }
    
    /// Get current session info
    BuildSession getCurrentSession() @trusted
    {
        synchronized (_mutex)
        {
            _currentSession.endTime = Clock.currTime();
            return _currentSession;
        }
    }
    
    /// Get historical statistics
    HistoryStats getStats() @trusted
    {
        synchronized (_mutex)
        {
            return _stats;
        }
    }
    
    /// Analyze change patterns to find correlations
    ChangeCorrelation[] analyzeCorrelations(size_t minOccurrences = 3) @trusted
    {
        synchronized (_mutex)
        {
            // Build co-occurrence matrix
            size_t[string][string] coOccurrence;
            
            for (size_t i = 0; i < _recentEvents.length; i++)
            {
                auto event = _recentEvents[i];
                auto key = event.targetId.toString();
                
                // Look at nearby events (within time window)
                foreach (j; max(0, cast(long)i - 10) .. min(_recentEvents.length, i + 10))
                {
                    if (i == j) continue;
                    
                    auto other = _recentEvents[j];
                    auto elapsed = event.timestamp - other.timestamp;
                    
                    import std.math : abs;
                    if (abs(elapsed.total!"minutes") < 30)
                    {
                        auto otherKey = other.targetId.toString();
                        if (key !in coOccurrence)
                            coOccurrence[key] = (size_t[string]).init;
                        
                        if (otherKey !in coOccurrence[key])
                            coOccurrence[key][otherKey] = 0;
                        
                        coOccurrence[key][otherKey]++;
                    }
                }
            }
            
            // Extract significant correlations
            ChangeCorrelation[] correlations;
            
            foreach (source, targets; coOccurrence)
            {
                foreach (target, count; targets)
                {
                    if (count >= minOccurrences)
                    {
                        correlations ~= ChangeCorrelation(
                            TargetId(source),
                            TargetId(target),
                            count,
                            cast(float)count / cast(float)_recentEvents.length
                        );
                    }
                }
            }
            
            correlations.sort!((a, b) => a.count > b.count);
            return correlations;
        }
    }
    
    /// Flush to disk
    void flush() @trusted
    {
        synchronized (_mutex)
        {
            save();
        }
    }
    
    /// End current session and start new one
    void endSession() @trusted
    {
        synchronized (_mutex)
        {
            _currentSession.endTime = Clock.currTime();
            save();
            
            // Start new session
            _currentSession = BuildSession.init;
            _currentSession.startTime = Clock.currTime();
        }
    }
    
    /// Clear all history
    void clear() @trusted
    {
        synchronized (_mutex)
        {
            _recentEvents = [];
            _predictorState = PredictorState.init;
            _stats = HistoryStats.init;
            
            auto historyFile = buildPath(_cacheDir, "history.json");
            if (exists(historyFile))
                remove(historyFile);
        }
    }
    
private:
    /// Update predictor state from change event
    void updatePredictorState(ref ChangeEvent event) @trusted
    {
        auto key = event.targetId.toString();
        
        if (key !in _predictorState.targetStats)
            _predictorState.targetStats[key] = TargetStats.init;
        
        _predictorState.targetStats[key].recordChange(event.timestamp);
        
        // Update speculation accuracy
        if (event.wasSpeculated)
            _predictorState.targetStats[key].recordPrediction(event.speculationValid);
    }
    
    /// Load from disk
    void load() @trusted
    {
        auto historyFile = buildPath(_cacheDir, "history.json");
        
        if (!exists(historyFile))
        {
            structuredLog.debug_("no_speculation_history_found_starting_fr").emit();
            return;
        }
        
        try
        {
            auto json = readText(historyFile);
            auto root = parseJSON(json);
            
            // Load stats
            if ("stats" in root && root["stats"].type == JSONType.object)
            {
                auto s = root["stats"];
                _stats.totalChanges = cast(size_t)s["totalChanges"].integer;
                _stats.totalBuilds = cast(size_t)s["totalBuilds"].integer;
                _stats.speculativeHits = cast(size_t)s["speculativeHits"].integer;
                _stats.speculativeMisses = cast(size_t)s["speculativeMisses"].integer;
            }
            
            // Load predictor state
            if ("predictorState" in root && root["predictorState"].type == JSONType.object)
            {
                auto ps = root["predictorState"];
                
                if ("coChangeMatrix" in ps)
                    _predictorState.coChangeMatrix = ps["coChangeMatrix"].str;
                
                if ("timePattern" in ps)
                    _predictorState.timePattern = ps["timePattern"].str;
                
                // Load target stats
                if ("targetStats" in ps && ps["targetStats"].type == JSONType.object)
                {
                    foreach (key, val; ps["targetStats"].objectNoRef)
                    {
                        if (val.type != JSONType.object) continue;
                        
                        TargetStats stats;
                        stats.changeCount = cast(size_t)val["changeCount"].integer;
                        stats.observationCount = cast(size_t)val["observationCount"].integer;
                        stats.predictionCount = cast(size_t)val["predictionCount"].integer;
                        stats.correctPredictions = cast(size_t)val["correctPredictions"].integer;
                        stats.ewmaChangeRate = cast(float)val["ewmaChangeRate"].floating;
                        
                        _predictorState.targetStats[key] = stats;
                    }
                }
            }
            
            structuredLog.debug_("loaded_speculation_history_").field("detail", "Loaded speculation history: " ~ 
                           _predictorState.targetStats.length.to!string ~ " targets").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_load_speculation_history_").field("detail", "Failed to load speculation history: " ~ e.msg).emit();
        }
    }
    
    /// Save to disk
    void save() @trusted
    {
        auto historyFile = buildPath(_cacheDir, "history.json");
        
        try
        {
            JSONValue root;
            
            // Save stats
            JSONValue stats;
            stats["totalChanges"] = JSONValue(_stats.totalChanges);
            stats["totalBuilds"] = JSONValue(_stats.totalBuilds);
            stats["speculativeHits"] = JSONValue(_stats.speculativeHits);
            stats["speculativeMisses"] = JSONValue(_stats.speculativeMisses);
            root["stats"] = stats;
            
            // Save predictor state
            JSONValue ps;
            ps["coChangeMatrix"] = JSONValue(_predictorState.coChangeMatrix);
            ps["timePattern"] = JSONValue(_predictorState.timePattern);
            
            JSONValue targetStats;
            foreach (key, ts; _predictorState.targetStats)
            {
                JSONValue tsJson;
                tsJson["changeCount"] = JSONValue(ts.changeCount);
                tsJson["observationCount"] = JSONValue(ts.observationCount);
                tsJson["predictionCount"] = JSONValue(ts.predictionCount);
                tsJson["correctPredictions"] = JSONValue(ts.correctPredictions);
                tsJson["ewmaChangeRate"] = JSONValue(ts.ewmaChangeRate);
                targetStats[key] = tsJson;
            }
            ps["targetStats"] = targetStats;
            root["predictorState"] = ps;
            
            // Save recent events (limited)
            JSONValue events;
            auto recentCount = min(100, _recentEvents.length);
            JSONValue[] eventArray;
            foreach (event; _recentEvents[$ - recentCount .. $])
            {
                JSONValue e;
                e["targetId"] = JSONValue(event.targetId.toString());
                e["timestamp"] = JSONValue(event.timestamp.toISOExtString());
                e["changeType"] = JSONValue(cast(int)event.changeType);
                e["wasSpeculated"] = JSONValue(event.wasSpeculated);
                e["speculationValid"] = JSONValue(event.speculationValid);
                eventArray ~= e;
            }
            root["recentEvents"] = JSONValue(eventArray);
            
            write(historyFile, root.toPrettyString());
            
            structuredLog.debug_("saved_speculation_history").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_save_speculation_history_").field("detail", "Failed to save speculation history: " ~ e.msg).emit();
        }
    }
}

/// Configuration for history tracking
struct HistoryConfig
{
    size_t maxRecentEvents = 10_000;  // Max events to keep in memory
    size_t saveInterval = 50;          // Save every N changes
    Duration sessionTimeout = 4.hours;
}

/// Correlation between two targets
struct ChangeCorrelation
{
    TargetId source;
    TargetId target;
    size_t count;
    float strength;
}

/// Historical statistics
struct HistoryStats
{
    size_t totalChanges;
    size_t totalBuilds;
    size_t speculativeHits;
    size_t speculativeMisses;
    
    @property float speculationAccuracy() const pure nothrow @nogc @safe
    {
        auto total = speculativeHits + speculativeMisses;
        return total == 0 ? 0.0f : cast(float)speculativeHits / cast(float)total;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "History: %d changes, %d builds, speculation %.1f%% (%d/%d)",
            totalChanges, totalBuilds, speculationAccuracy * 100,
            speculativeHits, speculativeHits + speculativeMisses
        );
    }
}

/// Unit tests
unittest
{
    import std.stdio;
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Basic recording");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto tracker = new HistoryTracker(testDir);
    
    // Record some changes
    tracker.recordChange(TargetId("target1"), ChangeType.SourceModified);
    tracker.recordChange(TargetId("target2"), ChangeType.DependencyChanged);
    tracker.recordChange(TargetId("target1"), ChangeType.SourceModified, [], Duration.zero, true, true);
    
    auto stats = tracker.getStats();
    assert(stats.totalChanges == 3);
    assert(stats.speculativeHits == 1);
    
    writeln("\x1b[32m  ✓ Basic recording\x1b[0m");
}

unittest
{
    import std.stdio;
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Persistence");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-persist");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    // Create and populate
    {
        auto tracker = new HistoryTracker(testDir);
        tracker.recordChange(TargetId("target1"), ChangeType.SourceModified);
        tracker.recordChange(TargetId("target2"), ChangeType.SourceModified);
        tracker.flush();
    }
    
    // Reload and verify
    {
        auto tracker = new HistoryTracker(testDir);
        auto state = tracker.getPredictorState();
        assert("target1" in state.targetStats);
        assert("target2" in state.targetStats);
    }
    
    writeln("\x1b[32m  ✓ Persistence\x1b[0m");
}

