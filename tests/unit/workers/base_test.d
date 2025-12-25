module tests.unit.workers.base_test;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : msecs, seconds, minutes, Duration;
import core.time : MonoTime;
import engine.workers.base;
import engine.workers.protocol.types;
import engine.workers.pool.manager : WorkerPoolConfig, IWorkerFactory;

/// Test BaseWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - BaseWorkerConfig defaults");
    
    BaseWorkerConfig config;
    
    assert(config.startupTimeout == seconds(30), "Default startup timeout should be 30s");
    assert(config.requestTimeout == minutes(5), "Default request timeout should be 5min");
    assert(config.idleTimeout == minutes(5), "Default idle timeout should be 5min");
    assert(config.maxRequests == 5000, "Default max requests should be 5000");
    assert(config.coldStartMs == 500, "Default cold start should be 500ms");
    
    writeln("\x1b[32m  ✓ BaseWorkerConfig defaults correct\x1b[0m");
}

/// Test WorkerFactoryStats
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerFactoryStats");
    
    auto stats = WorkerFactoryStats("test-worker", 10, MonoTime.currTime);
    
    assert(stats.workerType == "test-worker", "Worker type should match");
    assert(stats.workersCreated == 10, "Workers created should match");
    
    // Time since last creation should be very small
    assert(stats.timeSinceLastCreation < seconds(1), "Time since creation should be small");
    
    writeln("\x1b[32m  ✓ WorkerFactoryStats works\x1b[0m");
}

/// Test WorkerCompilationResult success factory
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerCompilationResult.ok");
    
    auto result = WorkerCompilationResult.ok("Compiled successfully", 100, ["bin/main.o"]);
    
    assert(result.success, "Should be success");
    assert(result.output == "Compiled successfully", "Output should match");
    assert(result.executionTimeMs == 100, "Execution time should match");
    assert(result.outputFiles == ["bin/main.o"], "Output files should match");
    assert(!result.wasCached, "Should not be cached by default");
    
    writeln("\x1b[32m  ✓ WorkerCompilationResult.ok works\x1b[0m");
}

/// Test WorkerCompilationResult failure factory
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerCompilationResult.fail");
    
    auto result = WorkerCompilationResult.fail("Compilation error", 50, ["error: syntax"]);
    
    assert(!result.success, "Should be failure");
    assert(result.output == "Compilation error", "Output should match");
    assert(result.executionTimeMs == 50, "Execution time should match");
    assert(result.diagnostics == ["error: syntax"], "Diagnostics should match");
    
    writeln("\x1b[32m  ✓ WorkerCompilationResult.fail works\x1b[0m");
}

/// Test BaseWorkerConfig custom values
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - BaseWorkerConfig custom");
    
    BaseWorkerConfig config;
    config.startupTimeout = seconds(60);
    config.requestTimeout = minutes(10);
    config.idleTimeout = minutes(15);
    config.maxRequests = 10000;
    config.workDir = "/tmp/work";
    config.environment["PATH"] = "/usr/bin";
    config.coldStartMs = 2000;
    
    assert(config.startupTimeout == seconds(60), "Custom startup timeout");
    assert(config.requestTimeout == minutes(10), "Custom request timeout");
    assert(config.idleTimeout == minutes(15), "Custom idle timeout");
    assert(config.maxRequests == 10000, "Custom max requests");
    assert(config.workDir == "/tmp/work", "Custom work dir");
    assert(config.environment["PATH"] == "/usr/bin", "Custom env");
    assert(config.coldStartMs == 2000, "Custom cold start");
    
    writeln("\x1b[32m  ✓ BaseWorkerConfig custom values work\x1b[0m");
}

/// Test WorkerId
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerId");
    
    auto id = WorkerId("rust-cargo", 5);
    
    assert(id.type == "rust-cargo", "Type should match");
    assert(id.instanceId == 5, "Instance should match");
    assert(id.toString() == "rust-cargo-5", "String representation");
    
    writeln("\x1b[32m  ✓ WorkerId works\x1b[0m");
}

/// Test PersistentWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - PersistentWorkerConfig");
    
    PersistentWorkerConfig cfg;
    cfg.executable = "/usr/bin/cargo";
    cfg.baseArgs = ["build", "--release"];
    cfg.startupTimeout = seconds(30);
    cfg.requestTimeout = minutes(5);
    cfg.idleTimeout = seconds(60);
    cfg.maxRequests = 1000;
    cfg.workDir = "/project";
    cfg.environment["CARGO_HOME"] = "/home/.cargo";
    
    assert(cfg.executable == "/usr/bin/cargo", "Executable should match");
    assert(cfg.baseArgs.length == 2, "Args should match");
    assert(cfg.maxRequests == 1000, "Max requests should match");
    
    writeln("\x1b[32m  ✓ PersistentWorkerConfig works\x1b[0m");
}

/// Test WorkerState enum values
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerState enum");
    
    // All states should be distinct
    WorkerState[] states = [
        WorkerState.Starting,
        WorkerState.Ready,
        WorkerState.Busy,
        WorkerState.Idle,
        WorkerState.Terminating,
        WorkerState.Dead
    ];
    
    foreach (i, s1; states)
    {
        foreach (j, s2; states)
        {
            if (i != j)
                assert(s1 != s2, "States should be distinct");
        }
    }
    
    writeln("\x1b[32m  ✓ WorkerState enum valid\x1b[0m");
}

/// Test WorkerStats recording
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerStats");
    
    WorkerStats stats;
    
    assert(stats.totalRequests == 0, "Initial total should be 0");
    assert(stats.hitRate == 0.0f, "Initial hit rate should be 0");
    
    // Record some executions
    stats.recordExecution(true, 50);
    stats.recordExecution(true, 40);
    stats.recordExecution(false, 100);
    
    assert(stats.totalRequests == 3, "Total should be 3");
    assert(stats.successfulRequests == 2, "Successful should be 2");
    assert(stats.failedRequests == 1, "Failed should be 1");
    assert(stats.totalExecutionTimeMs == 190, "Total time should be 190ms");
    assert(stats.avgExecutionTimeMs == 63, "Avg time should be ~63ms");
    
    writeln("\x1b[32m  ✓ WorkerStats recording works\x1b[0m");
}

/// Test WorkerCapabilities
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.base - WorkerCapabilities");
    
    WorkerCapabilities caps;
    caps.compilerType = "cargo";
    caps.compilerVersion = "1.70.0";
    caps.supportedFlags = ["--release", "--verbose"];
    caps.supportsStreaming = false;
    caps.supportsCancel = true;
    caps.maxConcurrent = 1;
    
    assert(caps.compilerType == "cargo", "Compiler type should match");
    assert(caps.compilerVersion == "1.70.0", "Version should match");
    assert(caps.supportedFlags.length == 2, "Flags should match");
    assert(caps.supportsCancel, "Should support cancel");
    
    writeln("\x1b[32m  ✓ WorkerCapabilities works\x1b[0m");
}


