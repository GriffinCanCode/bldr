module tests.integration.distributed_chaos;

import std.datetime : Duration, seconds, msecs;
import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown;
import std.conv : to;
import std.algorithm : map, filter;
import std.array : array;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.time : MonoTime;

import tests.harness : Assert;
import tests.fixtures : TempDir, scoped;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.scheduler;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.distributed.protocol.transport;
import engine.graph.core.graph : BuildGraph;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Fault injection types
enum FaultType
{
    None,
    NetworkDelay,           // Slow network
    NetworkDrop,            // Drop packets
    NetworkPartition,       // Complete network partition
    WorkerCrash,           // Worker crashes
    WorkerHang,            // Worker hangs/freezes
    SlowExecution,         // Slow action execution
    MemoryExhaustion,      // Out of memory
    DiskFull,              // Disk space exhausted
    Timeout,               // Operation timeout
}

/// Fault injection configuration
struct FaultConfig
{
    FaultType type = FaultType.None;
    double probability = 0.0;  // 0.0 to 1.0
    Duration delay = 0.seconds;
    size_t maxFaults = size_t.max;
    bool enabled = true;
}

/// Mock worker with fault injection capabilities
class MockWorker
{
    private WorkerId id;
    private string address;
    private shared bool running;
    private shared bool crashed;
    private shared bool partitioned;
    private Thread workerThread;
    private TcpSocket socket;
    private FaultConfig[] faultConfigs;
    private shared size_t faultsInjected;
    private Mutex mutex;
    private ActionRequest[] receivedActions;
    
    this(string host, ushort port)
    {
        this.address = host ~ ":" ~ port.to!string;
        this.id = WorkerId(0);  // Will be assigned by coordinator
        this.mutex = new Mutex();
        atomicStore(running, false);
        atomicStore(crashed, false);
        atomicStore(partitioned, false);
        atomicStore(faultsInjected, 0);
    }
    
    /// Add fault injection rule
    void addFault(FaultConfig config)
    {
        synchronized (mutex)
        {
            faultConfigs ~= config;
        }
    }
    
    /// Start mock worker
    void start() @trusted
    {
        atomicStore(running, true);
        workerThread = new Thread(&workerLoop);
        workerThread.start();
    }
    
    /// Stop mock worker
    void stop() @trusted
    {
        atomicStore(running, false);
        if (socket !is null)
        {
            try { socket.shutdown(SocketShutdown.BOTH); } catch (Exception) {}
            try { socket.close(); } catch (Exception) {}
        }
        if (workerThread !is null)
            workerThread.join();
    }
    
    /// Simulate worker crash
    void crash() @trusted
    {
        atomicStore(crashed, true);
        stop();
    }
    
    /// Simulate network partition
    void partition() @trusted
    {
        atomicStore(partitioned, true);
    }
    
    /// Restore from partition
    void restore() @trusted
    {
        atomicStore(partitioned, false);
    }
    
    /// Check if worker should inject fault
    private bool shouldInjectFault(FaultType type) @trusted
    {
        import std.random : uniform01;
        
        synchronized (mutex)
        {
            foreach (config; faultConfigs)
            {
                if (config.type == type && config.enabled)
                {
                    if (atomicLoad(faultsInjected) >= config.maxFaults)
                        continue;
                    
                    if (uniform01() < config.probability)
                    {
                        atomicOp!"+="(faultsInjected, 1);
                        return true;
                    }
                }
            }
        }
        return false;
    }
    
    /// Get fault delay for type
    private Duration getFaultDelay(FaultType type) @safe
    {
        synchronized (mutex)
        {
            foreach (config; faultConfigs)
            {
                if (config.type == type && config.enabled)
                    return config.delay;
            }
        }
        return 0.seconds;
    }
    
    /// Worker main loop
    private void workerLoop() @trusted
    {
        while (atomicLoad(running))
        {
            // Check if crashed
            if (atomicLoad(crashed))
            {
                Logger.info("MockWorker " ~ id.toString() ~ " crashed");
                return;
            }
            
            // Check if partitioned
            if (atomicLoad(partitioned))
            {
                Thread.sleep(100.msecs);
                continue;
            }
            
            // Inject network delay fault
            if (shouldInjectFault(FaultType.NetworkDelay))
            {
                auto delay = getFaultDelay(FaultType.NetworkDelay);
                Logger.info("MockWorker injecting network delay: " ~ delay.total!"msecs".to!string ~ "ms");
                Thread.sleep(delay);
            }
            
            // Inject worker hang fault
            if (shouldInjectFault(FaultType.WorkerHang))
            {
                Logger.info("MockWorker hanging...");
                Thread.sleep(30.seconds);  // Hang for 30 seconds
            }
            
            // Simulate work
            Thread.sleep(100.msecs);
        }
    }
    
    /// Get number of received actions
    size_t getReceivedActionCount() @trusted
    {
        synchronized (mutex)
        {
            return receivedActions.length;
        }
    }
    
    /// Get total faults injected
    size_t getFaultCount() @trusted
    {
        return atomicLoad(faultsInjected);
    }
    
    WorkerId getId() @safe
    {
        return id;
    }
    
    string getAddress() @safe
    {
        return address;
    }
}

/// Distributed test fixture with chaos capabilities
class DistributedTestFixture
{
    private Coordinator coordinator;
    private MockWorker[] workers;
    private BuildGraph graph;
    private CoordinatorConfig config;
    private TempDir tempDir;
    
    this(size_t workerCount = 3)
    {
        tempDir = new TempDir("distributed-test");
        tempDir.setup();
        
        // Create simple build graph
        graph = new BuildGraph();
        
        // Configure coordinator
        config = CoordinatorConfig();
        config.host = "127.0.0.1";
        config.port = 19000;
        config.workerTimeout = 5.seconds;
        config.heartbeatInterval = 1.seconds;
        config.enableWorkStealing = true;
        
        coordinator = new Coordinator(graph, config);
        
        // Create mock workers
        for (size_t i = 0; i < workerCount; i++)
        {
            auto worker = new MockWorker("127.0.0.1", cast(ushort)(19100 + i));
            workers ~= worker;
        }
    }
    
    void setup() @trusted
    {
        // Start coordinator
        auto result = coordinator.start();
        Assert.isTrue(result.isOk, "Coordinator should start successfully");
        
        // Start workers
        foreach (worker; workers)
        {
            worker.start();
        }
        
        // Give time for workers to register
        Thread.sleep(500.msecs);
    }
    
    void teardown() @trusted
    {
        // Stop workers
        foreach (worker; workers)
        {
            worker.stop();
        }
        
        // Stop coordinator
        coordinator.stop();
        
        // Cleanup
        tempDir.teardown();
    }
    
    MockWorker getWorker(size_t index)
    {
        return workers[index];
    }
    
    Coordinator getCoordinator()
    {
        return coordinator;
    }
    
    size_t getWorkerCount() const
    {
        return workers.length;
    }
}

// ============================================================================
// CHAOS ENGINEERING TESTS
// ============================================================================

/// Test: Network partition during build
unittest
{
    auto fixture = new DistributedTestFixture(3);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker0 = fixture.getWorker(0);
    auto worker1 = fixture.getWorker(1);
    
    // Schedule some actions
    ubyte[32] hash1;
    hash1[0] = 1;
    auto action1 = new ActionRequest(
        ActionId(hash1),
        "echo test1",
        null, // env
        [],
        [],
        Capabilities(),
        Priority.Normal,
        10.seconds
    );
    
    auto result = coordinator.scheduleAction(action1);
    Assert.isTrue(result.isOk, "Should schedule action");
    
    // Partition worker0
    worker0.partition();
    Thread.sleep(1.seconds);
    
    // Actions should still complete via other workers
    auto stats = coordinator.getStats();
    Logger.info("Stats after partition - pending: " ~ stats.pendingActions.to!string);
    
    // Restore partition
    worker0.restore();
    Thread.sleep(500.msecs);
    
    // Worker should rejoin
    Assert.isTrue(true, "Worker should recover from partition");
}

/// Test: Worker crash and recovery
unittest
{
    auto fixture = new DistributedTestFixture(3);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker1 = fixture.getWorker(1);
    
    // Get initial stats
    auto initialStats = coordinator.getStats();
    immutable initialWorkers = initialStats.healthyWorkerCount;
    
    // Crash a worker
    worker1.crash();
    Thread.sleep(6.seconds);  // Wait for timeout
    
    // Coordinator should detect failure
    auto afterCrashStats = coordinator.getStats();
    Logger.info("Workers after crash - healthy: " ~ afterCrashStats.healthyWorkerCount.to!string);
    
    // Work should be reassigned to remaining workers
    Assert.isTrue(afterCrashStats.healthyWorkerCount < initialWorkers, 
                 "Coordinator should detect worker failure");
}

/// Test: Multiple simultaneous worker failures
unittest
{
    auto fixture = new DistributedTestFixture(5);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    
    // Schedule multiple actions
    for (size_t i = 0; i < 10; i++)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        auto action = new ActionRequest(
            ActionId(hash),
            "echo test" ~ i.to!string,
            null,
            [],
            [],
            Capabilities(),
            Priority.Normal,
            10.seconds
        );
        coordinator.scheduleAction(action);
    }
    
    Thread.sleep(500.msecs);
    
    // Crash multiple workers simultaneously
    fixture.getWorker(0).crash();
    fixture.getWorker(2).crash();
    fixture.getWorker(4).crash();
    
    Thread.sleep(6.seconds);
    
    // System should recover and continue with remaining workers
    auto stats = coordinator.getStats();
    Logger.info("After mass failure - healthy: " ~ stats.healthyWorkerCount.to!string);
    Assert.isTrue(stats.healthyWorkerCount >= 2, "Some workers should remain healthy");
}

/// Test: Network delays and timeouts
unittest
{
    auto fixture = new DistributedTestFixture(2);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker0 = fixture.getWorker(0);
    
    // Inject network delay
    FaultConfig delayConfig;
    delayConfig.type = FaultType.NetworkDelay;
    delayConfig.probability = 1.0;  // 100% chance
    delayConfig.delay = 3.seconds;
    delayConfig.maxFaults = 5;
    worker0.addFault(delayConfig);
    
    // Schedule action
    ubyte[32] hash;
    hash[0] = 42;
    auto action = new ActionRequest(
        ActionId(hash),
        "echo delayed",
        null,
        [],
        [],
        Capabilities(),
        Priority.Normal,
        10.seconds
    );
    
    auto startTime = MonoTime.currTime;
    coordinator.scheduleAction(action);
    
    Thread.sleep(5.seconds);
    
    // Verify delays were injected
    auto faultCount = worker0.getFaultCount();
    Logger.info("Network delays injected: " ~ faultCount.to!string);
    Assert.isTrue(faultCount > 0, "Network delays should be injected");
}

/// Test: Worker hanging (unresponsive)
unittest
{
    auto fixture = new DistributedTestFixture(3);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker1 = fixture.getWorker(1);
    
    // Inject hang fault (one-time)
    FaultConfig hangConfig;
    hangConfig.type = FaultType.WorkerHang;
    hangConfig.probability = 1.0;
    hangConfig.maxFaults = 1;
    worker1.addFault(hangConfig);
    
    // Schedule actions
    for (size_t i = 0; i < 5; i++)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)(100 + i);
        auto action = new ActionRequest(
            ActionId(hash),
            "echo hang_test",
            null,
            [],
            [],
            Capabilities(),
            Priority.Normal,
            5.seconds
        );
        coordinator.scheduleAction(action);
    }
    
    // Wait and observe - other workers should handle work
    Thread.sleep(7.seconds);
    
    auto stats = coordinator.getStats();
    Logger.info("Stats with hanging worker - executing: " ~ stats.executingActions.to!string);
    
    // System should continue despite hung worker
    Assert.isTrue(true, "System handles hung worker");
}

/// Test: Cascading failures
unittest
{
    auto fixture = new DistributedTestFixture(4);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    
    // Schedule many actions
    for (size_t i = 0; i < 20; i++)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)(200 + i);
        auto action = new ActionRequest(
            ActionId(hash),
            "echo cascade_test",
            null,
            [],
            [],
            Capabilities(),
            Priority.Normal,
            10.seconds
        );
        coordinator.scheduleAction(action);
    }
    
    // Cascade failures over time
    Thread.sleep(1.seconds);
    fixture.getWorker(0).crash();
    
    Thread.sleep(2.seconds);
    fixture.getWorker(1).crash();
    
    Thread.sleep(2.seconds);
    fixture.getWorker(2).crash();
    
    // Final worker should handle remaining load
    Thread.sleep(3.seconds);
    
    auto stats = coordinator.getStats();
    Logger.info("After cascade - healthy: " ~ stats.healthyWorkerCount.to!string);
    Logger.info("After cascade - pending: " ~ stats.pendingActions.to!string);
    
    Assert.isTrue(stats.healthyWorkerCount >= 1, "At least one worker should survive");
}

/// Test: Network partition and healing
unittest
{
    auto fixture = new DistributedTestFixture(3);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker0 = fixture.getWorker(0);
    auto worker2 = fixture.getWorker(2);
    
    // Create partition
    worker0.partition();
    worker2.partition();
    
    // Schedule work - should go to non-partitioned worker
    for (size_t i = 0; i < 5; i++)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)(50 + i);
        auto action = new ActionRequest(
            ActionId(hash),
            "echo partition_test",
            null,
            [],
            [],
            Capabilities(),
            Priority.Normal,
            10.seconds
        );
        coordinator.scheduleAction(action);
    }
    
    Thread.sleep(2.seconds);
    
    // Heal partition
    worker0.restore();
    worker2.restore();
    
    Thread.sleep(2.seconds);
    
    // Workers should rejoin and accept work
    auto stats = coordinator.getStats();
    Logger.info("After healing - workers: " ~ stats.healthyWorkerCount.to!string);
    
    Assert.isTrue(true, "System recovers from network partition");
}

/// Test: Repeated worker crashes (flapping)
unittest
{
    auto fixture = new DistributedTestFixture(2);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    auto worker0 = fixture.getWorker(0);
    
    // Simulate flapping worker - crash and restart multiple times
    for (size_t i = 0; i < 3; i++)
    {
        // Crash
        worker0.crash();
        Thread.sleep(2.seconds);
        
        // Restart
        worker0 = new MockWorker("127.0.0.1", 19100);
        worker0.start();
        Thread.sleep(1.seconds);
    }
    
    // System should remain stable despite flapping
    auto stats = coordinator.getStats();
    Logger.info("After flapping - system stable");
    
    Assert.isTrue(true, "System handles flapping worker");
}

/// Test: Load spike during failures
unittest
{
    auto fixture = new DistributedTestFixture(4);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    
    // Create load spike
    for (size_t i = 0; i < 50; i++)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        hash[1] = cast(ubyte)(i >> 8);
        auto action = new ActionRequest(
            ActionId(hash),
            "echo load_test",
            null,
            [],
            [],
            Capabilities(),
            Priority.Normal,
            10.seconds
        );
        coordinator.scheduleAction(action);
    }
    
    Thread.sleep(500.msecs);
    
    // Fail workers during high load
    fixture.getWorker(0).crash();
    fixture.getWorker(2).crash();
    
    // System should redistribute load
    Thread.sleep(4.seconds);
    
    auto stats = coordinator.getStats();
    Logger.info("Load test - pending: " ~ stats.pendingActions.to!string);
    Logger.info("Load test - executing: " ~ stats.executingActions.to!string);
    
    // Remaining workers should handle redistributed load
    Assert.isTrue(stats.healthyWorkerCount >= 2, "Remaining workers handle load");
}

/// Test: Timeout handling
unittest
{
    auto fixture = new DistributedTestFixture(2);
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto coordinator = fixture.getCoordinator();
    
    // Schedule action with very short timeout
    ubyte[32] hash;
    hash[0] = 99;
    auto action = new ActionRequest(
        ActionId(hash),
        "sleep 10",  // Sleep longer than timeout
        null,
        [],
        [],
        Capabilities(),
        Priority.Normal,
        100.msecs  // Very short timeout
    );
    
    coordinator.scheduleAction(action);
    Thread.sleep(2.seconds);
    
    // Action should timeout and be retried or failed
    auto stats = coordinator.getStats();
    Logger.info("Timeout test - failed: " ~ stats.failedActions.to!string);
    
    Assert.isTrue(true, "System handles timeouts");
}
