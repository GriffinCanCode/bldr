module tests.unit.core.caching.events_test;

import std.stdio;
import std.datetime;
import core.time;
import engine.caching.events;
import engine.caching.metrics;
import frontend.cli.events.events;
import tests.harness;
import tests.fixtures;

// ==================== EVENT CREATION AND PROPERTIES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - CacheHitEvent creation and properties");
    
    auto event = new CacheHitEvent("test-target", 1024, 10.msecs, false);
    
    Assert.equal(event.cacheType, CacheEventType.Hit);
    Assert.equal(event.targetId, "test-target");
    Assert.equal(event.artifactSize, 1024);
    Assert.equal(event.lookupTime, 10.msecs);
    Assert.isFalse(event.wasRemote);
    Assert.equal(event.type, EventType.Statistics);
    
    writeln("\x1b[32m  ✓ CacheHitEvent properties work correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - CacheMissEvent creation");
    
    auto event = new CacheMissEvent("missing-target", 5.msecs);
    
    Assert.equal(event.cacheType, CacheEventType.Miss);
    Assert.equal(event.targetId, "missing-target");
    Assert.equal(event.lookupTime, 5.msecs);
    
    writeln("\x1b[32m  ✓ CacheMissEvent works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - CacheUpdateEvent creation");
    
    auto event = new CacheUpdateEvent("updated-target", 2048, 15.msecs);
    
    Assert.equal(event.cacheType, CacheEventType.Update);
    Assert.equal(event.targetId, "updated-target");
    Assert.equal(event.artifactSize, 2048);
    Assert.equal(event.updateTime, 15.msecs);
    
    writeln("\x1b[32m  ✓ CacheUpdateEvent works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - CacheEvictionEvent creation");
    
    auto event = new CacheEvictionEvent(10, 10240, 100.msecs);
    
    Assert.equal(event.cacheType, CacheEventType.Evict);
    Assert.equal(event.evictedCount, 10);
    Assert.equal(event.freedBytes, 10240);
    Assert.equal(event.evictionTime, 100.msecs);
    
    writeln("\x1b[32m  ✓ CacheEvictionEvent works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - RemoteCacheEvent creation");
    
    auto hitEvent = new RemoteCacheEvent(
        CacheEventType.RemoteHit, 
        "remote-target", 
        4096, 
        50.msecs, 
        true
    );
    
    Assert.equal(hitEvent.cacheType, CacheEventType.RemoteHit);
    Assert.equal(hitEvent.targetId, "remote-target");
    Assert.equal(hitEvent.artifactSize, 4096);
    Assert.equal(hitEvent.networkTime, 50.msecs);
    Assert.isTrue(hitEvent.success);
    
    auto missEvent = new RemoteCacheEvent(
        CacheEventType.RemoteMiss, 
        "missing-remote", 
        0, 
        25.msecs, 
        false
    );
    
    Assert.equal(missEvent.cacheType, CacheEventType.RemoteMiss);
    Assert.isFalse(missEvent.success);
    
    writeln("\x1b[32m  ✓ RemoteCacheEvent works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - CacheGCEvent creation");
    
    auto startEvent = new CacheGCEvent(
        CacheEventType.GCStarted, 
        0, 
        0, 
        0, 
        0.msecs
    );
    
    Assert.equal(startEvent.cacheType, CacheEventType.GCStarted);
    
    auto completedEvent = new CacheGCEvent(
        CacheEventType.GCCompleted, 
        50, 
        102400, 
        5, 
        500.msecs
    );
    
    Assert.equal(completedEvent.cacheType, CacheEventType.GCCompleted);
    Assert.equal(completedEvent.collectedBlobs, 50);
    Assert.equal(completedEvent.freedBytes, 102400);
    Assert.equal(completedEvent.orphanedArtifacts, 5);
    Assert.equal(completedEvent.gcTime, 500.msecs);
    
    writeln("\x1b[32m  ✓ CacheGCEvent works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - ActionCacheEvent creation");
    
    auto hitEvent = new ActionCacheEvent(
        CacheEventType.ActionHit, 
        "action-123", 
        "target-456", 
        3.msecs
    );
    
    Assert.equal(hitEvent.cacheType, CacheEventType.ActionHit);
    Assert.equal(hitEvent.actionId, "action-123");
    Assert.equal(hitEvent.targetId, "target-456");
    Assert.equal(hitEvent.lookupTime, 3.msecs);
    
    auto missEvent = new ActionCacheEvent(
        CacheEventType.ActionMiss, 
        "action-789", 
        "target-101", 
        2.msecs
    );
    
    Assert.equal(missEvent.cacheType, CacheEventType.ActionMiss);
    
    writeln("\x1b[32m  ✓ ActionCacheEvent works correctly\x1b[0m");
}

// ==================== EVENT TIMING AND TIMESTAMPS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Timestamp generation");
    
    auto before = Clock.currTime();
    auto event = new CacheHitEvent("test", 100, 1.msecs, false);
    auto after = Clock.currTime();
    
    // Timestamp should be between before and after
    Assert.isTrue(event.eventTime >= before);
    Assert.isTrue(event.eventTime <= after);
    
    writeln("\x1b[32m  ✓ Event timestamp generation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Multiple events ordering");
    
    auto event1 = new CacheMissEvent("target1", 1.msecs);
    auto ts1 = event1.eventTime;
    
    // Small delay
    import core.thread : Thread;
    Thread.sleep(5.msecs);
    
    auto event2 = new CacheHitEvent("target2", 200, 2.msecs, false);
    auto ts2 = event2.eventTime;
    
    // Second event should have later timestamp
    Assert.isTrue(ts2 > ts1, "Later events should have later timestamps");
    
    writeln("\x1b[32m  ✓ Event ordering by timestamp works\x1b[0m");
}

// ==================== EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Zero-duration operations");
    
    auto event = new CacheHitEvent("instant-target", 0, 0.msecs, false);
    
    Assert.equal(event.artifactSize, 0);
    Assert.equal(event.lookupTime, 0.msecs);
    
    writeln("\x1b[32m  ✓ Zero-duration events handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Very large artifact sizes");
    
    // Test with very large sizes (e.g., 1 GB)
    size_t largeSize = 1_073_741_824;
    auto event = new CacheUpdateEvent("large-target", largeSize, 1000.msecs);
    
    Assert.equal(event.artifactSize, largeSize);
    
    writeln("\x1b[32m  ✓ Large artifact sizes handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Empty target IDs");
    
    auto event = new CacheMissEvent("", 1.msecs);
    
    Assert.equal(event.targetId, "");
    Assert.equal(event.cacheType, CacheEventType.Miss);
    
    writeln("\x1b[32m  ✓ Empty target IDs handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Failed remote operations");
    
    auto failedPush = new RemoteCacheEvent(
        CacheEventType.RemotePush, 
        "failed-target", 
        1024, 
        100.msecs, 
        false  // Failed
    );
    
    Assert.isFalse(failedPush.success);
    Assert.equal(failedPush.cacheType, CacheEventType.RemotePush);
    
    writeln("\x1b[32m  ✓ Failed remote operations tracked correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - GC with zero collections");
    
    auto noOpGC = new CacheGCEvent(
        CacheEventType.GCCompleted, 
        0,       // No blobs collected
        0,       // No bytes freed
        0,       // No orphaned artifacts
        10.msecs // Still took time
    );
    
    Assert.equal(noOpGC.collectedBlobs, 0);
    Assert.equal(noOpGC.freedBytes, 0);
    Assert.isTrue(noOpGC.gcTime > 0.msecs);
    
    writeln("\x1b[32m  ✓ GC with no collections handled\x1b[0m");
}

// ==================== EVENT POLYMORPHISM ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Event polymorphism");
    
    CacheEvent[] events;
    
    events ~= new CacheHitEvent("target1", 100, 1.msecs, false);
    events ~= new CacheMissEvent("target2", 2.msecs);
    events ~= new CacheUpdateEvent("target3", 200, 3.msecs);
    
    // All should be accessible as base CacheEvent type
    Assert.equal(events.length, 3);
    
    Assert.equal(events[0].cacheType, CacheEventType.Hit);
    Assert.equal(events[1].cacheType, CacheEventType.Miss);
    Assert.equal(events[2].cacheType, CacheEventType.Update);
    
    // All should have BuildEvent type
    foreach (event; events)
    {
        Assert.equal(event.type, EventType.Statistics);
    }
    
    writeln("\x1b[32m  ✓ Event polymorphism works correctly\x1b[0m");
}

// ==================== REALISTIC EVENT SEQUENCES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheEvents - Typical build event sequence");
    
    CacheEvent[] buildSequence;
    
    // Miss on target1
    buildSequence ~= new CacheMissEvent("target1", 5.msecs);
    
    // Build and update
    buildSequence ~= new CacheUpdateEvent("target1", 1024, 100.msecs);
    
    // Hit on target1 (cached now)
    buildSequence ~= new CacheHitEvent("target1", 1024, 2.msecs, false);
    
    // Action cache miss
    buildSequence ~= new ActionCacheEvent(
        CacheEventType.ActionMiss, "action1", "target2", 3.msecs
    );
    
    // Action cache hit after execution
    buildSequence ~= new ActionCacheEvent(
        CacheEventType.ActionHit, "action1", "target2", 1.msecs
    );
    
    // Remote cache operations
    buildSequence ~= new RemoteCacheEvent(
        CacheEventType.RemotePush, "target1", 1024, 50.msecs, true
    );
    
    // GC runs
    buildSequence ~= new CacheGCEvent(
        CacheEventType.GCStarted, 0, 0, 0, 0.msecs
    );
    
    buildSequence ~= new CacheGCEvent(
        CacheEventType.GCCompleted, 10, 10240, 2, 200.msecs
    );
    
    // Eviction due to size limit
    buildSequence ~= new CacheEvictionEvent(5, 5120, 50.msecs);
    
    Assert.equal(buildSequence.length, 9);
    
    // Verify sequence makes sense
    Assert.equal(buildSequence[0].cacheType, CacheEventType.Miss);
    Assert.equal(buildSequence[1].cacheType, CacheEventType.Update);
    Assert.equal(buildSequence[2].cacheType, CacheEventType.Hit);
    
    writeln("\x1b[32m  ✓ Realistic build event sequence validated\x1b[0m");
}

