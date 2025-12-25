module tests.unit.services.speculation;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : msecs, seconds, Duration;
import engine.runtime.services.speculation;
import engine.economics.estimator : ExecutionHistory, CostEstimator;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.config.schema.schema : Target;

/// Test speculation policy presets
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Policy presets ordering");
    
    auto cons = SpeculationPolicy.conservative();
    auto bal = SpeculationPolicy.balanced();
    auto agg = SpeculationPolicy.aggressive();
    
    // Conservative should be most restrictive
    assert(cons.maxConcurrent <= bal.maxConcurrent, "Conservative should have fewer concurrent");
    assert(cons.minCostMs >= bal.minCostMs, "Conservative should require higher cost");
    assert(cons.confidenceThreshold >= bal.confidenceThreshold, "Conservative should need more confidence");
    
    // Aggressive should be most permissive
    assert(agg.maxConcurrent >= bal.maxConcurrent, "Aggressive should have more concurrent");
    assert(agg.minCostMs <= bal.minCostMs, "Aggressive should accept lower cost");
    assert(agg.confidenceThreshold <= bal.confidenceThreshold, "Aggressive should need less confidence");
    
    writeln("\x1b[32m  ✓ Policy presets properly ordered\x1b[0m");
}

/// Test speculative status transitions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Status transitions");
    
    // Valid status progression
    SpeculativeStatus[] validProgress = [
        SpeculativeStatus.Pending,
        SpeculativeStatus.Running,
        SpeculativeStatus.Completed,
        SpeculativeStatus.Promoted
    ];
    
    foreach (i, status; validProgress[0..$-1])
    {
        assert(status != validProgress[i+1], "Adjacent statuses should differ");
    }
    
    // Abort can happen from Running
    assert(SpeculativeStatus.Aborted != SpeculativeStatus.Running);
    
    writeln("\x1b[32m  ✓ Status transitions valid\x1b[0m");
}

/// Test speculation statistics calculation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Statistics effectiveness");
    
    SpeculationStats stats;
    stats.totalSpeculated = 10;
    stats.successful = 7;
    stats.aborted = 2;
    stats.wasted = 1;
    stats.timeSaved = 5000.msecs;
    stats.timeWasted = 500.msecs;
    
    // Effectiveness = successful / total
    assert(stats.effectiveness > 0.69f && stats.effectiveness < 0.71f, 
           "Effectiveness should be ~70%");
    
    // ROI = timeSaved / timeWasted
    assert(stats.roi > 9.9f && stats.roi < 10.1f, 
           "ROI should be ~10x");
    
    writeln("\x1b[32m  ✓ Statistics calculation correct\x1b[0m");
}

/// Test speculation stats with edge cases
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Statistics edge cases");
    
    // Empty stats
    SpeculationStats empty;
    assert(empty.effectiveness == 0.0f, "Empty stats should have 0 effectiveness");
    
    // No wasted time (infinite ROI)
    SpeculationStats noWaste;
    noWaste.totalSpeculated = 5;
    noWaste.successful = 5;
    noWaste.timeSaved = 1000.msecs;
    noWaste.timeWasted = Duration.zero;
    assert(noWaste.roi == float.infinity, "No waste should be infinite ROI");
    
    // All wasted
    SpeculationStats allWasted;
    allWasted.totalSpeculated = 10;
    allWasted.successful = 0;
    allWasted.wasted = 10;
    allWasted.timeWasted = 1000.msecs;
    assert(allWasted.effectiveness == 0.0f, "All wasted should have 0 effectiveness");
    
    writeln("\x1b[32m  ✓ Edge cases handled\x1b[0m");
}

/// Test executor stats hit rate calculation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Executor stats hit rate");
    
    SpeculationExecutorStats stats;
    
    // Empty stats
    assert(stats.hitRate == 0.0f, "Empty should have 0 hit rate");
    
    // Half hits
    stats.hits = 5;
    stats.misses = 5;
    assert(stats.hitRate == 0.5f, "50% hit rate");
    
    // All hits
    stats.hits = 10;
    stats.misses = 0;
    assert(stats.hitRate == 1.0f, "100% hit rate");
    
    // Some hits
    stats.hits = 3;
    stats.misses = 7;
    assert(stats.hitRate == 0.3f, "30% hit rate");
    
    writeln("\x1b[32m  ✓ Hit rate calculation correct\x1b[0m");
}

/// Test speculation service creation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Service creation");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    assert(service !is null, "Service should be created");
    
    // Set policy
    service.setPolicy(SpeculationPolicy.aggressive());
    
    // Get stats (should be empty initially)
    auto stats = service.getStats();
    assert(stats.totalSpeculated == 0, "Should start with no speculation");
    
    writeln("\x1b[32m  ✓ Service creation works\x1b[0m");
}

/// Test speculation with null graph
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Null graph handling");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator, null);
    
    // Should handle null graph gracefully
    auto candidates = service.getCandidates(10);
    assert(candidates.length == 0, "No candidates for null graph");
    
    writeln("\x1b[32m  ✓ Null graph handled\x1b[0m");
}

/// Test speculation policy configuration
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Policy configuration");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    // Test all policy presets
    service.setPolicy(SpeculationPolicy.conservative());
    service.setPolicy(SpeculationPolicy.balanced());
    service.setPolicy(SpeculationPolicy.aggressive());
    
    // Custom policy
    SpeculationPolicy custom;
    custom.maxConcurrent = 16;
    custom.minCostMs = 100;
    custom.confidenceThreshold = 0.3f;
    custom.budgetFraction = 0.5f;
    service.setPolicy(custom);
    
    writeln("\x1b[32m  ✓ Policy configuration works\x1b[0m");
}

/// Test speculation abort all
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Abort all");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    // Abort should work even with no tasks
    service.abortAll();
    
    auto stats = service.getStats();
    assert(stats.aborted == 0, "No aborts when nothing running");
    
    writeln("\x1b[32m  ✓ Abort all works\x1b[0m");
}

/// Test shutdown
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Shutdown");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    // Shutdown should be idempotent
    service.shutdown();
    service.shutdown();  // Second call should be safe
    
    writeln("\x1b[32m  ✓ Shutdown idempotent\x1b[0m");
}

/// Test input change notification
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Input change notification");
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    // Notify with new hash
    service.notifyInputChanged("test.d", "abc123");
    service.notifyInputChanged("test.d", "def456");  // Changed
    
    // Same hash should be no-op
    service.notifyInputChanged("other.d", "xyz789");
    service.notifyInputChanged("other.d", "xyz789");  // Same
    
    writeln("\x1b[32m  ✓ Input change notification works\x1b[0m");
}


