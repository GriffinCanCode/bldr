module engine.economics.estimator;

import std.datetime : Duration, seconds, msecs;
import std.algorithm : map, sum, max;
import std.array : array;
import std.conv : to;
import engine.economics.pricing;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Build estimate (time + resource usage)
struct BuildEstimate
{
    Duration duration;
    ResourceUsageEstimate usage;
}

/// Cost estimator - predicts build time and cost from historical data
final class CostEstimator
{
    private ExecutionHistory history;
    
    this(ExecutionHistory history) @safe
    {
        this.history = history;
    }
    
    /// Estimate entire build graph
    BuildResult!BuildEstimate estimateGraph(BuildGraph graph) @trusted
    {
        try
        {
            // Sum estimates for all nodes (conservative: assume sequential)
            Duration totalTime;
            size_t totalCores, totalMemory, totalNetwork, totalDiskIO;
            
            foreach (node; graph.nodes.values)
            {
                auto nodeEstimateResult = estimateNode(node);
                if (nodeEstimateResult.isErr)
                    return Err!(BuildEstimate, BuildError)(nodeEstimateResult.unwrapErr());
                
                auto nodeEstimate = nodeEstimateResult.unwrap();
                
                totalTime += nodeEstimate.duration;
                totalCores += nodeEstimate.usage.cores;
                totalMemory = max(totalMemory, nodeEstimate.usage.memoryBytes);
                totalNetwork += nodeEstimate.usage.networkBytes;
                totalDiskIO += nodeEstimate.usage.diskIOBytes;
            }
            
            immutable avgCores = graph.nodes.length > 0 ? (totalCores / graph.nodes.length) : 4;
            
            return Ok!(BuildEstimate, BuildError)(BuildEstimate(
                totalTime,
                ResourceUsageEstimate(avgCores, totalMemory, totalNetwork, totalDiskIO, totalTime)
            ));
        }
        catch (Exception e)
        {
            return Err!(BuildEstimate, BuildError)(new EconomicsError("Failed to estimate graph: " ~ e.msg));
        }
    }
    
    /// Estimate single build node
    BuildResult!BuildEstimate estimateNode(BuildNode node) @trusted
    {
        import std.algorithm : canFind;
        
        try
        {
            // Check historical data first
            if (auto historicalData = history.lookup(node.id.toString()))
            {
                structuredLog.debug_("using_historical_data_for_").field("detail", "Using historical data for " ~ node.idString).emit();
                return Ok!(BuildEstimate, BuildError)(historicalData.estimate);
            }
            
            // Base estimates by language/type (heuristics)
            immutable language = node.target.language.to!string;
            immutable GB = 1024 * 1024 * 1024;
            immutable MB = 1024 * 1024;
            
            BuildEstimate estimate;
            
            if (canFind(["C", "C++", "Cpp"], language))
                estimate = BuildEstimate(seconds(30), ResourceUsageEstimate(4, 2*GB, 10*MB, 100*MB, seconds(30)));
            else if (canFind(["Rust", "Go"], language))
                estimate = BuildEstimate(seconds(15), ResourceUsageEstimate(4, GB, 5*MB, 50*MB, seconds(15)));
            else if (canFind(["Python", "JavaScript", "TypeScript"], language))
                estimate = BuildEstimate(seconds(5), ResourceUsageEstimate(2, 512*MB, 2*MB, 20*MB, seconds(5)));
            else if (language == "D")
                estimate = BuildEstimate(seconds(10), ResourceUsageEstimate(4, GB, 5*MB, 50*MB, seconds(10)));
            else
                estimate = BuildEstimate(seconds(10), ResourceUsageEstimate(2, GB, 5*MB, 50*MB, seconds(10)));
            
            // Adjust based on source count
            immutable sourceCount = node.target.sources.length;
            if (sourceCount > 10)
            {
                immutable scaleFactor = 1.0f + (sourceCount - 10) * 0.1f;
                estimate.duration = msecs(cast(long)(estimate.duration.total!"msecs" * scaleFactor));
                estimate.usage.duration = estimate.duration;
            }
            
            return Ok!(BuildEstimate, BuildError)(estimate);
        }
        catch (Exception e)
        {
            return Err!(BuildEstimate, BuildError)(new EconomicsError("Failed to estimate node: " ~ e.msg));
        }
    }
    
    /// Estimate cache hit probability for graph
    float estimateCacheHitProbability(BuildGraph graph) @trusted
    {
        if (graph.nodes.length == 0) return 0.0f;
        
        float totalProb = 0.0f;
        foreach (node; graph.nodes.values)
            totalProb += estimateCacheHitProbabilityForNode(node);
        
        return totalProb / graph.nodes.length;
    }
    
    /// Estimate cache hit probability for single node
    float estimateCacheHitProbabilityForNode(BuildNode node) @trusted
    {
        if (auto hist = history.lookup(node.id.toString()))
            return hist.cacheHitRate;
        
        // Heuristic: stable dependencies have high cache hit rate, frequently changing code has low cache hit rate
        return node.dependencyIds.length == 0 ? 0.1f : 0.3f;
    }
}

/// Execution history tracking
final class ExecutionHistory
{
    private HistoryEntry[string] entries;
    
    /// Record execution
    void record(string targetId, Duration duration, ResourceUsageEstimate usage, bool cacheHit) @trusted
    {
        if (auto entry = targetId in entries)
            entry.update(duration, usage, cacheHit);
        else
            entries[targetId] = HistoryEntry(duration, usage, cacheHit);
    }
    
    /// Lookup historical estimate
    const(HistoryEntry)* lookup(string targetId) @trusted
    {
        if (auto entry = targetId in entries)
            return entry;
        return null;
    }
    
    /// Clear history
    void clear() @trusted => entries.clear();
    
    /// Export to JSON for persistence
    string toJson() const @trusted
    {
        import std.format : format;
        import std.array : join;
        
        string[] jsonEntries;
        
        foreach (targetId, entry; entries)
        {
            jsonEntries ~= format(
                `{"target":"%s","duration":%d,"cores":%d,"memory":%d,"network":%d,"diskIO":%d,"cacheHitRate":%.3f,"execCount":%d}`,
                targetId,
                entry.estimate.duration.total!"msecs",
                entry.estimate.usage.cores,
                entry.estimate.usage.memoryBytes,
                entry.estimate.usage.networkBytes,
                entry.estimate.usage.diskIOBytes,
                entry.cacheHitRate,
                entry.executionCount
            );
        }
        
        return "[" ~ jsonEntries.join(",") ~ "]";
    }
    
    /// Import from JSON
    static ExecutionHistory fromJson(string json) @trusted
    {
        import std.json : parseJSON, JSONValue, JSONType, JSONException;
        import std.datetime : msecs;
        
        auto history = new ExecutionHistory();
        
        try
        {
            JSONValue root = parseJSON(json);
            
            if (root.type != JSONType.array)
                return history;
            
            foreach (item; root.array)
            {
                if (item.type != JSONType.object)
                    continue;
                
                // Extract fields
                string targetId = item["target"].str;
                long durationMs = item["duration"].integer;
                int cores = cast(int)item["cores"].integer;
                ulong memory = cast(ulong)item["memory"].integer;
                ulong network = cast(ulong)item["network"].integer;
                ulong diskIO = cast(ulong)item["diskIO"].integer;
                float cacheHitRate = cast(float)item["cacheHitRate"].floating;
                size_t execCount = cast(size_t)item["execCount"].integer;
                
                // Reconstruct entry
                ResourceUsageEstimate usage;
                usage.cores = cores;
                usage.memoryBytes = memory;
                usage.networkBytes = network;
                usage.diskIOBytes = diskIO;
                
                HistoryEntry entry;
                entry.estimate.duration = msecs(durationMs);
                entry.estimate.usage = usage;
                entry.cacheHitRate = cacheHitRate;
                entry.executionCount = execCount;
                
                history.entries[targetId] = entry;
            }
        }
        catch (JSONException e)
        {
            // Return empty history on parse failure
            import infrastructure.utils.logging;
            structuredLog.warning("failed_to_parse_execution_history_json_").field("detail", "Failed to parse execution history JSON: " ~ e.msg).emit();
        }
        
        return history;
    }
}

/// Historical entry for a target
private struct HistoryEntry
{
    BuildEstimate estimate;
    float cacheHitRate = 0.0f;
    size_t executionCount = 0;
    
    private enum float ALPHA = 0.3f;  // Exponential moving average weight
    
    this(Duration duration, ResourceUsageEstimate usage, bool cacheHit) pure @safe nothrow @nogc
    {
        estimate.duration = duration;
        estimate.usage = usage;
        cacheHitRate = cacheHit ? 1.0f : 0.0f;
        executionCount = 1;
    }
    
    /// Update with new execution data (exponential moving average)
    void update(Duration duration, ResourceUsageEstimate usage, bool cacheHit) @safe nothrow @nogc
    {
        immutable BETA = 1.0f - ALPHA;
        
        estimate.duration = msecs(cast(long)(estimate.duration.total!"msecs" * BETA + duration.total!"msecs" * ALPHA));
        estimate.usage.cores = cast(size_t)(estimate.usage.cores * BETA + usage.cores * ALPHA);
        estimate.usage.memoryBytes = cast(size_t)(estimate.usage.memoryBytes * BETA + usage.memoryBytes * ALPHA);
        estimate.usage.networkBytes = cast(size_t)(estimate.usage.networkBytes * BETA + usage.networkBytes * ALPHA);
        estimate.usage.diskIOBytes = cast(size_t)(estimate.usage.diskIOBytes * BETA + usage.diskIOBytes * ALPHA);
        estimate.usage.duration = estimate.duration;
        
        cacheHitRate = cacheHitRate * BETA + (cacheHit ? 1.0f : 0.0f) * ALPHA;
        executionCount++;
    }
}

/// Re-export EconomicsError
public import engine.economics.optimizer : EconomicsError;
