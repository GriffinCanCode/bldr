module frontend.testframework.flaky.detector;

import std.algorithm : max, min;
import std.conv : to;
import std.math : exp, log, abs;
import std.datetime : SysTime, Clock, Duration, dur;
import core.sync.mutex : Mutex;
import frontend.testframework.results : TestResult;
import infrastructure.utils.logging;

/// Flakiness confidence level
enum FlakyConfidence
{
    None,      // < 10% probability
    Low,       // 10-30% probability
    Medium,    // 30-60% probability
    High,      // 60-85% probability
    VeryHigh   // > 85% probability
}

/// Flaky test status
enum FlakyStatus
{
    Stable,      // Consistently passing
    Suspect,     // Recently failed, monitoring
    Flaky,       // Confirmed flaky
    Quarantined  // Isolated from main suite
}

/// Temporal pattern for flakiness
enum TemporalPattern
{
    None,         // No pattern
    TimeOfDay,    // Fails at certain times
    DayOfWeek,    // Fails on certain days
    LoadBased,    // Fails under high load
    Sequential    // Fails after certain tests
}

/// Flaky test record with Bayesian statistics
struct FlakyRecord
{
    string testId;
    FlakyStatus status;
    FlakyConfidence confidence;
    TemporalPattern pattern;
    
    // Bayesian statistics
    size_t totalRuns;
    size_t failures;
    size_t consecutivePasses;
    size_t consecutiveFails;
    double flakinessScore;      // 0.0 (stable) to 1.0 (always flaky)
    
    // Temporal data
    SysTime firstFailure;
    SysTime lastFailure;
    SysTime lastPass;
    Duration[] failureIntervals;
    
    // Quarantine info
    bool quarantined;
    SysTime quarantineStart;
    size_t quarantineRuns;
    
    /// Calculate flakiness probability using Bayesian inference
    double probability() const pure nothrow @nogc
    {
        if (totalRuns < 3)
            return 0.0;
        
        // Beta distribution with Jeffrey's prior (0.5, 0.5)
        immutable alpha = cast(double)failures + 0.5;
        immutable beta = cast(double)(totalRuns - failures) + 0.5;
        
        // Expected value of Beta distribution
        return alpha / (alpha + beta);
    }
    
    /// Get confidence level
    FlakyConfidence getConfidence() const pure nothrow @nogc
    {
        immutable prob = probability();
        
        if (prob < 0.1)
            return FlakyConfidence.None;
        else if (prob < 0.3)
            return FlakyConfidence.Low;
        else if (prob < 0.6)
            return FlakyConfidence.Medium;
        else if (prob < 0.85)
            return FlakyConfidence.High;
        else
            return FlakyConfidence.VeryHigh;
    }
    
    /// Check if test should be quarantined
    bool shouldQuarantine() const pure nothrow @nogc
    {
        // Quarantine criteria:
        // 1. Medium+ confidence AND
        // 2. Multiple recent failures OR
        // 3. Very high confidence
        
        immutable conf = getConfidence();
        
        if (conf == FlakyConfidence.VeryHigh)
            return true;
        
        if (conf >= FlakyConfidence.Medium && consecutiveFails >= 2)
            return true;
        
        if (conf >= FlakyConfidence.Medium && failures >= 3 && totalRuns < 10)
            return true;
        
        return false;
    }
}

/// Flaky test detector using Bayesian inference
final class FlakyDetector
{
    private FlakyRecord[string] records;
    private Mutex mutex;
    
    // Configuration
    private size_t minRunsForDetection = 3;
    private double quarantineThreshold = 0.3;
    private Duration quarantinePeriod = dur!"days"(7);
    
    this() @safe
    {
        mutex = new Mutex();
    }
    
    /// Record test execution result
    void recordExecution(string testId, bool passed, SysTime timestamp = Clock.currTime()) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            FlakyRecord record;
            
            if (recordPtr !is null)
            {
                record = *recordPtr;
            }
            else
            {
                record.testId = testId;
                record.status = FlakyStatus.Stable;
            }
            
            // Update statistics
            record.totalRuns++;
            
            if (passed)
            {
                record.consecutivePasses++;
                record.consecutiveFails = 0;
                record.lastPass = timestamp;
            }
            else
            {
                record.failures++;
                record.consecutiveFails++;
                record.consecutivePasses = 0;
                
                if (record.firstFailure == SysTime.init)
                    record.firstFailure = timestamp;
                
                // Record failure interval
                if (record.lastFailure != SysTime.init)
                {
                    immutable interval = timestamp - record.lastFailure;
                    record.failureIntervals ~= interval;
                }
                
                record.lastFailure = timestamp;
            }
            
            // Update flakiness score and confidence
            record.flakinessScore = record.probability();
            record.confidence = record.getConfidence();
            
            // Update status
            updateStatus(record);
            
            // Check quarantine
            if (!record.quarantined && record.shouldQuarantine())
            {
                quarantineTest(record, timestamp);
                structuredLog.warning("test_quarantined_").field("detail", "Test quarantined: " ~ testId ~ 
                    " (confidence: " ~ record.confidence.to!string ~ ")").emit();
            }
            
            records[testId] = record;
        }
    }
    
    /// Check if test is flaky
    bool isFlaky(string testId) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            if (recordPtr is null)
                return false;
            
            return recordPtr.status == FlakyStatus.Flaky || 
                   recordPtr.status == FlakyStatus.Quarantined;
        }
    }
    
    /// Check if test is quarantined
    bool isQuarantined(string testId) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            if (recordPtr is null)
                return false;
            
            return recordPtr.quarantined;
        }
    }
    
    /// Get flaky record for test
    FlakyRecord getRecord(string testId) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            if (recordPtr is null)
                return FlakyRecord.init;
            
            return *recordPtr;
        }
    }
    
    /// Get all flaky tests
    FlakyRecord[] getFlakyTests() @system
    {
        import std.algorithm : filter;
        import std.array : array;
        
        synchronized (mutex)
        {
            return records.values
                .filter!(r => r.status == FlakyStatus.Flaky || 
                             r.status == FlakyStatus.Quarantined)
                .array;
        }
    }
    
    /// Get tests by confidence level
    FlakyRecord[] getTestsByConfidence(FlakyConfidence minConfidence) @system
    {
        import std.algorithm : filter;
        import std.array : array;
        
        synchronized (mutex)
        {
            return records.values
                .filter!(r => r.confidence >= minConfidence)
                .array;
        }
    }
    
    /// Release test from quarantine
    void releaseFromQuarantine(string testId) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            if (recordPtr is null)
                return;
            
            recordPtr.quarantined = false;
            recordPtr.status = FlakyStatus.Suspect;
            recordPtr.quarantineRuns = 0;
            
            structuredLog.info("test_released_from_quarantine_").field("detail", "Test released from quarantine: " ~ testId).emit();
        }
    }
    
    /// Detect temporal patterns
    TemporalPattern detectPattern(string testId) @system
    {
        synchronized (mutex)
        {
            auto recordPtr = testId in records;
            if (recordPtr is null || recordPtr.failureIntervals.length < 3)
                return TemporalPattern.None;
            
            return analyzeTemporalPattern(*recordPtr);
        }
    }
    
    /// Update test status based on statistics
    private void updateStatus(ref FlakyRecord record) nothrow
    {
        if (record.totalRuns < minRunsForDetection)
        {
            record.status = FlakyStatus.Stable;
            return;
        }
        
        immutable conf = record.getConfidence();
        
        if (record.quarantined)
        {
            record.status = FlakyStatus.Quarantined;
        }
        else if (conf >= FlakyConfidence.Medium)
        {
            record.status = FlakyStatus.Flaky;
        }
        else if (record.failures > 0)
        {
            record.status = FlakyStatus.Suspect;
        }
        else
        {
            record.status = FlakyStatus.Stable;
        }
    }
    
    /// Quarantine flaky test
    private void quarantineTest(ref FlakyRecord record, SysTime timestamp) nothrow
    {
        record.quarantined = true;
        record.quarantineStart = timestamp;
        record.quarantineRuns = 0;
        record.status = FlakyStatus.Quarantined;
    }
    
    /// Analyze temporal failure patterns
    private TemporalPattern analyzeTemporalPattern(ref const(FlakyRecord) record) pure nothrow
    {
        if (record.failureIntervals.length < 3)
            return TemporalPattern.None;
        
        // Check for periodic patterns
        double avgInterval = 0.0;
        foreach (interval; record.failureIntervals)
        {
            avgInterval += interval.total!"hours";
        }
        avgInterval /= record.failureIntervals.length;
        
        // Time of day pattern: ~24 hour intervals
        if (abs(avgInterval - 24.0) < 2.0)
            return TemporalPattern.TimeOfDay;
        
        // Day of week pattern: ~168 hour intervals
        if (abs(avgInterval - 168.0) < 12.0)
            return TemporalPattern.DayOfWeek;
        
        // Check variance for load-based pattern
        double variance = 0.0;
        foreach (interval; record.failureIntervals)
        {
            immutable diff = interval.total!"hours" - avgInterval;
            variance += diff * diff;
        }
        variance /= record.failureIntervals.length;
        
        // High variance suggests load-based flakiness
        if (variance > avgInterval * avgInterval)
            return TemporalPattern.LoadBased;
        
        return TemporalPattern.None;
    }
    
    /// Get detector statistics
    struct DetectorStats
    {
        size_t totalTests;
        size_t stableTests;
        size_t suspectTests;
        size_t flakyTests;
        size_t quarantinedTests;
        double avgFlakinessScore;
    }
    
    DetectorStats getStats() @system
    {
        synchronized (mutex)
        {
            DetectorStats stats;
            stats.totalTests = records.length;
            
            double totalScore = 0.0;
            
            foreach (ref record; records)
            {
                final switch (record.status)
                {
                    case FlakyStatus.Stable:
                        stats.stableTests++;
                        break;
                    case FlakyStatus.Suspect:
                        stats.suspectTests++;
                        break;
                    case FlakyStatus.Flaky:
                        stats.flakyTests++;
                        break;
                    case FlakyStatus.Quarantined:
                        stats.quarantinedTests++;
                        break;
                }
                
                totalScore += record.flakinessScore;
            }
            
            if (stats.totalTests > 0)
                stats.avgFlakinessScore = totalScore / stats.totalTests;
            
            return stats;
        }
    }
}

