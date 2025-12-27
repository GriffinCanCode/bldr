module frontend.testframework.flaky.retry;

import std.algorithm : min;
import std.conv : to;
import std.datetime : Duration, dur;
import core.thread : Thread;
import frontend.testframework.results : TestResult;
import frontend.testframework.flaky.detector : FlakyDetector, FlakyConfidence;
import infrastructure.utils.logging;

/// Retry policy configuration
struct RetryPolicy
{
    size_t maxAttempts = 3;                 // Maximum retry attempts
    Duration initialDelay = dur!"msecs"(100); // Initial retry delay
    double backoffMultiplier = 2.0;         // Exponential backoff factor
    Duration maxDelay = dur!"seconds"(10);   // Maximum retry delay
    bool adaptiveRetry = true;               // Use flaky detection for retry count
}

/// Retry strategy
enum RetryStrategy
{
    Fixed,      // Fixed number of retries
    Adaptive,   // Based on flakiness confidence
    Exponential // Exponential backoff
}

/// Retry context
struct RetryContext
{
    string testId;
    size_t attempt;
    size_t maxAttempts;
    Duration delay;
    TestResult lastResult;
    bool shouldRetry;
}

/// Intelligent test retry mechanism
/// Uses Bayesian flakiness detection for adaptive retries
final class RetryOrchestrator
{
    private RetryPolicy policy;
    private FlakyDetector detector;
    
    this(RetryPolicy policy, FlakyDetector detector) pure nothrow @safe @nogc
    {
        this.policy = policy;
        this.detector = detector;
    }
    
    /// Determine if test should be retried
    bool shouldRetry(string testId, size_t currentAttempt, bool passed) @system
    {
        // Don't retry if passed
        if (passed)
            return false;
        
        // Check attempt limit
        if (currentAttempt >= getMaxAttempts(testId))
            return false;
        
        return true;
    }
    
    /// Get maximum retry attempts for test
    size_t getMaxAttempts(string testId) @system
    {
        if (!policy.adaptiveRetry)
            return policy.maxAttempts;
        
        // Adjust based on flakiness confidence
        auto record = detector.getRecord(testId);
        
        final switch (record.confidence)
        {
            case FlakyConfidence.None:
                return 1; // No retries for stable tests
            
            case FlakyConfidence.Low:
                return 2; // One retry
            
            case FlakyConfidence.Medium:
                return 3; // Two retries
            
            case FlakyConfidence.High:
                return 4; // Three retries
            
            case FlakyConfidence.VeryHigh:
                return 5; // Four retries (very flaky)
        }
    }
    
    /// Calculate retry delay
    Duration getRetryDelay(size_t attempt) const pure nothrow @safe @nogc
    {
        // Exponential backoff
        double multiplier = 1.0;
        foreach (_; 0 .. attempt)
        {
            multiplier *= policy.backoffMultiplier;
        }
        
        immutable delayMs = cast(long)(policy.initialDelay.total!"msecs" * multiplier);
        immutable cappedDelay = min(delayMs, policy.maxDelay.total!"msecs");
        
        return dur!"msecs"(cappedDelay);
    }
    
    /// Execute test with retries
    TestResult executeWithRetry(
        string testId,
        TestResult delegate() @system executeTest
    ) @system
    {
        size_t attempt = 0;
        TestResult result;
        
        while (attempt < getMaxAttempts(testId))
        {
            attempt++;
            
            structuredLog.debug_("test_attempt_").field("detail", "Test attempt " ~ attempt.to!string ~ "/" ~ 
                getMaxAttempts(testId).to!string ~ ": " ~ testId).emit();
            
            // Execute test
            result = executeTest();
            
            // Record result with flaky detector
            detector.recordExecution(testId, result.passed);
            
            // If passed, we're done
            if (result.passed)
            {
                if (attempt > 1)
                {
                    structuredLog.info("test_passed_on_attempt_").field("detail", "Test passed on attempt " ~ attempt.to!string ~ ": " ~ testId).emit();
                }
                break;
            }
            
            // Check if should retry
            if (!shouldRetry(testId, attempt, result.passed))
            {
                break;
            }
            
            // Wait before retry
            immutable delay = getRetryDelay(attempt);
            structuredLog.debug_("retrying_test_after_").field("detail", "Retrying test after " ~ delay.total!"msecs".to!string ~ "ms: " ~ testId).emit();
            Thread.sleep(delay);
        }
        
        // Log final result
        if (!result.passed && attempt > 1)
        {
            structuredLog.warning("test_failed_after_").field("detail", "Test failed after " ~ attempt.to!string ~ " attempts: " ~ testId).emit();
        }
        
        return result;
    }
    
    /// Create retry context
    RetryContext createContext(string testId) @system
    {
        RetryContext context;
        context.testId = testId;
        context.attempt = 0;
        context.maxAttempts = getMaxAttempts(testId);
        context.delay = policy.initialDelay;
        context.shouldRetry = true;
        return context;
    }
    
    /// Update retry context after attempt
    void updateContext(ref RetryContext context, TestResult result) @system
    {
        context.attempt++;
        context.lastResult = result;
        context.shouldRetry = shouldRetry(context.testId, context.attempt, result.passed);
        
        if (context.shouldRetry)
        {
            context.delay = getRetryDelay(context.attempt);
        }
        
        // Record with detector
        detector.recordExecution(context.testId, result.passed);
    }
}

