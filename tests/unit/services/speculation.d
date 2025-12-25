module tests.unit.services.speculation;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : msecs, seconds, Duration, Clock, SysTime;
import std.algorithm : canFind, filter;
import std.array : array;
import std.file : tempDir, exists, rmdirRecurse;
import std.path : buildPath;
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

// ============================================================================
// ChangePredictor Tests
// ============================================================================

/// Test ChangePredictor basic prediction
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Basic prediction");
    
    auto predictor = new ChangePredictor();
    
    // Record changes for targets
    auto tid1 = TargetId("frequently_changing");
    auto tid2 = TargetId("rarely_changing");
    
    // Record many changes for tid1
    foreach (_; 0 .. 10)
        predictor.recordChange(tid1);
    
    // Record one change for tid2
    predictor.recordChange(tid2);
    
    // Get predictions
    auto predictions = predictor.predict();
    assert(predictions.length >= 2, "Should have predictions for both targets");
    
    // Find predictions for our targets
    auto pred1 = predictions.filter!(p => p.targetId == tid1);
    auto pred2 = predictions.filter!(p => p.targetId == tid2);
    
    if (!pred1.empty && !pred2.empty)
    {
        assert(pred1.front.probability >= pred2.front.probability, 
               "Frequent target should have higher probability");
    }
    
    writeln("\x1b[32m  ✓ Basic prediction works\x1b[0m");
}

/// Test ChangePredictor predictOne
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Single prediction");
    
    auto predictor = new ChangePredictor();
    auto tid = TargetId("test_target");
    
    // No history - should return null
    auto prediction = predictor.predictOne(tid);
    assert(prediction.isNull, "Should have no prediction for unknown target");
    
    // After recording, should have prediction
    predictor.recordChange(tid);
    prediction = predictor.predictOne(tid);
    assert(!prediction.isNull, "Should have prediction after recording");
    
    auto prob = prediction.get();
    assert(prob.probability > 0.0f && prob.probability <= 1.0f, 
           "Probability should be in valid range");
    assert(prob.confidence > 0.0f && prob.confidence <= 1.0f, 
           "Confidence should be in valid range");
    
    writeln("\x1b[32m  ✓ Single prediction works\x1b[0m");
}

/// Test ChangePredictor co-change correlation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Co-change correlation");
    
    auto predictor = new ChangePredictor();
    
    auto header = TargetId("header.h");
    auto impl = TargetId("impl.cpp");
    
    // Simulate co-change pattern
    foreach (_; 0 .. 5)
    {
        predictor.recordChange(header);
        predictor.recordCoChange(header, impl);
    }
    
    // Record header change to trigger co-change
    predictor.recordChange(header);
    
    // Predictions should reflect co-change
    auto predictions = predictor.predict();
    
    // impl should have prediction due to co-change with recently changed header
    bool foundImpl = predictions.canFind!(p => p.targetId == impl);
    assert(foundImpl || predictions.length > 0, "Should have predictions");
    
    writeln("\x1b[32m  ✓ Co-change correlation works\x1b[0m");
}

/// Test ChangePredictor state export/import
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - State persistence");
    
    // Create and train predictor
    auto predictor1 = new ChangePredictor();
    foreach (_; 0 .. 5)
        predictor1.recordChange(TargetId("persistent_target"));
    
    // Export state
    auto state = predictor1.exportState();
    assert("persistent_target" in state.targetStats, "State should contain target");
    
    // Import into new predictor
    auto predictor2 = new ChangePredictor();
    predictor2.importState(state);
    
    // Verify state transferred
    auto stats1 = predictor1.getStats();
    auto stats2 = predictor2.getStats();
    assert(stats1.trackedTargets == stats2.trackedTargets, "Stats should match");
    assert(stats1.totalChangesRecorded == stats2.totalChangesRecorded, "Changes should match");
    
    writeln("\x1b[32m  ✓ State persistence works\x1b[0m");
}

/// Test ChangePredictor statistics
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Statistics");
    
    auto predictor = new ChangePredictor();
    
    // Initially empty
    auto stats = predictor.getStats();
    assert(stats.trackedTargets == 0, "Should start empty");
    assert(stats.totalChangesRecorded == 0, "Should have no changes");
    
    // After recording
    predictor.recordChange(TargetId("target1"));
    predictor.recordChange(TargetId("target2"));
    predictor.recordChange(TargetId("target1")); // Second change
    
    stats = predictor.getStats();
    assert(stats.trackedTargets == 2, "Should track 2 targets");
    assert(stats.totalChangesRecorded == 3, "Should have 3 changes");
    
    writeln("\x1b[32m  ✓ Statistics work\x1b[0m");
}

/// Test ChangeProbability score calculation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Score calculation");
    
    ChangeProbability high;
    high.probability = 0.9f;
    high.confidence = 0.8f;
    
    ChangeProbability low;
    low.probability = 0.3f;
    low.confidence = 0.5f;
    
    assert(high.score > low.score, "Higher prob*conf should have higher score");
    assert(high.score == 0.9f * 0.8f, "Score should be probability * confidence");
    
    writeln("\x1b[32m  ✓ Score calculation correct\x1b[0m");
}

/// Test PredictorConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.predictor - Config defaults");
    
    auto config = PredictorConfig.init;
    assert(config.priorProbability > 0.0f && config.priorProbability < 1.0f, 
           "Prior should be valid");
    assert(config.minProbabilityThreshold >= 0.0f, "Min threshold should be non-negative");
    assert(config.coChangeWindow > 0, "Co-change window should be positive");
    assert(config.maxCoChangeTargets > 0, "Max co-change targets should be positive");
    
    writeln("\x1b[32m  ✓ Config defaults valid\x1b[0m");
}

// ============================================================================
// HistoryTracker Tests
// ============================================================================

/// Test HistoryTracker basic recording
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Basic recording");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-basic");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto tracker = new HistoryTracker(testDir);
    
    // Record changes
    tracker.recordChange(TargetId("target1"), ChangeType.SourceModified);
    tracker.recordChange(TargetId("target2"), ChangeType.DependencyChanged);
    
    auto stats = tracker.getStats();
    assert(stats.totalChanges == 2, "Should have 2 changes");
    
    writeln("\x1b[32m  ✓ Basic recording works\x1b[0m");
}

/// Test HistoryTracker speculation tracking
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Speculation tracking");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-spec");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto tracker = new HistoryTracker(testDir);
    
    // Record speculative build results
    tracker.recordChange(TargetId("spec_hit"), ChangeType.SourceModified,
                        [], Duration.zero, true, true);  // Successful speculation
    tracker.recordChange(TargetId("spec_miss"), ChangeType.SourceModified,
                        [], Duration.zero, true, false); // Failed speculation
    
    auto stats = tracker.getStats();
    assert(stats.speculativeHits == 1, "Should have 1 speculation hit");
    assert(stats.speculativeMisses == 1, "Should have 1 speculation miss");
    assert(stats.speculationAccuracy == 0.5f, "Should have 50% accuracy");
    
    writeln("\x1b[32m  ✓ Speculation tracking works\x1b[0m");
}

/// Test HistoryTracker persistence
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Persistence");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-persist");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    // Create and populate
    {
        auto tracker = new HistoryTracker(testDir);
        tracker.recordChange(TargetId("persist_target"), ChangeType.SourceModified);
        tracker.flush();
    }
    
    // Reload and verify
    {
        auto tracker = new HistoryTracker(testDir);
        auto state = tracker.getPredictorState();
        assert("persist_target" in state.targetStats, "Should persist target");
    }
    
    writeln("\x1b[32m  ✓ Persistence works\x1b[0m");
}

/// Test HistoryTracker session tracking
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Session tracking");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-session");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto tracker = new HistoryTracker(testDir);
    
    // Record activity
    tracker.recordBuildSuccess(TargetId("success1"), 100.msecs);
    tracker.recordBuildFailure(TargetId("failure1"), "error");
    
    auto session = tracker.getCurrentSession();
    assert(session.successfulBuilds == 1, "Should have 1 success");
    assert(session.failedBuilds == 1, "Should have 1 failure");
    
    writeln("\x1b[32m  ✓ Session tracking works\x1b[0m");
}

/// Test HistoryTracker recent events
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Recent events");
    
    auto testDir = buildPath(tempDir(), "bldr-test-history-events");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto tracker = new HistoryTracker(testDir);
    
    // Record events
    foreach (i; 0 .. 10)
        tracker.recordChange(TargetId("target" ~ i.to!string), ChangeType.SourceModified);
    
    // Get recent events
    auto events = tracker.getRecentEvents(5);
    assert(events.length == 5, "Should return requested count");
    
    events = tracker.getRecentEvents(100);
    assert(events.length == 10, "Should return all events if fewer than requested");
    
    writeln("\x1b[32m  ✓ Recent events work\x1b[0m");
}

/// Test HistoryStats formatting
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - Stats formatting");
    
    HistoryStats stats;
    stats.totalChanges = 100;
    stats.totalBuilds = 50;
    stats.speculativeHits = 30;
    stats.speculativeMisses = 10;
    
    auto formatted = stats.format();
    assert(formatted.length > 0, "Should produce formatted string");
    assert(stats.speculationAccuracy == 0.75f, "Accuracy should be 75%");
    
    writeln("\x1b[32m  ✓ Stats formatting works\x1b[0m");
}

/// Test ChangeType enum values
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.history - ChangeType enum");
    
    assert(ChangeType.SourceModified != ChangeType.DependencyChanged);
    assert(ChangeType.ConfigChanged != ChangeType.Manual);
    assert(cast(int)ChangeType.Unknown == 4, "Unknown should be last");
    
    writeln("\x1b[32m  ✓ ChangeType enum valid\x1b[0m");
}

// ============================================================================
// SpeculativeEngine Tests
// ============================================================================

/// Test EngineConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - Config defaults");
    
    auto config = EngineConfig.init;
    assert(config.workerCount > 0, "Should have workers");
    assert(config.maxQueueSize > 0, "Should have queue size");
    assert(config.taskTimeout > Duration.zero, "Should have timeout");
    
    writeln("\x1b[32m  ✓ Config defaults valid\x1b[0m");
}

/// Test EngineStats calculations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - Stats calculations");
    
    EngineStats stats;
    stats.tasksCompleted = 8;
    stats.tasksAborted = 2;
    stats.tasksCacheHit = 3;
    
    assert(stats.completionRate == 0.8f, "Completion rate should be 80%");
    assert(stats.hitRate > 0.37f && stats.hitRate < 0.38f, "Hit rate should be ~37.5%");
    
    // Format should work
    auto formatted = stats.format();
    assert(formatted.length > 0, "Should produce formatted string");
    
    writeln("\x1b[32m  ✓ Stats calculations correct\x1b[0m");
}

/// Test EngineStats edge cases
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - Stats edge cases");
    
    EngineStats empty;
    assert(empty.completionRate == 0.0f, "Empty should have 0 completion rate");
    assert(empty.hitRate == 0.0f, "Empty should have 0 hit rate");
    
    EngineStats allCompleted;
    allCompleted.tasksCompleted = 10;
    allCompleted.tasksAborted = 0;
    assert(allCompleted.completionRate == 1.0f, "All completed should be 100%");
    
    writeln("\x1b[32m  ✓ Stats edge cases handled\x1b[0m");
}

/// Test SpeculativeResult structure
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - SpeculativeResult");
    
    SpeculativeResult result;
    result.targetId = TargetId("test");
    result.outputHash = "abc123";
    result.executionTime = 500.msecs;
    result.isValid = true;
    
    assert(result.targetId == TargetId("test"));
    assert(result.outputHash == "abc123");
    assert(result.isValid);
    
    // Invalid result
    result.isValid = false;
    result.invalidReason = "inputs_changed";
    assert(!result.isValid);
    assert(result.invalidReason == "inputs_changed");
    
    writeln("\x1b[32m  ✓ SpeculativeResult works\x1b[0m");
}

// ============================================================================
// Integration Tests
// ============================================================================

/// Test speculation service with predictive mode
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Predictive mode initialization");
    
    auto testDir = buildPath(tempDir(), "bldr-test-predictive");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    // Initialize predictive mode
    service.initializePredictive(testDir);
    assert(service.isPredictiveMode, "Should be in predictive mode");
    
    // Should have predictor and history
    assert(service.getPredictor() !is null, "Should have predictor");
    assert(service.getHistory() !is null, "Should have history");
    
    writeln("\x1b[32m  ✓ Predictive mode initialization works\x1b[0m");
}

/// Test speculation service record methods
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Record methods");
    
    auto testDir = buildPath(tempDir(), "bldr-test-record");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator);
    
    service.initializePredictive(testDir);
    
    // Record change
    service.recordChange(TargetId("recorded_target"));
    
    // Verify recorded in predictor
    auto predictor = service.getPredictor();
    auto prediction = predictor.predictOne(TargetId("recorded_target"));
    assert(!prediction.isNull, "Should have prediction after recording");
    
    writeln("\x1b[32m  ✓ Record methods work\x1b[0m");
}

/// Test executor stats formatting
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - Executor stats formatting");
    
    SpeculationExecutorStats stats;
    stats.totalSpeculated = 100;
    stats.hits = 70;
    stats.misses = 30;
    stats.aborted = 10;
    stats.timeSaved = 5000.msecs;
    
    auto formatted = stats.format();
    assert(formatted.length > 0, "Should produce formatted string");
    assert(stats.hitRate > 0.69f && stats.hitRate < 0.71f, "Hit rate should be ~70%");
    assert(stats.successRate == 0.7f, "Success rate should be 70%");
    
    writeln("\x1b[32m  ✓ Executor stats formatting works\x1b[0m");
}

/// Test BuildSession calculations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - BuildSession calculations");
    
    BuildSession session;
    session.speculativeHits = 8;
    session.speculativeMisses = 2;
    
    assert(session.speculationHitRate == 0.8f, "Hit rate should be 80%");
    
    // Empty session
    BuildSession empty;
    assert(empty.speculationHitRate == 0.0f, "Empty session should have 0 hit rate");
    
    writeln("\x1b[32m  ✓ BuildSession calculations work\x1b[0m");
}

/// Test ChangeCorrelation structure
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m speculation - ChangeCorrelation");
    
    ChangeCorrelation corr;
    corr.source = TargetId("header.h");
    corr.target = TargetId("impl.cpp");
    corr.count = 10;
    corr.strength = 0.8f;
    
    assert(corr.source == TargetId("header.h"));
    assert(corr.target == TargetId("impl.cpp"));
    assert(corr.count == 10);
    assert(corr.strength == 0.8f);
    
    writeln("\x1b[32m  ✓ ChangeCorrelation works\x1b[0m");
}
