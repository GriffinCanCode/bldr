module infrastructure.telemetry.analytics.analysis;

import std.datetime : Duration, dur;
import std.algorithm : sum, map, sort, maxElement, minElement, filter;
import std.range : array, empty, walkLength;
import std.math : sqrt;
import infrastructure.telemetry.collection.collector;
import infrastructure.errors;

/// Analyzes telemetry data to extract insights and trends
struct TelemetryAnalyzer
{
    private BuildSession[] sessions;
    
    this(BuildSession[] sessions) pure @system
    {
        this.sessions = sessions;
    }
    
    /// Generate comprehensive analytics report
    Result!(AnalyticsReport, TelemetryError) analyze() const pure @system
    {
        if (sessions.empty)
            return Result!(AnalyticsReport, TelemetryError).err(
                TelemetryError.invalidData("No sessions available for analysis")
            );
        
        AnalyticsReport report;
        
        report.totalBuilds = sessions.length;
        report.successfulBuilds = sessions.filter!(s => s.succeeded).walkLength;
        report.failedBuilds = report.totalBuilds - report.successfulBuilds;
        report.successRate = (report.successfulBuilds * 100.0) / report.totalBuilds;
        
        // Calculate average metrics
        report.avgBuildTime = calculateAverageDuration();
        report.avgCacheHitRate = calculateAverageCacheHitRate();
        report.avgParallelism = calculateAverageParallelism();
        report.avgTargetsPerSecond = calculateAverageTargetsPerSecond();
        
        // Find extremes
        report.fastestBuild = findFastestBuild();
        report.slowestBuild = findSlowestBuild();
        
        // Identify bottlenecks
        report.bottlenecks = identifyBottlenecks();
        
        // Calculate trends
        report.buildTimeTrend = calculateBuildTimeTrend();
        report.cacheEfficiencyTrend = calculateCacheEfficiencyTrend();
        
        return Result!(AnalyticsReport, TelemetryError).ok(report);
    }
    
    /// Get target-specific analytics
    Result!(TargetAnalytics, TelemetryError) analyzeTarget(string targetId) const pure @system
    {
        TargetAnalytics analytics;
        analytics.targetId = targetId;
        
        Duration[] durations;
        size_t successCount;
        size_t failureCount;
        size_t cacheCount;
        
        foreach (session; sessions)
        {
            if (auto target = targetId in session.targets)
            {
                durations ~= target.duration;
                
                final switch (target.status)
                {
                    case TargetStatus.Completed:
                        successCount++;
                        break;
                    case TargetStatus.Failed:
                        failureCount++;
                        break;
                    case TargetStatus.Cached:
                        cacheCount++;
                        break;
                    case TargetStatus.Pending:
                        break;
                }
            }
        }
        
        if (durations.empty)
            return Result!(TargetAnalytics, TelemetryError).err(
                TelemetryError.invalidData("No data for target: " ~ targetId)
            );
        
        analytics.totalBuilds = durations.length;
        analytics.successCount = successCount;
        analytics.failureCount = failureCount;
        analytics.cacheCount = cacheCount;
        analytics.avgDuration = calculateMean(durations);
        analytics.minDuration = durations.minElement;
        analytics.maxDuration = durations.maxElement;
        analytics.stdDeviation = calculateStdDev(durations);
        
        return Result!(TargetAnalytics, TelemetryError).ok(analytics);
    }
    
    /// Detect performance regressions
    Result!(Regression[], TelemetryError) detectRegressions(double threshold = 1.5) const pure @system
    {
        if (sessions.length < 2)
            return Result!(Regression[], TelemetryError).ok([]);
        
        Regression[] regressions;
        
        // Compare recent builds against historical average
        immutable recentCount = sessions.length >= 10 ? 3 : 1;
        const recent = sessions[$ - recentCount .. $];
        const historical = sessions[0 .. $ - recentCount];
        
        immutable historicalAvg = calculateMean(
            historical.map!(s => s.totalDuration).array.dup
        );
        
        foreach (session; recent)
        {
            immutable ratio = session.totalDuration.total!"msecs" / 
                            cast(double)historicalAvg.total!"msecs";
            
            if (ratio >= threshold)
            {
                Regression reg;
                reg.sessionTime = session.startTime;
                reg.expectedDuration = historicalAvg;
                reg.actualDuration = session.totalDuration;
                reg.slowdownRatio = ratio;
                regressions ~= reg;
            }
        }
        
        return Result!(Regression[], TelemetryError).ok(regressions);
    }
    
    private Duration calculateAverageDuration() const pure @system
    {
        return calculateMean(sessions.map!(s => s.totalDuration).array.dup);
    }
    
    private double calculateAverageCacheHitRate() const pure @system
    {
        if (sessions.empty)
            return 0.0;
        
        return sessions.map!(s => s.cacheHitRate).sum / sessions.length;
    }
    
    private double calculateAverageParallelism() const pure @system
    {
        if (sessions.empty)
            return 0.0;
        
        return sessions.map!(s => s.parallelismUtilization).sum / sessions.length;
    }
    
    private double calculateAverageTargetsPerSecond() const pure @system
    {
        if (sessions.empty)
            return 0.0;
        
        return sessions.map!(s => s.targetsPerSecond).sum / sessions.length;
    }
    
    private Duration findFastestBuild() const pure @system
    {
        if (sessions.empty)
            return dur!"msecs"(0);
        
        return sessions.map!(s => s.totalDuration).array.minElement;
    }
    
    private Duration findSlowestBuild() const pure @system
    {
        if (sessions.empty)
            return dur!"msecs"(0);
        
        return sessions.map!(s => s.totalDuration).array.maxElement;
    }
    
    private string[] identifyBottlenecks() const pure @system
    {
        import std.typecons : Tuple, tuple;
        
        // Aggregate target durations across all sessions
        Duration[string] totalDurations;
        size_t[string] counts;
        
        foreach (session; sessions)
        {
            foreach (targetId, target; session.targets)
            {
                if (target.status == TargetStatus.Completed)
                {
                    totalDurations[targetId] = totalDurations.get(targetId, dur!"msecs"(0)) + target.duration;
                    counts[targetId] = counts.get(targetId, 0) + 1;
                }
            }
        }
        
        // Calculate averages and find slowest
        Tuple!(string, long)[] avgDurations;
        foreach (targetId, total; totalDurations)
        {
            immutable count = counts[targetId];
            if (count > 0)
            {
                auto avg = cast(long)(total.total!"msecs" / count);
                avgDurations ~= tuple(targetId, avg);
            }
        }
        
        avgDurations.sort!((a, b) => a[1] > b[1]);
        
        // Return top 5 bottlenecks
        immutable limit = avgDurations.length < 5 ? avgDurations.length : 5;
        return avgDurations[0 .. limit].map!(t => t[0]).array;
    }
    
    private TrendDirection calculateBuildTimeTrend() const pure @system
    {
        if (sessions.length < 2)
            return TrendDirection.Stable;
        
        // Simple linear regression on build times
        const firstHalf = sessions[0 .. $ / 2];
        const secondHalf = sessions[$ / 2 .. $];
        
        immutable avgFirst = calculateMean(firstHalf.map!(s => s.totalDuration).array.dup);
        immutable avgSecond = calculateMean(secondHalf.map!(s => s.totalDuration).array.dup);
        
        immutable change = (avgSecond.total!"msecs" - avgFirst.total!"msecs") / 
                          cast(double)avgFirst.total!"msecs";
        
        if (change > 0.1) return TrendDirection.Increasing;
        if (change < -0.1) return TrendDirection.Decreasing;
        return TrendDirection.Stable;
    }
    
    private TrendDirection calculateCacheEfficiencyTrend() const pure @system
    {
        if (sessions.length < 2)
            return TrendDirection.Stable;
        
        const firstHalf = sessions[0 .. $ / 2];
        const secondHalf = sessions[$ / 2 .. $];
        
        immutable avgFirst = firstHalf.map!(s => s.cacheHitRate).sum / firstHalf.length;
        immutable avgSecond = secondHalf.map!(s => s.cacheHitRate).sum / secondHalf.length;
        
        immutable change = (avgSecond - avgFirst) / avgFirst;
        
        if (change > 0.1) return TrendDirection.Increasing;
        if (change < -0.1) return TrendDirection.Decreasing;
        return TrendDirection.Stable;
    }
    
    private static Duration calculateMean(Duration[] values) pure @system
    {
        if (values.empty)
            return dur!"msecs"(0);
        
        immutable total = values.map!(d => d.total!"msecs").sum;
        return dur!"msecs"(total / values.length);
    }
    
    private static Duration calculateStdDev(Duration[] values) pure @system
    {
        if (values.length < 2)
            return dur!"msecs"(0);
        
        immutable mean = calculateMean(values);
        immutable meanMs = mean.total!"msecs";
        
        immutable variance = values
            .map!(d => d.total!"msecs" - meanMs)
            .map!(diff => diff * diff)
            .sum / values.length;
        
        return dur!"msecs"(cast(long)sqrt(cast(double)variance));
    }
}

/// Comprehensive analytics report
struct AnalyticsReport
{
    size_t totalBuilds;
    size_t successfulBuilds;
    size_t failedBuilds;
    double successRate;
    
    Duration avgBuildTime;
    double avgCacheHitRate;
    double avgParallelism;
    double avgTargetsPerSecond;
    
    Duration fastestBuild;
    Duration slowestBuild;
    
    string[] bottlenecks;
    
    TrendDirection buildTimeTrend;
    TrendDirection cacheEfficiencyTrend;
}

/// Target-specific analytics
struct TargetAnalytics
{
    string targetId;
    size_t totalBuilds;
    size_t successCount;
    size_t failureCount;
    size_t cacheCount;
    Duration avgDuration;
    Duration minDuration;
    Duration maxDuration;
    Duration stdDeviation;
}

/// Performance regression detection
struct Regression
{
    import std.datetime : SysTime;
    
    SysTime sessionTime;
    Duration expectedDuration;
    Duration actualDuration;
    double slowdownRatio;
}

/// Trend direction indicator
enum TrendDirection
{
    Increasing,
    Stable,
    Decreasing
}

