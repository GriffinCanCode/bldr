module frontend.testframework.analytics.insights;

import std.algorithm : sort, map, filter, sum;
import std.array : array;
import std.range : walkLength;
import std.datetime : Duration;
import std.conv : to;
import frontend.testframework.results;
import frontend.testframework.flaky : FlakyRecord, FlakyConfidence;
import frontend.testframework.sharding : ShardEngine;

/// Test suite health metrics
struct HealthMetrics
{
    double passRate;              // Overall pass rate (0.0 - 1.0)
    double stability;             // Test stability score (0.0 - 1.0)
    double performance;           // Performance score (0.0 - 1.0)
    double coverage;              // Test coverage estimate (0.0 - 1.0)
    size_t flakyCount;            // Number of flaky tests
    size_t slowCount;             // Number of slow tests
    
    /// Get overall health score
    double overallHealth() const pure nothrow @safe @nogc
    {
        return (passRate + stability + performance) / 3.0;
    }
    
    /// Get health grade
    string grade() const pure nothrow @safe
    {
        immutable health = overallHealth();
        
        if (health >= 0.95)
            return "A+";
        else if (health >= 0.90)
            return "A";
        else if (health >= 0.85)
            return "B+";
        else if (health >= 0.80)
            return "B";
        else if (health >= 0.70)
            return "C";
        else
            return "D";
    }
}

/// Test performance insights
struct PerformanceInsights
{
    Duration totalDuration;
    Duration avgDuration;
    Duration medianDuration;
    Duration p95Duration;
    Duration p99Duration;
    
    string[] slowTests;           // Tests slower than P95
    string[] fastTests;           // Tests faster than median
    
    double parallelEfficiency;    // Parallel execution efficiency
    size_t recommendedShards;     // Recommended shard count
}

/// Test analytics engine
final class TestAnalytics
{
    /// Analyze test results
    static HealthMetrics analyzeHealth(
        TestResult[] results,
        FlakyRecord[] flakyRecords
    ) pure nothrow @safe
    {
        HealthMetrics metrics;
        
        if (results.length == 0)
            return metrics;
        
        // Calculate pass rate
        immutable passed = results.filter!(r => r.passed).walkLength;
        metrics.passRate = cast(double)passed / results.length;
        
        // Calculate stability (inverse of flakiness)
        if (flakyRecords.length > 0)
        {
            double avgFlakiness = 0.0;
            foreach (record; flakyRecords)
            {
                avgFlakiness += record.flakinessScore;
            }
            avgFlakiness /= flakyRecords.length;
            metrics.stability = 1.0 - avgFlakiness;
        }
        else
        {
            metrics.stability = 1.0;
        }
        
        // Performance score based on caching
        immutable cached = results.filter!(r => r.cached).walkLength;
        if (results.length > 0)
        {
            metrics.performance = cast(double)cached / results.length;
        }
        
        // Count flaky tests
        metrics.flakyCount = flakyRecords.filter!(r => 
            r.confidence >= FlakyConfidence.Medium).walkLength;
        
        // Count slow tests (>10s)
        metrics.slowCount = results.filter!(r => 
            r.duration.total!"seconds" > 10).walkLength;
        
        return metrics;
    }
    
    /// Analyze test performance
    static PerformanceInsights analyzePerformance(
        TestResult[] results
    ) pure @safe
    {
        PerformanceInsights insights;
        
        if (results.length == 0)
            return insights;
        
        // Sort by duration (in-place)
        auto sorted = results.map!(r => r.duration).array;
        sorted.sort();
        
        // Total duration
        insights.totalDuration = sorted.sum();
        
        // Average duration
        insights.avgDuration = insights.totalDuration / results.length;
        
        // Median duration
        insights.medianDuration = sorted[sorted.length / 2];
        
        // P95 duration
        immutable p95Idx = cast(size_t)(sorted.length * 0.95);
        if (p95Idx < sorted.length)
            insights.p95Duration = sorted[p95Idx];
        
        // P99 duration
        immutable p99Idx = cast(size_t)(sorted.length * 0.99);
        if (p99Idx < sorted.length)
            insights.p99Duration = sorted[p99Idx];
        
        // Identify slow tests
        insights.slowTests = results
            .filter!(r => r.duration > insights.p95Duration)
            .map!(r => r.targetId)
            .array;
        
        // Identify fast tests
        insights.fastTests = results
            .filter!(r => r.duration < insights.medianDuration)
            .map!(r => r.targetId)
            .array;
        
        // Estimate parallel efficiency
        if (insights.avgDuration.total!"msecs" > 0)
        {
            immutable idealParallel = insights.totalDuration / insights.avgDuration;
            immutable actualParallel = results.length;
            insights.parallelEfficiency = cast(double)idealParallel / actualParallel;
        }
        
        // Recommend shard count based on test distribution
        insights.recommendedShards = computeOptimalShards(sorted);
        
        return insights;
    }
    
    /// Compute optimal shard count
    private static size_t computeOptimalShards(Duration[] sortedDurations) pure nothrow @safe
    {
        if (sortedDurations.length < 4)
            return 2;
        
        // Use coefficient of variation to determine sharding
        immutable total = sortedDurations.sum();
        immutable avg = total / sortedDurations.length;
        
        double variance = 0.0;
        foreach (d; sortedDurations)
        {
            immutable diff = d.total!"msecs" - avg.total!"msecs";
            variance += diff * diff;
        }
        variance /= sortedDurations.length;
        
        immutable stdDev = variance ^^ 0.5;
        immutable cv = stdDev / avg.total!"msecs";
        
        // High variance -> more shards
        if (cv > 1.0)
            return 8;
        else if (cv > 0.5)
            return 6;
        else if (cv > 0.25)
            return 4;
        else
            return 2;
    }
    
    /// Generate test report summary
    static string generateReport(
        TestStats stats,
        HealthMetrics health,
        PerformanceInsights performance
    ) pure @safe
    {
        import std.format : format;
        
        string report;
        
        report ~= "═══════════════════════════════════════════\n";
        report ~= "           TEST ANALYTICS REPORT            \n";
        report ~= "═══════════════════════════════════════════\n\n";
        
        // Overall Summary
        report ~= "OVERALL HEALTH: " ~ health.grade() ~ " (" ~ 
            format("%.1f", health.overallHealth() * 100) ~ "%)\n\n";
        
        // Test Results
        report ~= "Test Results:\n";
        report ~= format("  Total tests:     %d\n", stats.totalTargets);
        report ~= format("  Passed:          %d (%.1f%%)\n", 
            stats.passedTargets, health.passRate * 100);
        report ~= format("  Failed:          %d\n", stats.failedTargets);
        report ~= format("  From cache:      %d\n\n", stats.cachedTargets);
        
        // Health Metrics
        report ~= "Health Metrics:\n";
        report ~= format("  Pass rate:       %.1f%%\n", health.passRate * 100);
        report ~= format("  Stability:       %.1f%%\n", health.stability * 100);
        report ~= format("  Performance:     %.1f%%\n", health.performance * 100);
        report ~= format("  Flaky tests:     %d\n", health.flakyCount);
        report ~= format("  Slow tests:      %d\n\n", health.slowCount);
        
        // Performance Insights
        report ~= "Performance:\n";
        report ~= format("  Total duration:  %d ms\n", 
            performance.totalDuration.total!"msecs");
        report ~= format("  Avg duration:    %d ms\n", 
            performance.avgDuration.total!"msecs");
        report ~= format("  Median:          %d ms\n", 
            performance.medianDuration.total!"msecs");
        report ~= format("  P95:             %d ms\n", 
            performance.p95Duration.total!"msecs");
        report ~= format("  P99:             %d ms\n", 
            performance.p99Duration.total!"msecs");
        report ~= format("  Parallel eff:    %.1f%%\n", 
            performance.parallelEfficiency * 100);
        report ~= format("  Recommended shards: %d\n\n", 
            performance.recommendedShards);
        
        // Recommendations
        report ~= "Recommendations:\n";
        
        if (health.flakyCount > 0)
        {
            report ~= format("  • Fix or quarantine %d flaky tests\n", health.flakyCount);
        }
        
        if (health.slowCount > 5)
        {
            report ~= format("  • Optimize %d slow tests\n", health.slowCount);
        }
        
        if (performance.parallelEfficiency < 0.7)
        {
            report ~= "  • Improve test parallelization\n";
        }
        
        if (health.passRate < 0.95)
        {
            report ~= "  • Investigate failing tests\n";
        }
        
        report ~= "\n═══════════════════════════════════════════\n";
        
        return report;
    }
}

