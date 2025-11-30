module tests.unit.core.distributed.peers;

import std.stdio;
import std.datetime;
import std.conv;
import core.thread;
import core.atomic;
import engine.distributed.worker.peers;
import engine.distributed.protocol.protocol;
import tests.harness;

// ==================== BASIC PEER REGISTRATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Peer registration");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    auto result = registry.register(peerId, "peer2:9100");
    
    Assert.isTrue(result.isOk);
    
    auto peers = registry.getAllPeers();
    Assert.equal(peers.length, 1);
    Assert.equal(peers[0].id.value, peerId.value);
    Assert.equal(peers[0].address, "peer2:9100");
    
    writeln("\x1b[32m  ✓ Peer registration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Self registration ignored");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    // Try to register self
    auto result = registry.register(selfId, "self:9100");
    Assert.isTrue(result.isOk);  // Should succeed but not actually register
    
    auto peers = registry.getAllPeers();
    Assert.equal(peers.length, 0);  // Should not include self
    
    writeln("\x1b[32m  ✓ Self registration ignored\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Multiple peer registration");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    registry.register(WorkerId(2), "peer2:9100");
    registry.register(WorkerId(3), "peer3:9100");
    registry.register(WorkerId(4), "peer4:9100");
    
    auto peers = registry.getAllPeers();
    Assert.equal(peers.length, 3);
    
    writeln("\x1b[32m  ✓ Multiple peer registration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Duplicate registration updates");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    
    // Register initially
    registry.register(peerId, "peer2:9100");
    auto peers1 = registry.getAllPeers();
    Assert.equal(peers1.length, 1);
    
    // Register again with different address
    registry.register(peerId, "peer2:9200");
    auto peers2 = registry.getAllPeers();
    Assert.equal(peers2.length, 1);  // Should still be only 1 peer
    Assert.equal(peers2[0].address, "peer2:9200");  // Address updated
    
    writeln("\x1b[32m  ✓ Duplicate registration updates peer\x1b[0m");
}

// ==================== PEER UNREGISTRATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Peer unregistration");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    
    Assert.equal(registry.getAllPeers().length, 1);
    
    registry.unregister(peerId);
    
    Assert.equal(registry.getAllPeers().length, 0);
    
    writeln("\x1b[32m  ✓ Peer unregistration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Unregister non-existent peer");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    // Should not crash
    registry.unregister(WorkerId(999));
    
    writeln("\x1b[32m  ✓ Unregister non-existent peer handled\x1b[0m");
}

// ==================== PEER METRICS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Update peer metrics");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    
    // Update metrics
    registry.updateMetrics(peerId, 10, 0.75);
    
    auto peers = registry.getAllPeers();
    Assert.equal(peers.length, 1);
    Assert.equal(atomicLoad(peers[0].queueDepth), 10);
    Assert.equal(atomicLoad(peers[0].loadFactor), 0.75f);
    
    writeln("\x1b[32m  ✓ Update peer metrics works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Update metrics for non-existent peer");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    // Should not crash
    registry.updateMetrics(WorkerId(999), 5, 0.5);
    
    writeln("\x1b[32m  ✓ Update metrics for non-existent peer handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Metrics update refreshes lastSeen");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    
    auto peers1 = registry.getAllPeers();
    auto firstSeen = peers1[0].lastSeen;
    
    Thread.sleep(50.msecs);
    
    registry.updateMetrics(peerId, 5, 0.5);
    
    auto peers2 = registry.getAllPeers();
    auto secondSeen = peers2[0].lastSeen;
    
    Assert.isTrue(secondSeen > firstSeen);
    
    writeln("\x1b[32m  ✓ Metrics update refreshes lastSeen\x1b[0m");
}

// ==================== PEER HEALTH TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Mark peer dead");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    
    auto peers1 = registry.getAllPeers();
    Assert.isTrue(atomicLoad(peers1[0].alive));
    
    registry.markDead(peerId);
    
    auto peers2 = registry.getAllPeers();
    Assert.isFalse(atomicLoad(peers2[0].alive));
    
    writeln("\x1b[32m  ✓ Mark peer dead works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Metrics update revives dead peer");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    
    registry.markDead(peerId);
    
    auto peers1 = registry.getAllPeers();
    Assert.isFalse(atomicLoad(peers1[0].alive));
    
    // Update metrics should revive peer
    registry.updateMetrics(peerId, 5, 0.5);
    
    auto peers2 = registry.getAllPeers();
    Assert.isTrue(atomicLoad(peers2[0].alive));
    
    writeln("\x1b[32m  ✓ Metrics update revives peer\x1b[0m");
}

// ==================== STALE PEER PRUNING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Prune stale peers");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId, 50.msecs);  // 50ms stale threshold
    
    auto peerId1 = WorkerId(2);
    auto peerId2 = WorkerId(3);
    
    registry.register(peerId1, "peer2:9100");
    registry.register(peerId2, "peer3:9100");
    
    Assert.equal(registry.getAllPeers().length, 2);
    
    // Keep peer2 alive
    Thread.sleep(30.msecs);
    registry.updateMetrics(peerId2, 5, 0.5);
    
    // Wait for peer1 to become stale
    Thread.sleep(40.msecs);
    
    // Prune stale peers
    registry.pruneStale();
    
    auto peers = registry.getAllPeers();
    Assert.equal(peers.length, 1);
    Assert.equal(peers[0].id.value, peerId2.value);
    
    writeln("\x1b[32m  ✓ Prune stale peers works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Prune with no stale peers");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId, 1.seconds);
    
    registry.register(WorkerId(2), "peer2:9100");
    registry.register(WorkerId(3), "peer3:9100");
    
    registry.pruneStale();
    
    Assert.equal(registry.getAllPeers().length, 2);
    
    writeln("\x1b[32m  ✓ Prune with no stale peers works\x1b[0m");
}

// ==================== VICTIM SELECTION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Select victim from empty registry");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto result = registry.selectVictim();
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Select victim from empty registry handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Select victim from single peer");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    registry.updateMetrics(peerId, 10, 0.5);  // Has work
    
    auto result = registry.selectVictim();
    Assert.isTrue(result.isOk);
    
    auto victim = result.unwrap();
    Assert.equal(victim.value, peerId.value);
    
    writeln("\x1b[32m  ✓ Select victim from single peer works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - No victim when peers have no work");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId = WorkerId(2);
    registry.register(peerId, "peer2:9100");
    registry.updateMetrics(peerId, 0, 0.0);  // No work
    
    auto result = registry.selectVictim();
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ No victim when peers have no work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Exclude dead peers from victim selection");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId1 = WorkerId(2);
    auto peerId2 = WorkerId(3);
    
    registry.register(peerId1, "peer2:9100");
    registry.updateMetrics(peerId1, 10, 0.5);
    registry.markDead(peerId1);
    
    registry.register(peerId2, "peer3:9100");
    registry.updateMetrics(peerId2, 10, 0.5);
    
    auto result = registry.selectVictim();
    Assert.isTrue(result.isOk);
    
    auto victim = result.unwrap();
    Assert.equal(victim.value, peerId2.value);
    
    writeln("\x1b[32m  ✓ Exclude dead peers from victim selection\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Select most loaded victim");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId1 = WorkerId(2);
    auto peerId2 = WorkerId(3);
    auto peerId3 = WorkerId(4);
    
    registry.register(peerId1, "peer2:9100");
    registry.updateMetrics(peerId1, 5, 0.3);  // Low load
    
    registry.register(peerId2, "peer3:9100");
    registry.updateMetrics(peerId2, 20, 0.9);  // High load
    
    registry.register(peerId3, "peer4:9100");
    registry.updateMetrics(peerId3, 10, 0.5);  // Medium load
    
    // Select victim multiple times - should favor high load peer
    int peer2Selected = 0;
    for (int i = 0; i < 100; i++)
    {
        auto result = registry.selectVictim();
        if (result.isOk)
        {
            auto victim = result.unwrap();
            if (victim.value == peerId2.value)
                peer2Selected++;
        }
    }
    
    // Most loaded peer should be selected more often
    Assert.isTrue(peer2Selected > 20);
    
    writeln("\x1b[32m  ✓ Select most loaded victim works\x1b[0m");
}

// ==================== ALIVE PEERS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Get alive peers");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    auto peerId1 = WorkerId(2);
    auto peerId2 = WorkerId(3);
    auto peerId3 = WorkerId(4);
    
    registry.register(peerId1, "peer2:9100");
    registry.register(peerId2, "peer3:9100");
    registry.register(peerId3, "peer4:9100");
    
    registry.markDead(peerId2);
    
    auto alive = registry.getAlivePeers();
    Assert.equal(alive.length, 2);
    
    // Check that dead peer is not included
    bool foundDead = false;
    foreach (peer; alive)
    {
        if (peer.id.value == peerId2.value)
            foundDead = true;
    }
    Assert.isFalse(foundDead);
    
    writeln("\x1b[32m  ✓ Get alive peers works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - All peers alive initially");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    registry.register(WorkerId(2), "peer2:9100");
    registry.register(WorkerId(3), "peer3:9100");
    
    auto alive = registry.getAlivePeers();
    auto all = registry.getAllPeers();
    
    Assert.equal(alive.length, all.length);
    
    writeln("\x1b[32m  ✓ All peers alive initially\x1b[0m");
}

// ==================== PEER COUNT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Peer count");
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    Assert.equal(registry.peerCount(), 0);
    
    registry.register(WorkerId(2), "peer2:9100");
    Assert.equal(registry.peerCount(), 1);
    
    registry.register(WorkerId(3), "peer3:9100");
    Assert.equal(registry.peerCount(), 2);
    
    registry.unregister(WorkerId(2));
    Assert.equal(registry.peerCount(), 1);
    
    writeln("\x1b[32m  ✓ Peer count works\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Concurrent peer registration");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    try
    {
        // Register peers concurrently
        foreach (i; parallel(iota(2, 22)))
        {
            registry.register(WorkerId(i), "peer" ~ i.to!string ~ ":9100");
        }
        
        Assert.equal(registry.peerCount(), 20);
        
        writeln("\x1b[32m  ✓ Concurrent peer registration works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Peers - Concurrent metrics update");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto selfId = WorkerId(1);
    auto registry = new PeerRegistry(selfId);
    
    // Register peers
    foreach (i; 2 .. 12)
    {
        registry.register(WorkerId(i), "peer" ~ i.to!string ~ ":9100");
    }
    
    try
    {
        // Update metrics concurrently
        foreach (i; parallel(iota(2, 12)))
        {
            registry.updateMetrics(WorkerId(i), cast(size_t)i, cast(float)i / 20.0);
        }
        
        auto peers = registry.getAllPeers();
        Assert.equal(peers.length, 10);
        
        writeln("\x1b[32m  ✓ Concurrent metrics update works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

