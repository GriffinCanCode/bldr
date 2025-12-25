module tests.unit.workers.service_test;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : seconds, minutes, Duration;
import core.time : MonoTime;
import engine.workers.service;
import engine.workers.pool.manager : WorkerPoolConfig;
import engine.workers.pool.recycler : WarmthLevel, RecyclingPolicy;
import engine.workers.pool.memory : MemoryThresholds;

/// Test WorkerServiceConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - WorkerServiceConfig defaults");
    
    WorkerServiceConfig cfg;
    
    assert(cfg.enableJVMWorkers, "JVM workers enabled by default");
    assert(cfg.enableTSWorkers, "TS workers enabled by default");
    assert(cfg.enableRustWorkers, "Rust workers enabled by default");
    assert(cfg.enableGoWorkers, "Go workers enabled by default");
    assert(cfg.enablePythonWorkers, "Python workers enabled by default");
    assert(cfg.metricsInterval == seconds(30), "Default metrics interval");
    assert(cfg.enableAutoRecovery, "Auto recovery enabled by default");
    
    writeln("\x1b[32m  ✓ WorkerServiceConfig defaults correct\x1b[0m");
}

/// Test WorkerServiceStatus enum
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - WorkerServiceStatus enum");
    
    WorkerServiceStatus[] statuses = [
        WorkerServiceStatus.Stopped,
        WorkerServiceStatus.Starting,
        WorkerServiceStatus.Running,
        WorkerServiceStatus.Degraded,
        WorkerServiceStatus.Stopping
    ];
    
    // All statuses should be distinct
    foreach (i, s1; statuses)
    {
        foreach (j, s2; statuses)
        {
            if (i != j)
                assert(s1 != s2, "Statuses should be distinct");
        }
    }
    
    writeln("\x1b[32m  ✓ WorkerServiceStatus enum valid\x1b[0m");
}

/// Test LanguageMetrics
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - LanguageMetrics");
    
    LanguageMetrics metrics;
    metrics.compilations = 100;
    metrics.successes = 95;
    metrics.avgExecutionMs = 50;
    metrics.coldStartMs = 800;
    metrics.speedup = 16.0f;
    
    assert(metrics.compilations == 100, "Compilations should match");
    assert(metrics.speedup == 16.0f, "Speedup should match");
    
    writeln("\x1b[32m  ✓ LanguageMetrics works\x1b[0m");
}

/// Test WorkerServiceMetrics
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - WorkerServiceMetrics");
    
    WorkerServiceMetrics metrics;
    metrics.totalCompilations = 500;
    metrics.successfulCompilations = 480;
    metrics.failedCompilations = 20;
    metrics.averageSpeedupFactor = 12.5f;
    metrics.warmWorkers = 5;
    metrics.hotWorkers = 2;
    
    assert(metrics.totalCompilations == 500, "Total compilations should match");
    assert(metrics.successfulCompilations == 480, "Successful should match");
    assert(metrics.averageSpeedupFactor == 12.5f, "Speedup should match");
    
    writeln("\x1b[32m  ✓ WorkerServiceMetrics works\x1b[0m");
}

/// Test PersistentWorkerService creation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - PersistentWorkerService creation");
    
    auto service = new PersistentWorkerService();
    
    assert(service !is null, "Service should be created");
    assert(service.getStatus() == WorkerServiceStatus.Stopped, "Initial status should be Stopped");
    
    writeln("\x1b[32m  ✓ PersistentWorkerService creation works\x1b[0m");
}

/// Test service configuration propagation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Configuration propagation");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = true;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = true;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = true;
    cfg.poolConfig.maxWorkersPerType = 8;
    cfg.poolConfig.idleTimeout = minutes(15);
    
    auto service = new PersistentWorkerService(cfg);
    assert(service !is null, "Service should be created with config");
    
    writeln("\x1b[32m  ✓ Configuration propagation works\x1b[0m");
}

/// Test WorkerPoolConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - WorkerPoolConfig defaults");
    
    WorkerPoolConfig cfg;
    
    assert(cfg.maxWorkersPerType == 4, "Default max workers per type");
    assert(cfg.idleTimeout == minutes(10), "Default idle timeout");
    assert(cfg.healthCheckInterval == seconds(30), "Default health check interval");
    assert(cfg.maxRequestsPerWorker == 10_000, "Default max requests");
    assert(cfg.maxHeapMB == 2048, "Default max heap");
    assert(cfg.enableMetrics, "Metrics enabled by default");
    assert(cfg.enableRecycling, "Recycling enabled by default");
    assert(cfg.enableMemoryMonitor, "Memory monitor enabled by default");
    assert(cfg.persistAcrossBuilds, "Persist across builds enabled");
    
    writeln("\x1b[32m  ✓ WorkerPoolConfig defaults correct\x1b[0m");
}

/// Test RecyclingPolicy defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - RecyclingPolicy defaults");
    
    RecyclingPolicy policy;
    
    assert(policy.maxIdleTime == minutes(10), "Default max idle time");
    assert(policy.minKeepWarmTime == minutes(2), "Default min keep warm time");
    assert(policy.hotWorkerBonus == minutes(5), "Default hot worker bonus");
    assert(policy.maxRequestsBeforeRecycle == 10_000, "Default max requests");
    assert(policy.preferWarmWorkers, "Prefer warm workers enabled");
    assert(policy.keepHotAcrossBuilds, "Keep hot across builds enabled");
    
    writeln("\x1b[32m  ✓ RecyclingPolicy defaults correct\x1b[0m");
}

/// Test MemoryThresholds defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - MemoryThresholds defaults");
    
    MemoryThresholds thresholds;
    
    assert(thresholds.normalMax == 0.70f, "Default normal max");
    assert(thresholds.elevatedMax == 0.85f, "Default elevated max");
    assert(thresholds.highMax == 0.95f, "Default high max");
    assert(thresholds.minHeapMB == 256, "Default min heap");
    assert(thresholds.maxHeapMB == 8192, "Default max heap");
    
    writeln("\x1b[32m  ✓ MemoryThresholds defaults correct\x1b[0m");
}

/// Test WarmthLevel enum
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - WarmthLevel enum");
    
    // Warmth levels should be ordered
    assert(WarmthLevel.Cold < WarmthLevel.Warming, "Cold < Warming");
    assert(WarmthLevel.Warming < WarmthLevel.Warm, "Warming < Warm");
    assert(WarmthLevel.Warm < WarmthLevel.Hot, "Warm < Hot");
    
    writeln("\x1b[32m  ✓ WarmthLevel ordering correct\x1b[0m");
}

/// Test global service functions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Global service functions");
    
    // Get service (creates if needed)
    auto service = getWorkerService();
    assert(service !is null, "Global service should be created");
    
    // Second call should return same instance
    auto service2 = getWorkerService();
    assert(service is service2, "Should return same instance");
    
    writeln("\x1b[32m  ✓ Global service functions work\x1b[0m");
}

/// Test service start/stop lifecycle
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Service lifecycle");
    
    WorkerServiceConfig cfg;
    // Disable all workers for fast test
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    
    assert(service.getStatus() == WorkerServiceStatus.Stopped, "Initial status");
    
    service.start();
    assert(service.getStatus() == WorkerServiceStatus.Running, "After start");
    
    service.stop();
    assert(service.getStatus() == WorkerServiceStatus.Stopped, "After stop");
    
    // Multiple stops should be safe
    service.stop();
    assert(service.getStatus() == WorkerServiceStatus.Stopped, "After double stop");
    
    writeln("\x1b[32m  ✓ Service lifecycle works\x1b[0m");
}

/// Test metrics retrieval
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Metrics retrieval");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    auto metrics = service.getMetrics();
    
    assert(metrics.totalCompilations == 0, "Initial compilations should be 0");
    assert(metrics.successfulCompilations == 0, "Initial successes should be 0");
    assert(metrics.failedCompilations == 0, "Initial failures should be 0");
    
    writeln("\x1b[32m  ✓ Metrics retrieval works\x1b[0m");
}

/// Test speedup factor calculation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Speedup factor");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    // Unknown type should return 1.0
    auto speedup = service.getSpeedupFactor("unknown-type");
    assert(speedup == 1.0f, "Unknown type should return 1.0");
    
    writeln("\x1b[32m  ✓ Speedup factor calculation works\x1b[0m");
}

/// Test pool access
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.service - Pool access");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    auto pool = service.getPool();
    assert(pool !is null, "Pool should be accessible");
    
    writeln("\x1b[32m  ✓ Pool access works\x1b[0m");
}


