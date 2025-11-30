module tests.integration.distributed_network_chaos;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown;
import std.conv : to;
import std.algorithm : map, filter, sort, min, max;
import std.array : array;
import std.random : uniform, uniform01, Random;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.registry;
import engine.distributed.protocol.protocol;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Network chaos types
enum NetworkChaosType
{
    PacketLoss,         // Random packet drops
    Latency,            // Network delay
    Jitter,             // Variable latency
    Bandwidth,          // Bandwidth limitation
    Reordering,         // Packets arrive out of order
    Duplication,        // Duplicate packets
    Corruption,         // Corrupted packet data
    BlackHole,          // All packets dropped silently
    SplitBrain,         // Network partition splits cluster
    Asymmetric,         // One-way network failure
}

/// Network chaos configuration
struct NetworkChaosConfig
{
    NetworkChaosType type;
    double probability = 0.3;
    Duration delay = 100.msecs;
    float multiplier = 1.0;
    bool enabled = true;
}

/// Chaotic network layer
class ChaoticNetwork
{
    private NetworkChaosConfig[] chaosConfigs;
    private Random rng;
    private shared size_t packetsProcessed;
    private shared size_t packetsDropped;
    private shared size_t packetsDelayed;
    private shared size_t packetsCorrupted;
    private Mutex mutex;
    
    this()
    {
        this.rng = Random(99999);
        this.mutex = new Mutex();
        atomicStore(packetsProcessed, 0);
        atomicStore(packetsDropped, 0);
        atomicStore(packetsDelayed, 0);
        atomicStore(packetsCorrupted, 0);
    }
    
    void addChaos(NetworkChaosConfig config)
    {
        synchronized (mutex)
        {
            chaosConfigs ~= config;
        }
    }
    
    /// Process packet through chaotic network
    bool processPacket(ref ubyte[] data, string from, string to)
    {
        atomicOp!"+="(packetsProcessed, 1);
        
        synchronized (mutex)
        {
            foreach (config; chaosConfigs)
            {
                if (!config.enabled)
                    continue;
                
                if (uniform01(rng) < config.probability)
                {
                    return applyChaos(config, data, from, to);
                }
            }
        }
        
        return true;  // Packet delivered successfully
    }
    
    private bool applyChaos(NetworkChaosConfig config, ref ubyte[] data, string from, string to)
    {
        final switch (config.type)
        {
            case NetworkChaosType.PacketLoss:
                Logger.info("CHAOS: Packet loss " ~ from ~ " -> " ~ to);
                atomicOp!"+="(packetsDropped, 1);
                return false;  // Drop packet
            
            case NetworkChaosType.Latency:
                Logger.info("CHAOS: Network latency " ~ config.delay.total!"msecs".to!string ~ "ms");
                atomicOp!"+="(packetsDelayed, 1);
                Thread.sleep(config.delay);
                return true;
            
            case NetworkChaosType.Jitter:
                auto jitter = uniform(0, config.delay.total!"msecs", rng);
                Logger.info("CHAOS: Network jitter " ~ jitter.to!string ~ "ms");
                atomicOp!"+="(packetsDelayed, 1);
                Thread.sleep(msecs(jitter));
                return true;
            
            case NetworkChaosType.Bandwidth:
                // Simulate bandwidth limitation with delay
                auto bandwidth_delay = (data.length * 8) / (config.multiplier * 1000);  // Simplified
                Logger.info("CHAOS: Bandwidth limit " ~ bandwidth_delay.to!string ~ "ms");
                atomicOp!"+="(packetsDelayed, 1);
                Thread.sleep(msecs(cast(long)bandwidth_delay));
                return true;
            
            case NetworkChaosType.Reordering:
                Logger.info("CHAOS: Packet reordering");
                // Delay this packet to reorder it
                Thread.sleep(uniform(0, 500, rng).msecs);
                return true;
            
            case NetworkChaosType.Duplication:
                Logger.info("CHAOS: Packet duplication");
                // In real implementation, would send duplicate
                return true;
            
            case NetworkChaosType.Corruption:
                Logger.info("CHAOS: Packet corruption");
                atomicOp!"+="(packetsCorrupted, 1);
                // Corrupt random bytes
                if (data.length > 0)
                {
                    size_t corruptIdx = uniform(0, data.length, rng);
                    data[corruptIdx] = cast(ubyte)uniform(0, 256, rng);
                }
                return true;
            
            case NetworkChaosType.BlackHole:
                Logger.info("CHAOS: Black hole - silent drop");
                atomicOp!"+="(packetsDropped, 1);
                return false;
            
            case NetworkChaosType.SplitBrain:
                Logger.info("CHAOS: Split-brain partition");
                atomicOp!"+="(packetsDropped, 1);
                return false;
            
            case NetworkChaosType.Asymmetric:
                // Drop only one direction
                if (from < to)  // Deterministic asymmetry
                {
                    Logger.info("CHAOS: Asymmetric partition " ~ from ~ " -> " ~ to);
                    atomicOp!"+="(packetsDropped, 1);
                    return false;
                }
                return true;
        }
    }
    
    size_t getPacketsProcessed() const => atomicLoad(packetsProcessed);
    size_t getPacketsDropped() const => atomicLoad(packetsDropped);
    size_t getPacketsDelayed() const => atomicLoad(packetsDelayed);
    size_t getPacketsCorrupted() const => atomicLoad(packetsCorrupted);
}

/// Network partition simulator
class PartitionSimulator
{
    private bool[string][string] connectivity;  // from -> to -> connected
    private Mutex mutex;
    
    this()
    {
        this.mutex = new Mutex();
    }
    
    /// Set connectivity between two nodes
    void setConnectivity(string from, string to, bool connected)
    {
        synchronized (mutex)
        {
            if (from !in connectivity)
                connectivity[from] = null;
            connectivity[from][to] = connected;
        }
    }
    
    /// Check if nodes can communicate
    bool canCommunicate(string from, string to) const
    {
        synchronized (mutex)
        {
            if (from !in connectivity)
                return true;  // Default: connected
            if (to !in connectivity[from])
                return true;
            return connectivity[from][to];
        }
    }
    
    /// Create full partition (split cluster in half)
    void createSplitBrain(string[] group1, string[] group2)
    {
        synchronized (mutex)
        {
            // Group1 can't talk to Group2
            foreach (from; group1)
            {
                foreach (to; group2)
                {
                    setConnectivity(from, to, false);
                    setConnectivity(to, from, false);
                }
            }
        }
    }
    
    /// Heal partition
    void heal()
    {
        synchronized (mutex)
        {
            connectivity.clear();
        }
    }
}

// ============================================================================
// CHAOS TESTS: Distributed Network Partitions
// ============================================================================

/// Test: Network packet loss handling
@("network_chaos.packet_loss")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Packet Loss");
    
    auto network = new ChaoticNetwork();
    
    // Inject 30% packet loss
    NetworkChaosConfig lossChaos;
    lossChaos.type = NetworkChaosType.PacketLoss;
    lossChaos.probability = 0.3;
    network.addChaos(lossChaos);
    
    // Send many packets
    size_t successCount = 0;
    size_t totalPackets = 100;
    
    for (size_t i = 0; i < totalPackets; i++)
    {
        ubyte[] data = [1, 2, 3, 4, 5];
        if (network.processPacket(data, "worker1", "coordinator"))
            successCount++;
    }
    
    Logger.info("Packets delivered: " ~ successCount.to!string ~ "/" ~ totalPackets.to!string);
    Logger.info("Packets dropped: " ~ network.getPacketsDropped().to!string);
    
    // Should lose approximately 30% (with some variance)
    Assert.isTrue(successCount > 50 && successCount < 90, "Should have ~70% delivery rate");
    Assert.isTrue(network.getPacketsDropped() > 0, "Should have dropped packets");
    
    writeln("  \x1b[32m✓ Packet loss test passed\x1b[0m");
}

/// Test: Network latency and jitter
@("network_chaos.latency_jitter")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Latency and Jitter");
    
    auto network = new ChaoticNetwork();
    
    // Inject latency
    NetworkChaosConfig latencyChaos;
    latencyChaos.type = NetworkChaosType.Latency;
    latencyChaos.probability = 0.5;
    latencyChaos.delay = 200.msecs;
    network.addChaos(latencyChaos);
    
    // Inject jitter
    NetworkChaosConfig jitterChaos;
    jitterChaos.type = NetworkChaosType.Jitter;
    jitterChaos.probability = 0.3;
    jitterChaos.delay = 100.msecs;
    network.addChaos(jitterChaos);
    
    // Measure packet delivery time
    auto startTime = MonoTime.currTime;
    
    for (size_t i = 0; i < 10; i++)
    {
        ubyte[] data = [1, 2, 3];
        network.processPacket(data, "worker1", "coordinator");
    }
    
    auto elapsed = MonoTime.currTime - startTime;
    
    Logger.info("10 packets took " ~ elapsed.total!"msecs".to!string ~ "ms");
    Logger.info("Packets delayed: " ~ network.getPacketsDelayed().to!string);
    
    // Should have measurable delay
    Assert.isTrue(elapsed.total!"msecs" > 100, "Should have network delay");
    Assert.isTrue(network.getPacketsDelayed() > 0, "Should have delayed packets");
    
    writeln("  \x1b[32m✓ Latency/jitter test passed\x1b[0m");
}

/// Test: Packet corruption detection
@("network_chaos.corruption")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Packet Corruption");
    
    auto network = new ChaoticNetwork();
    
    // Inject corruption
    NetworkChaosConfig corruptChaos;
    corruptChaos.type = NetworkChaosType.Corruption;
    corruptChaos.probability = 0.5;
    network.addChaos(corruptChaos);
    
    // Send packets and track corruption
    size_t corruptedCount = 0;
    
    for (size_t i = 0; i < 50; i++)
    {
        ubyte[] originalData = [1, 2, 3, 4, 5];
        ubyte[] data = originalData.dup;
        
        network.processPacket(data, "worker1", "coordinator");
        
        if (data != originalData)
            corruptedCount++;
    }
    
    Logger.info("Corrupted packets: " ~ corruptedCount.to!string ~ "/50");
    Logger.info("Network reported corrupted: " ~ network.getPacketsCorrupted().to!string);
    
    Assert.isTrue(corruptedCount > 0, "Should have corrupted packets");
    Assert.equal(corruptedCount, network.getPacketsCorrupted(), "Counts should match");
    
    writeln("  \x1b[32m✓ Packet corruption test passed\x1b[0m");
}

/// Test: Split-brain partition
@("network_chaos.split_brain")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Split-Brain Partition");
    
    auto partition = new PartitionSimulator();
    
    string[] group1 = ["coordinator", "worker1", "worker2"];
    string[] group2 = ["worker3", "worker4", "worker5"];
    
    // Initially all connected
    foreach (from; group1 ~ group2)
    {
        foreach (to; group1 ~ group2)
        {
            Assert.isTrue(partition.canCommunicate(from, to), "Initially all connected");
        }
    }
    
    // Create split-brain
    partition.createSplitBrain(group1, group2);
    
    // Check partition
    foreach (from; group1)
    {
        foreach (to; group2)
        {
            Assert.isFalse(partition.canCommunicate(from, to), 
                          "Groups should be partitioned: " ~ from ~ " -> " ~ to);
        }
    }
    
    // Within groups should still communicate
    Assert.isTrue(partition.canCommunicate("coordinator", "worker1"), 
                 "Same group should communicate");
    Assert.isTrue(partition.canCommunicate("worker3", "worker4"),
                 "Same group should communicate");
    
    // Heal partition
    partition.heal();
    
    foreach (from; group1)
    {
        foreach (to; group2)
        {
            Assert.isTrue(partition.canCommunicate(from, to), 
                         "Should reconnect after healing");
        }
    }
    
    writeln("  \x1b[32m✓ Split-brain test passed\x1b[0m");
}

/// Test: Asymmetric network failure
@("network_chaos.asymmetric")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Asymmetric Failure");
    
    auto network = new ChaoticNetwork();
    
    // Inject asymmetric failure
    NetworkChaosConfig asymmetricChaos;
    asymmetricChaos.type = NetworkChaosType.Asymmetric;
    asymmetricChaos.probability = 1.0;
    network.addChaos(asymmetricChaos);
    
    // Test both directions
    ubyte[] data1 = [1, 2, 3];
    ubyte[] data2 = [1, 2, 3];
    
    bool forward = network.processPacket(data1, "worker1", "worker2");
    bool backward = network.processPacket(data2, "worker2", "worker1");
    
    Logger.info("Forward (worker1 -> worker2): " ~ (forward ? "delivered" : "dropped"));
    Logger.info("Backward (worker2 -> worker1): " ~ (backward ? "delivered" : "dropped"));
    
    // One direction should fail, other should succeed
    Assert.isTrue(forward != backward, "Should be asymmetric");
    
    writeln("  \x1b[32m✓ Asymmetric failure test passed\x1b[0m");
}

/// Test: Bandwidth limitation
@("network_chaos.bandwidth")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Bandwidth Limitation");
    
    auto network = new ChaoticNetwork();
    
    // Inject bandwidth limit
    NetworkChaosConfig bandwidthChaos;
    bandwidthChaos.type = NetworkChaosType.Bandwidth;
    bandwidthChaos.probability = 1.0;
    bandwidthChaos.multiplier = 10.0;  // 10 KB/s
    network.addChaos(bandwidthChaos);
    
    // Send large packet
    ubyte[] largeData = new ubyte[10000];  // 10 KB
    
    auto startTime = MonoTime.currTime;
    bool delivered = network.processPacket(largeData, "worker1", "coordinator");
    auto elapsed = MonoTime.currTime - startTime;
    
    Logger.info("10KB packet took " ~ elapsed.total!"msecs".to!string ~ "ms");
    
    Assert.isTrue(delivered, "Should deliver packet");
    Assert.isTrue(elapsed.total!"msecs" > 100, "Should be bandwidth-limited");
    
    writeln("  \x1b[32m✓ Bandwidth limitation test passed\x1b[0m");
}

/// Test: Packet reordering
@("network_chaos.reordering")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Packet Reordering");
    
    auto network = new ChaoticNetwork();
    
    // Inject reordering
    NetworkChaosConfig reorderChaos;
    reorderChaos.type = NetworkChaosType.Reordering;
    reorderChaos.probability = 0.5;
    network.addChaos(reorderChaos);
    
    // Send sequence of packets
    size_t[] deliveryOrder;
    
    for (size_t i = 0; i < 20; i++)
    {
        ubyte[] data = [cast(ubyte)i];
        
        auto startTime = MonoTime.currTime;
        bool delivered = network.processPacket(data, "worker1", "coordinator");
        auto elapsed = MonoTime.currTime - startTime;
        
        if (delivered)
        {
            deliveryOrder ~= elapsed.total!"msecs";
        }
    }
    
    // Check if packets arrived out of order (variable latency)
    bool hasReordering = false;
    for (size_t i = 1; i < deliveryOrder.length; i++)
    {
        if (deliveryOrder[i] < deliveryOrder[i-1])
        {
            hasReordering = true;
            break;
        }
    }
    
    Logger.info("Delivery times (variance indicates reordering): " ~ deliveryOrder.to!string);
    
    writeln("  \x1b[32m✓ Packet reordering test passed\x1b[0m");
}

/// Test: Black hole (silent drops)
@("network_chaos.blackhole")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Black Hole");
    
    auto network = new ChaoticNetwork();
    
    // Inject black hole
    NetworkChaosConfig blackholeChaos;
    blackholeChaos.type = NetworkChaosType.BlackHole;
    blackholeChaos.probability = 1.0;
    network.addChaos(blackholeChaos);
    
    // Send packets into black hole
    size_t successCount = 0;
    
    for (size_t i = 0; i < 10; i++)
    {
        ubyte[] data = [1, 2, 3];
        if (network.processPacket(data, "worker1", "coordinator"))
            successCount++;
    }
    
    Logger.info("Black hole: " ~ successCount.to!string ~ "/10 packets delivered");
    Logger.info("Packets dropped: " ~ network.getPacketsDropped().to!string);
    
    // All packets should be silently dropped
    Assert.equal(successCount, 0, "Black hole should drop all packets");
    Assert.equal(network.getPacketsDropped(), 10, "Should report 10 drops");
    
    writeln("  \x1b[32m✓ Black hole test passed\x1b[0m");
}

/// Test: Combined network chaos stress
@("network_chaos.combined_stress")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Combined Stress Test");
    
    auto network = new ChaoticNetwork();
    
    // Enable all chaos types with varying probabilities
    network.addChaos(NetworkChaosConfig(NetworkChaosType.PacketLoss, 0.1, 0.msecs, 1.0, true));
    network.addChaos(NetworkChaosConfig(NetworkChaosType.Latency, 0.2, 50.msecs, 1.0, true));
    network.addChaos(NetworkChaosConfig(NetworkChaosType.Jitter, 0.15, 100.msecs, 1.0, true));
    network.addChaos(NetworkChaosConfig(NetworkChaosType.Corruption, 0.05, 0.msecs, 1.0, true));
    network.addChaos(NetworkChaosConfig(NetworkChaosType.Reordering, 0.1, 0.msecs, 1.0, true));
    
    // Hammer network with traffic
    size_t totalPackets = 200;
    size_t successCount = 0;
    
    auto startTime = MonoTime.currTime;
    
    for (size_t i = 0; i < totalPackets; i++)
    {
        ubyte[] data = [1, 2, 3, 4, 5];
        if (network.processPacket(data, "worker" ~ (i % 5).to!string, "coordinator"))
            successCount++;
    }
    
    auto elapsed = MonoTime.currTime - startTime;
    
    Logger.info("Results:");
    Logger.info("  Total packets: " ~ totalPackets.to!string);
    Logger.info("  Delivered: " ~ successCount.to!string);
    Logger.info("  Dropped: " ~ network.getPacketsDropped().to!string);
    Logger.info("  Delayed: " ~ network.getPacketsDelayed().to!string);
    Logger.info("  Corrupted: " ~ network.getPacketsCorrupted().to!string);
    Logger.info("  Time: " ~ elapsed.total!"msecs".to!string ~ "ms");
    
    // Should deliver most packets despite chaos
    Assert.isTrue(successCount > totalPackets / 2, "Should deliver majority of packets");
    Assert.isTrue(network.getPacketsDropped() > 0, "Should have dropped some");
    Assert.isTrue(network.getPacketsDelayed() > 0, "Should have delayed some");
    
    writeln("  \x1b[32m✓ Combined stress test passed\x1b[0m");
}

/// Test: Partition healing and recovery
@("network_chaos.partition_healing")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Network - Partition Healing");
    
    auto partition = new PartitionSimulator();
    
    string[] group1 = ["coordinator", "worker1"];
    string[] group2 = ["worker2", "worker3"];
    
    // Create partition
    partition.createSplitBrain(group1, group2);
    
    // Verify partition
    Assert.isFalse(partition.canCommunicate("coordinator", "worker2"), 
                  "Should be partitioned");
    Assert.isFalse(partition.canCommunicate("worker1", "worker3"),
                  "Should be partitioned");
    
    // Heal partition
    Logger.info("Healing partition...");
    partition.heal();
    
    // Verify healing
    Assert.isTrue(partition.canCommunicate("coordinator", "worker2"),
                 "Should be healed");
    Assert.isTrue(partition.canCommunicate("worker1", "worker3"),
                 "Should be healed");
    Assert.isTrue(partition.canCommunicate("coordinator", "worker3"),
                 "Should be fully connected");
    
    writeln("  \x1b[32m✓ Partition healing test passed\x1b[0m");
}

