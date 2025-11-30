module tests.unit.core.retry;

import std.stdio;
import std.datetime;
import std.conv;
import engine.runtime.recovery.retry;
import infrastructure.errors;

/// Test retry policy creation
unittest
{
    writeln("Testing retry policy creation...");
    
    auto policy = RetryPolicy.init;
    assert(policy.maxAttempts == 3);
    assert(policy.initialDelay == 100.msecs);
    
    // Test category-based policies
    auto systemPolicy = RetryPolicy.forCategory(ErrorCategory.System);
    assert(systemPolicy.maxAttempts == 5);
    assert(systemPolicy.exponential);
    
    auto buildPolicy = RetryPolicy.forCategory(ErrorCategory.Build);
    assert(buildPolicy.maxAttempts == 1); // No retry for build errors
    assert(!buildPolicy.exponential);
    
    writeln("✓ Retry policy creation tests passed");
}

/// Test exponential backoff calculation
unittest
{
    writeln("Testing exponential backoff...");
    
    auto policy = RetryPolicy(5, 100.msecs, 10.seconds, 2.0, 0.0, true); // No jitter for testing
    
    // First attempt - no delay
    assert(policy.delayFor(0) == Duration.zero);
    
    // Subsequent attempts - exponential
    auto delay1 = policy.delayFor(1);
    assert(delay1 >= 90.msecs && delay1 <= 110.msecs); // 100ms with jitter
    
    auto delay2 = policy.delayFor(2);
    assert(delay2 >= 180.msecs && delay2 <= 220.msecs); // 200ms with jitter
    
    // Max delay capping
    auto delay10 = policy.delayFor(10);
    assert(delay10 <= policy.maxDelay);
    
    writeln("✓ Exponential backoff tests passed");
}

/// Test retry context
unittest
{
    writeln("Testing retry context...");
    
    auto policy = RetryPolicy(3, 100.msecs, 1.seconds, 2.0, 0.1, true);
    auto ctx = RetryContext("test-target", policy);
    
    assert(ctx.operationId == "test-target");
    assert(ctx.currentAttempt == 0);
    assert(ctx.shouldRetry());
    
    // Simulate attempts
    auto error = new BuildFailureError("test", "test error");
    ctx.recordAttempt(error);
    assert(ctx.currentAttempt == 1);
    assert(ctx.shouldRetry());
    
    ctx.recordAttempt(error);
    assert(ctx.currentAttempt == 2);
    assert(ctx.shouldRetry());
    
    ctx.recordAttempt(error);
    assert(ctx.currentAttempt == 3);
    assert(!ctx.shouldRetry()); // Max attempts reached
    
    writeln("✓ Retry context tests passed");
}

/// Test retry orchestrator
unittest
{
    writeln("Testing retry orchestrator...");
    
    auto orchestrator = new RetryOrchestrator();
    assert(orchestrator.isEnabled());
    
    // Test enable/disable
    orchestrator.setEnabled(false);
    assert(!orchestrator.isEnabled());
    orchestrator.setEnabled(true);
    assert(orchestrator.isEnabled());
    
    // Test policy registration
    auto customPolicy = RetryPolicy(5, 50.msecs, 5.seconds, 1.5, 0.05, true);
    orchestrator.registerPolicy(ErrorCode.ProcessTimeout, customPolicy);
    
    auto error = new SystemError("timeout", ErrorCode.ProcessTimeout);
    auto policy = orchestrator.policyFor(error);
    assert(policy.maxAttempts == 5);
    
    writeln("✓ Retry orchestrator tests passed");
}

/// Test retry with success
unittest
{
    writeln("Testing retry with success...");
    
    auto orchestrator = new RetryOrchestrator();
    auto policy = RetryPolicy(3, 1.msecs, 100.msecs, 2.0, 0.0, true); // Fast for testing
    
    int attempts = 0;
    
    auto result = orchestrator.withRetry(
        "test-op",
        () {
            attempts++;
            if (attempts < 2)
                return Result!(int, BuildError).err(new SystemError("temp error", ErrorCode.ProcessTimeout));
            return Result!(int, BuildError).ok(42);
        },
        policy
    );
    
    assert(result.isOk);
    assert(result.unwrap() == 42);
    assert(attempts == 2); // Failed once, succeeded on second attempt
    
    writeln("✓ Retry with success tests passed");
}

/// Test retry exhaustion
unittest
{
    writeln("Testing retry exhaustion...");
    
    auto orchestrator = new RetryOrchestrator();
    auto policy = RetryPolicy(3, 1.msecs, 100.msecs, 2.0, 0.0, true);
    
    int attempts = 0;
    
    auto result = orchestrator.withRetry(
        "test-op",
        () {
            attempts++;
            return Result!(int, BuildError).err(new SystemError("persistent error", ErrorCode.ProcessTimeout));
        },
        policy
    );
    
    assert(result.isErr);
    assert(attempts == 3); // Max attempts
    
    writeln("✓ Retry exhaustion tests passed");
}

/// Test non-recoverable errors
unittest
{
    writeln("Testing non-recoverable errors...");
    
    auto orchestrator = new RetryOrchestrator();
    auto policy = RetryPolicy(3, 1.msecs, 100.msecs, 2.0, 0.0, true);
    
    int attempts = 0;
    
    auto result = orchestrator.withRetry(
        "test-op",
        () {
            attempts++;
            // Build errors are not recoverable
            return Result!(int, BuildError).err(new BuildFailureError("test", "compile error", ErrorCode.CompilationFailed));
        },
        policy
    );
    
    assert(result.isErr);
    assert(attempts == 1); // No retry for non-recoverable errors
    
    writeln("✓ Non-recoverable error tests passed");
}

/// Test retry statistics
unittest
{
    writeln("Testing retry statistics...");
    
    auto orchestrator = new RetryOrchestrator();
    orchestrator.resetStats();
    
    auto policy = RetryPolicy(3, 1.msecs, 100.msecs, 2.0, 0.0, true);
    
    // Successful retry
    orchestrator.withRetry(
        "test-1",
        () {
            static int attempt1 = 0;
            attempt1++;
            if (attempt1 < 2)
                return Result!(int, BuildError).err(new SystemError("temp", ErrorCode.ProcessTimeout));
            return Result!(int, BuildError).ok(1);
        },
        policy
    );
    
    // Failed retry
    orchestrator.withRetry(
        "test-2",
        () {
            return Result!(int, BuildError).err(new SystemError("persistent", ErrorCode.ProcessTimeout));
        },
        policy
    );
    
    auto stats = orchestrator.getStats();
    assert(stats.totalRetries == 2); // One successful, one failed
    assert(stats.successfulRetries == 1);
    assert(stats.failedRetries == 1);
    
    writeln("✓ Retry statistics tests passed");
}

void runRetryTests()
{
    writeln("\n=== Running Retry Tests ===\n");
    
    // Tests run automatically via unittest blocks
    
    writeln("\n=== All Retry Tests Passed ===\n");
}

