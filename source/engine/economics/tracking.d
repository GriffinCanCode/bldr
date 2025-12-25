module engine.economics.tracking;

import std.datetime : Duration, Clock, SysTime;
import std.conv : to;
import std.file : exists, readText, write;
import std.path : buildPath;
import engine.economics.pricing;
import engine.economics.estimator;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Cost tracking for builds
/// Records actual costs and compares to estimates
final class CostTracker
{
    private ExecutionHistory history;
    private string cacheDir;
    private ActualCost[] costs;
    
    this(ExecutionHistory history, string cacheDir) @safe
    {
        this.history = history;
        this.cacheDir = cacheDir;
    }
    
    /// Track build execution
    void trackExecution(string targetId, Duration duration, ResourceUsageEstimate usage,
                       float actualCost, bool cacheHit) @trusted
    {
        history.record(targetId, duration, usage, cacheHit);
        costs ~= ActualCost(targetId, Clock.currTime, duration, actualCost, cacheHit);
        Logger.debugLog("Tracked execution: " ~ targetId ~ " (" ~ formatDuration(duration) ~ 
                       ", " ~ formatCost(actualCost) ~ ")");
    }
    
    /// Get total costs for current session
    CostSummary getSummary() const pure @safe nothrow @nogc
    {
        CostSummary summary;
        foreach (cost; costs)
        {
            summary.totalCost += cost.cost;
            summary.totalTime += cost.duration;
            summary.executionCount++;
            if (cost.cacheHit) summary.cacheHits++;
        }
        return summary;
    }
    
    /// Save history to disk
    VoidBuildResult save() @trusted
    {
        try
        {
            immutable historyPath = buildPath(cacheDir, "execution-history.json");
            immutable json = history.toJson();
            write(historyPath, json);
            Logger.debugLog("Saved execution history to " ~ historyPath);
            return Ok!BuildError();
        }
        catch (Exception e)
        {
            BuildError error = new EconomicsError("Failed to save history: " ~ e.msg);
            return VoidBuildResult.err(error);
        }
    }
    
    /// Load history from disk
    VoidBuildResult load() @trusted
    {
        try
        {
            immutable historyPath = buildPath(cacheDir, "execution-history.json");
            
            if (!exists(historyPath))
            {
                Logger.debugLog("No execution history found");
                return Ok!BuildError();
            }
            
            immutable json = readText(historyPath);
            
            // Deserialize execution history from JSON
            import engine.economics.estimator : ExecutionHistory;
            this.history = ExecutionHistory.fromJson(json);
            
            Logger.debugLog("Loaded execution history from " ~ historyPath);
            return Ok!BuildError();
        }
        catch (Exception e)
        {
            Logger.warning("Failed to load history: " ~ e.msg);
            return Ok!BuildError();  // Non-fatal
        }
    }
}

/// Cost summary for reporting
struct CostSummary
{
    float totalCost = 0.0f;
    Duration totalTime;
    size_t executionCount = 0;
    size_t cacheHits = 0;
    
    /// Cache hit rate
    float cacheHitRate() const pure @safe nothrow @nogc =>
        executionCount > 0 ? cast(float)cacheHits / executionCount : 0.0f;
    
    /// Average cost per execution
    float avgCost() const pure @safe nothrow @nogc =>
        executionCount > 0 ? totalCost / executionCount : 0.0f;
    
    /// Format for display
    string format() const @safe
    {
        import std.format : format;
        
        return format(
            "Build Cost Summary:\n" ~
            "  Total Cost:   %s\n" ~
            "  Total Time:   %s\n" ~
            "  Executions:   %d\n" ~
            "  Cache Hits:   %d (%.1f%%)\n" ~
            "  Avg Cost:     %s",
            formatCost(totalCost),
            formatDuration(totalTime),
            executionCount,
            cacheHits,
            cacheHitRate() * 100.0f,
            formatCost(avgCost())
        );
    }
}

/// Actual cost record
private struct ActualCost
{
    string targetId;
    SysTime timestamp;
    Duration duration;
    float cost;
    bool cacheHit;
}

/// Format duration for display
private string formatDuration(Duration d) pure @safe
{
    immutable totalSeconds = d.total!"seconds";
    if (totalSeconds < 60) return totalSeconds.to!string ~ "s";
    if (totalSeconds < 3600) return (totalSeconds / 60).to!string ~ "m " ~ (totalSeconds % 60).to!string ~ "s";
    return (totalSeconds / 3600).to!string ~ "h " ~ ((totalSeconds % 3600) / 60).to!string ~ "m";
}

// ==================== Worker Startup Savings ====================

/// Worker startup savings tracking
/// Integrates persistent worker pool economics with build cost tracking
struct WorkerStartupSavings
{
    long jvmSavedMs;      /// Milliseconds saved from warm JVM workers
    long goSavedMs;       /// Milliseconds saved from warm Go workers  
    long pythonSavedMs;   /// Milliseconds saved from warm Python workers
    size_t warmExecutions;
    size_t coldFallbacks;
    
    /// Total time saved from persistent workers
    long totalSavedMs() const pure nothrow @safe @nogc =>
        jvmSavedMs + goSavedMs + pythonSavedMs;
    
    /// Estimated cost savings (assuming $0.05/core-minute)
    float estimatedCostSavings() const pure nothrow @safe @nogc =>
        (totalSavedMs() / 60_000.0f) * 0.05f;
    
    /// Format for display
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Worker Startup Savings:\n" ~
            "  JVM (Java/Kotlin/Scala): %.1fs\n" ~
            "  Go: %.1fs\n" ~
            "  Python (mypy/ruff): %.1fs\n" ~
            "  Warm executions: %d\n" ~
            "  Cold fallbacks: %d\n" ~
            "  Est. cost savings: $%.2f",
            jvmSavedMs / 1000.0,
            goSavedMs / 1000.0,
            pythonSavedMs / 1000.0,
            warmExecutions,
            coldFallbacks,
            estimatedCostSavings()
        );
    }
}

/// Track worker startup savings
/// Call this from persistent worker pool after execution
void trackWorkerSavings(
    ref WorkerStartupSavings savings,
    string workerType,
    bool usedWarm,
    long savedMs
) @safe
{
    if (usedWarm)
    {
        savings.warmExecutions++;
        if (workerType.canFind("jvm"))
            savings.jvmSavedMs += savedMs;
        else if (workerType.canFind("go"))
            savings.goSavedMs += savedMs;
        else if (workerType.canFind("python"))
            savings.pythonSavedMs += savedMs;
    }
    else
    {
        savings.coldFallbacks++;
    }
}

private bool canFind(string haystack, string needle) pure nothrow @safe @nogc
{
    if (needle.length > haystack.length) return false;
    
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return true;
    
    return false;
}

