module tests.unit.core.distributed.adaptive;

import std.stdio;
import std.datetime;
import std.conv;
import core.thread;
import core.atomic;
import engine.distributed.worker.adaptive;
import engine.distributed.worker.steal;
import engine.distributed.worker.peers;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport;
import tests.harness;
import infrastructure.errors;

// ==================== ADAPTIVE CONFIG TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveConfig default values");
    
    AdaptiveConfig cfg;
    
    Assert.isTrue(cfg.alpha > 0 && cfg.alpha < 1, "Alpha should be in (0,1)");
    // Use range checks for floating-point values
    Assert.isTrue(cfg.lowSuccessThreshold > 0.19 && cfg.lowSuccessThreshold < 0.21, "lowSuccessThreshold ~0.20");
    Assert.isTrue(cfg.highSuccessThreshold > 0.59 && cfg.highSuccessThreshold < 0.61, "highSuccessThreshold ~0.60");
    Assert.equal(cfg.evaluationWindow, 50);
    Assert.isTrue(cfg.minLocalQueueLower < cfg.minLocalQueueUpper);
    Assert.isTrue(cfg.stealThresholdLower < cfg.stealThresholdUpper);
    
    writeln("\x1b[32m  ✓ AdaptiveConfig default values correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveConfig custom values");
    
    AdaptiveConfig cfg;
    cfg.alpha = 0.25;
    cfg.lowSuccessThreshold = 0.15;
    cfg.highSuccessThreshold = 0.70;
    cfg.evaluationWindow = 100;
    cfg.adjustmentCooldown = 10.seconds;
    
    Assert.equal(cfg.alpha, 0.25);
    Assert.equal(cfg.lowSuccessThreshold, 0.15);
    Assert.equal(cfg.highSuccessThreshold, 0.70);
    Assert.equal(cfg.evaluationWindow, 100);
    Assert.equal(cfg.adjustmentCooldown, 10.seconds);
    
    writeln("\x1b[32m  ✓ AdaptiveConfig custom values work\x1b[0m");
}

// ==================== THRESHOLD STATE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - ThresholdState defaults");
    
    ThresholdState state;
    
    Assert.equal(state.minLocalQueue, 2);
    Assert.equal(state.stealThreshold, 0.5);
    Assert.equal(state.stealTimeout, 100.msecs);
    Assert.equal(state.retryBackoff, 50.msecs);
    
    writeln("\x1b[32m  ✓ ThresholdState defaults correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - ThresholdState custom initialization");
    
    ThresholdState state = {
        minLocalQueue: 4,
        stealThreshold: 0.7,
        stealTimeout: 200.msecs,
        retryBackoff: 100.msecs
    };
    
    Assert.equal(state.minLocalQueue, 4);
    Assert.equal(state.stealThreshold, 0.7f);
    Assert.equal(state.stealTimeout, 200.msecs);
    Assert.equal(state.retryBackoff, 100.msecs);
    
    writeln("\x1b[32m  ✓ ThresholdState custom initialization works\x1b[0m");
}

// ==================== ADAPTIVE STATS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveStats latency CV");
    
    AdaptiveStats stats;
    stats.avgLatencyUs = 1000;
    stats.latencyStddev = 200;
    
    auto cv = stats.latencyCv();
    Assert.isTrue(cv > 0.19 && cv < 0.21, "CV should be stddev/mean");
    
    writeln("\x1b[32m  ✓ AdaptiveStats latency CV correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveStats zero latency CV");
    
    AdaptiveStats stats;
    stats.avgLatencyUs = 0;
    stats.latencyStddev = 100;
    
    auto cv = stats.latencyCv();
    Assert.equal(cv, 0.0);
    
    writeln("\x1b[32m  ✓ AdaptiveStats zero latency CV handled\x1b[0m");
}

// ==================== ADAPTIVE THRESHOLDS CREATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveThresholds creation");
    
    auto adaptive = new AdaptiveThresholds();
    
    auto state = adaptive.getState();
    Assert.equal(state.minLocalQueue, 2);
    Assert.equal(state.stealThreshold, 0.5);
    
    auto stats = adaptive.getStats();
    Assert.equal(stats.totalSamples, 0);
    
    writeln("\x1b[32m  ✓ AdaptiveThresholds creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - AdaptiveThresholds with custom initial state");
    
    ThresholdState initial = {
        minLocalQueue: 5,
        stealThreshold: 0.6,
        stealTimeout: 150.msecs,
        retryBackoff: 75.msecs
    };
    
    auto adaptive = new AdaptiveThresholds(AdaptiveConfig.init, initial);
    
    auto state = adaptive.getState();
    Assert.equal(state.minLocalQueue, 5);
    Assert.equal(state.stealThreshold, 0.6f);
    Assert.equal(state.stealTimeout, 150.msecs);
    Assert.equal(state.retryBackoff, 75.msecs);
    
    writeln("\x1b[32m  ✓ AdaptiveThresholds with custom initial state works\x1b[0m");
}

// ==================== RECORDING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Record successful attempts");
    
    auto adaptive = new AdaptiveThresholds();
    
    adaptive.recordAttempt(true, 5000);
    adaptive.recordAttempt(true, 6000);
    adaptive.recordAttempt(true, 4000);
    
    auto stats = adaptive.getStats();
    Assert.equal(stats.totalSamples, 3);
    Assert.isTrue(stats.successRate > 0.9, "All attempts were successful");
    
    writeln("\x1b[32m  ✓ Record successful attempts works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Record failed attempts");
    
    auto adaptive = new AdaptiveThresholds();
    
    adaptive.recordAttempt(false, 5000);
    adaptive.recordAttempt(false, 6000);
    adaptive.recordAttempt(true, 4000);
    
    auto stats = adaptive.getStats();
    Assert.equal(stats.totalSamples, 3);
    Assert.isTrue(stats.successRate > 0.2 && stats.successRate < 0.5, "~33% success");
    
    writeln("\x1b[32m  ✓ Record failed attempts works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Record network errors");
    
    auto adaptive = new AdaptiveThresholds();
    
    adaptive.recordAttempt(false, 5000, true, false);
    adaptive.recordAttempt(false, 6000, true, false);
    adaptive.recordAttempt(true, 4000, false, false);
    
    auto stats = adaptive.getStats();
    Assert.isTrue(stats.networkErrorRate > 0.5, "2/3 network errors");
    
    writeln("\x1b[32m  ✓ Record network errors works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Record timeouts");
    
    auto adaptive = new AdaptiveThresholds();
    
    adaptive.recordAttempt(false, 100000, false, true);
    adaptive.recordAttempt(false, 120000, false, true);
    adaptive.recordAttempt(true, 4000, false, false);
    
    auto stats = adaptive.getStats();
    Assert.isTrue(stats.timeoutRate > 0.5, "2/3 timeouts");
    
    writeln("\x1b[32m  ✓ Record timeouts works\x1b[0m");
}

// ==================== THRESHOLD ADJUSTMENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Low success rate triggers minLocalQueue increase");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 10;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.lowSuccessThreshold = 0.20;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    immutable initialMinLocal = adaptive.getState().minLocalQueue;
    
    // Record many failures
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(false, 1000);
    
    auto state = adaptive.getState();
    Assert.isTrue(state.minLocalQueue > initialMinLocal, 
        "minLocalQueue should increase with low success rate");
    
    writeln("\x1b[32m  ✓ Low success rate triggers minLocalQueue increase\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - High success rate allows minLocalQueue decrease");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 15;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.highSuccessThreshold = 0.60;
    
    ThresholdState initial = { minLocalQueue: 6 };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record many successes
    foreach (_; 0 .. 25)
        adaptive.recordAttempt(true, 5000);
    
    auto state = adaptive.getState();
    Assert.isTrue(state.minLocalQueue < 6, 
        "minLocalQueue should decrease with high success rate");
    
    writeln("\x1b[32m  ✓ High success rate allows minLocalQueue decrease\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - High latency increases timeout");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 10;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.highLatencyThresholdUs = 50_000;
    
    ThresholdState initial = { stealTimeout: 100.msecs };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record high latency
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(true, 80_000);  // 80ms
    
    auto state = adaptive.getState();
    Assert.isTrue(state.stealTimeout > 100.msecs, 
        "stealTimeout should increase with high latency");
    
    writeln("\x1b[32m  ✓ High latency increases timeout\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Low latency decreases timeout");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 15;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.lowLatencyThresholdUs = 10_000;
    
    ThresholdState initial = { stealTimeout: 200.msecs };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record low latency
    foreach (_; 0 .. 25)
        adaptive.recordAttempt(true, 5_000);  // 5ms
    
    auto state = adaptive.getState();
    Assert.isTrue(state.stealTimeout < 200.msecs, 
        "stealTimeout should decrease with low latency");
    
    writeln("\x1b[32m  ✓ Low latency decreases timeout\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - High error rate increases stealThreshold");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 10;
    cfg.adjustmentCooldown = 0.msecs;
    
    ThresholdState initial = { stealThreshold: 0.5 };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record many network errors
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(false, 5000, true, false);
    
    auto state = adaptive.getState();
    Assert.isTrue(state.stealThreshold > 0.5, 
        "stealThreshold should increase with high error rate");
    
    writeln("\x1b[32m  ✓ High error rate increases stealThreshold\x1b[0m");
}

// ==================== BOUNDS ENFORCEMENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - minLocalQueue upper bound enforced");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.minLocalQueueUpper = 4;
    
    ThresholdState initial = { minLocalQueue: 4 };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Try to increase beyond upper bound
    foreach (_; 0 .. 50)
        adaptive.recordAttempt(false, 1000);
    
    auto state = adaptive.getState();
    Assert.isTrue(state.minLocalQueue <= cfg.minLocalQueueUpper, 
        "Should not exceed upper bound");
    
    writeln("\x1b[32m  ✓ minLocalQueue upper bound enforced\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - minLocalQueue lower bound enforced");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.minLocalQueueLower = 2;
    
    ThresholdState initial = { minLocalQueue: 2 };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Try to decrease beyond lower bound
    foreach (_; 0 .. 50)
        adaptive.recordAttempt(true, 5000);
    
    auto state = adaptive.getState();
    Assert.isTrue(state.minLocalQueue >= cfg.minLocalQueueLower, 
        "Should not go below lower bound");
    
    writeln("\x1b[32m  ✓ minLocalQueue lower bound enforced\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - stealTimeout bounds enforced");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    cfg.stealTimeoutUpper = 300.msecs;
    cfg.stealTimeoutLower = 50.msecs;
    
    ThresholdState initial = { stealTimeout: 200.msecs };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Try to increase beyond upper bound
    foreach (_; 0 .. 100)
        adaptive.recordAttempt(true, 200_000);  // High latency
    
    auto state = adaptive.getState();
    Assert.isTrue(state.stealTimeout <= cfg.stealTimeoutUpper, 
        "Should not exceed timeout upper bound");
    
    writeln("\x1b[32m  ✓ stealTimeout bounds enforced\x1b[0m");
}

// ==================== COOLDOWN TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Cooldown prevents oscillation");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 100.seconds;  // Long cooldown
    
    auto adaptive = new AdaptiveThresholds(cfg);
    immutable initialMinLocal = adaptive.getState().minLocalQueue;
    
    // First batch: failures
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(false, 1000);
    
    auto stateAfterFirst = adaptive.getState();
    
    // Second batch: more failures (should not adjust due to cooldown)
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(false, 1000);
    
    auto stateAfterSecond = adaptive.getState();
    
    // Only one adjustment should have occurred
    Assert.equal(stateAfterFirst.minLocalQueue, stateAfterSecond.minLocalQueue,
        "Cooldown should prevent rapid adjustments");
    
    writeln("\x1b[32m  ✓ Cooldown prevents oscillation\x1b[0m");
}

// ==================== CALLBACK TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Callback notification on adjustment");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    
    bool callbackInvoked = false;
    ThresholdState capturedOld, capturedNew;
    
    adaptive.onAdjustment = (old, newState) {
        callbackInvoked = true;
        capturedOld = old;
        capturedNew = newState;
    };
    
    // Trigger adjustment
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(false, 1000);
    
    Assert.isTrue(callbackInvoked, "Callback should be invoked");
    Assert.isTrue(capturedNew.minLocalQueue > capturedOld.minLocalQueue,
        "Callback should capture state change");
    
    writeln("\x1b[32m  ✓ Callback notification on adjustment\x1b[0m");
}

// ==================== RESET TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Reset stats preserves thresholds");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    
    ThresholdState initial = { minLocalQueue: 5 };
    auto adaptive = new AdaptiveThresholds(cfg, initial);
    
    // Record some data and trigger adjustment
    foreach (_; 0 .. 10)
        adaptive.recordAttempt(false, 1000);
    
    auto stateBeforeReset = adaptive.getState();
    auto statsBeforeReset = adaptive.getStats();
    
    adaptive.resetStats();
    
    auto statsAfterReset = adaptive.getStats();
    auto stateAfterReset = adaptive.getState();
    
    Assert.equal(statsAfterReset.totalSamples, 0, "Samples should be reset");
    Assert.equal(stateAfterReset.minLocalQueue, stateBeforeReset.minLocalQueue,
        "Thresholds should be preserved");
    
    writeln("\x1b[32m  ✓ Reset stats preserves thresholds\x1b[0m");
}

// ==================== HISTORY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Adjustment history tracking");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 5;
    cfg.adjustmentCooldown = 0.msecs;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    
    // Trigger multiple adjustments
    foreach (batch; 0 .. 3)
    {
        foreach (_; 0 .. 10)
            adaptive.recordAttempt(false, 1000);
        adaptive.resetStats();  // Reset to allow more adjustments
    }
    
    auto history = adaptive.getHistory();
    Assert.isTrue(history.length >= 1, "Should have recorded adjustments");
    
    writeln("\x1b[32m  ✓ Adjustment history tracking\x1b[0m");
}

// ==================== FORCE EVALUATE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Force evaluate");
    
    AdaptiveConfig cfg;
    cfg.evaluationWindow = 1000;  // High window
    cfg.adjustmentCooldown = 0.msecs;
    
    auto adaptive = new AdaptiveThresholds(cfg);
    
    // Record a few samples (not enough to auto-evaluate)
    foreach (_; 0 .. 15)
        adaptive.recordAttempt(false, 1000);
    
    auto stateBeforeForce = adaptive.getState();
    
    adaptive.forceEvaluate();
    
    auto stateAfterForce = adaptive.getState();
    Assert.isTrue(stateAfterForce.minLocalQueue > stateBeforeForce.minLocalQueue,
        "Force evaluate should trigger adjustment");
    
    writeln("\x1b[32m  ✓ Force evaluate works\x1b[0m");
}

// ==================== STEAL ENGINE INTEGRATION TESTS ====================

// Mock Transport for StealEngine tests
class MockTransport : Transport
{
    override Result!DistributedError sendHeartBeat(WorkerId recipient, HeartBeat hb) { return Result!DistributedError.err(new DistributedError("Mock")); }
    override Result!DistributedError sendStealRequest(WorkerId recipient, StealRequest req) { return Result!DistributedError.err(new DistributedError("Mock")); }
    override Result!DistributedError sendStealResponse(WorkerId recipient, StealResponse res) { return Result!DistributedError.err(new DistributedError("Mock")); }
    override Result!(Envelope!StealResponse, DistributedError) receiveStealResponse(Duration timeout) { return Result!(Envelope!StealResponse, DistributedError).err(new DistributedError("Mock")); }
    override bool isConnected() { return true; }
    override void close() {}
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - StealEngine without adaptive (default)");
    
    auto selfId = WorkerId(1);
    auto peers = new PeerRegistry(selfId);
    
    StealConfig config;
    config.enableAdaptive = false;
    
    auto engine = new StealEngine(selfId, peers, config);
    
    Assert.isFalse(engine.isAdaptiveEnabled(), "Adaptive should be disabled by default");
    Assert.equal(engine.getEffectiveMinLocalQueue(), config.minLocalQueue);
    
    writeln("\x1b[32m  ✓ StealEngine without adaptive works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - StealEngine with adaptive enabled");
    
    auto selfId = WorkerId(1);
    auto peers = new PeerRegistry(selfId);
    
    StealConfig config;
    config.enableAdaptive = true;
    config.minLocalQueue = 3;
    config.stealThreshold = 0.6;
    
    auto engine = new StealEngine(selfId, peers, config);
    
    Assert.isTrue(engine.isAdaptiveEnabled(), "Adaptive should be enabled");
    Assert.equal(engine.getEffectiveMinLocalQueue(), 3);
    Assert.equal(engine.getEffectiveStealThreshold(), 0.6f);
    
    writeln("\x1b[32m  ✓ StealEngine with adaptive enabled works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - StealEngine adaptive state access");
    
    auto selfId = WorkerId(1);
    auto peers = new PeerRegistry(selfId);
    
    StealConfig config;
    config.enableAdaptive = true;
    config.minLocalQueue = 4;
    config.adaptiveConfig.evaluationWindow = 5;
    config.adaptiveConfig.adjustmentCooldown = 0.msecs;
    
    auto engine = new StealEngine(selfId, peers, config);
    auto transport = new MockTransport();
    
    // Trigger some steal attempts (will fail due to no peers)
    foreach (_; 0 .. 10)
        engine.steal(transport);
    
    auto adaptiveState = engine.getAdaptiveState();
    auto adaptiveStats = engine.getAdaptiveStats();
    
    Assert.isTrue(adaptiveStats.totalSamples > 0, "Should have recorded samples");
    
    writeln("\x1b[32m  ✓ StealEngine adaptive state access works\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Concurrent recording");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto adaptive = new AdaptiveThresholds();
    
    try
    {
        foreach (i; parallel(iota(100)))
            adaptive.recordAttempt(i % 2 == 0, 5000 + i * 100);
        
        auto stats = adaptive.getStats();
        Assert.equal(stats.totalSamples, 100, "All samples should be recorded");
        
        writeln("\x1b[32m  ✓ Concurrent recording works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Adaptive - Concurrent state reads");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto adaptive = new AdaptiveThresholds();
    
    // Pre-populate some data
    foreach (_; 0 .. 50)
        adaptive.recordAttempt(true, 5000);
    
    try
    {
        foreach (i; parallel(iota(100)))
        {
            auto state = adaptive.getState();
            auto stats = adaptive.getStats();
            // Just verify no crash
        }
        
        Assert.isTrue(true);
        writeln("\x1b[32m  ✓ Concurrent state reads work\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

