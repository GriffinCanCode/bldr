module engine.distributed.worker.worker;

import std.datetime : Duration, Clock, seconds, msecs;
import core.time : MonoTime;
import std.algorithm : remove;
import std.random : uniform;
import std.conv : to;
import core.thread : Thread;
import core.atomic;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.protocol : NetworkError;
import engine.distributed.protocol.transport;
import engine.distributed.protocol.messages;
import infrastructure.utils.concurrency.deque : WorkStealingDeque;
import infrastructure.utils.concurrency.structured : TaskScope, VoidTask;
import engine.distributed.worker.peers;
import engine.distributed.worker.steal;
import engine.distributed.memory;
import engine.distributed.metrics.steal : StealTelemetry;
import infrastructure.errors;
import infrastructure.utils.logging;

// Import split modules
public import engine.distributed.worker.lifecycle;
public import engine.distributed.worker.execution;
public import engine.distributed.worker.communication;

/// Build worker (executes actions)
/// Uses structured concurrency via TaskScope for thread management
final class Worker
{
    private WorkerLifecycle lifecycle;
    private WorkerExecutor executor;
    private WorkerCommunication communication;
    
    // Structured concurrency: TaskScope guarantees all child tasks complete before stop()
    private TaskScope taskScope;
    private VoidTask mainTask;
    private VoidTask heartbeatTask;
    private VoidTask peerAnnounceTask;
    
    this(WorkerConfig config) @trusted
    {
        lifecycle.initialize(config);
    }
    
    /// Start worker using structured concurrency
    Result!DistributedError start() @trusted
    {
        auto startResult = lifecycle.start();
        if (startResult.isErr) return startResult;
        
        // Create TaskScope for hierarchical task management
        taskScope = new TaskScope("worker-" ~ lifecycle.getId().toString());
        
        // Launch main loop as structured task
        mainTask = taskScope.launchBackground("main-loop", &mainLoopBody);
        
        // Launch heartbeat as periodic structured task  
        heartbeatTask = taskScope.launchPeriodic("heartbeat", 
            lifecycle.getConfig().heartbeatInterval, &heartbeatBody);
        
        // Launch peer announce if work stealing enabled
        if (lifecycle.getConfig().enableWorkStealing)
        {
            peerAnnounceTask = taskScope.launchPeriodic("peer-announce",
                lifecycle.getConfig().peerAnnounceInterval, &peerAnnounceBody);
        }
        
        return Ok!DistributedError();
    }
    
    /// Stop worker - TaskScope guarantees all tasks complete
    void stop() @trusted
    {
        if (taskScope !is null)
        {
            taskScope.cancelAndJoin();  // Cancel and wait for all tasks
            taskScope = null;
        }
        lifecycle.stop();
    }
    
    /// Main worker loop body (called by TaskScope.launchBackground)
    private void mainLoopBody() @trusted
    {
        auto config = lifecycle.getConfig();
        
        // Check cancellation via TaskScope
        if (taskScope.isCancelled()) return;
        
        // 1. Try local work first
        if (auto localAction = lifecycle.getLocalQueue().pop())
        { executeAction(localAction); return; }
        
        // 2. Request work from coordinator
        if (auto coordinatorAction = communication.requestWork(lifecycle.getId(), lifecycle.getCoordinatorTransport()))
        { executeAction(coordinatorAction); return; }
        
        // 3. Try stealing from peers (if enabled and local queue below threshold)
        if (config.enableWorkStealing && lifecycle.getStealEngine() !is null)
        {
            immutable minLocal = lifecycle.getStealEngine().getEffectiveMinLocalQueue();
            if (lifecycle.getLocalQueue().size() < minLocal)
            {
                immutable startTime = MonoTime.currTime;
                auto stolenAction = lifecycle.getStealEngine().steal(lifecycle.getCoordinatorTransport());
                immutable latency = MonoTime.currTime - startTime;
                
                if (auto telemetry = lifecycle.getStealTelemetry()) 
                    telemetry.recordAttempt(WorkerId(0), latency, stolenAction !is null);
                if (stolenAction !is null) { executeAction(stolenAction); return; }
            }
        }
        
        // 4. No work available, brief yield
        Thread.yield();
    }
    
    /// Execute build action (delegates to executor)
    private void executeAction(ActionRequest request) @trusted
    {
        lifecycle.setState(WorkerState.Executing);
        auto config = lifecycle.getConfig();
        executor.executeAction(request, config.enableSandboxing, config.defaultCapabilities,
            (ActionResult result) @trusted { communication.sendResult(lifecycle.getId(), result, lifecycle.getCoordinatorTransport()); });
        lifecycle.setState(WorkerState.Idle);
    }
    
    /// Heartbeat body (called periodically by TaskScope.launchPeriodic)
    private void heartbeatBody() @trusted
    {
        communication.sendHeartbeat(lifecycle.getId(), lifecycle.getState(), 
            lifecycle.getMetrics(), lifecycle.getCoordinatorTransport());
    }
    
    /// Peer announce body (called periodically by TaskScope.launchPeriodic)
    private void peerAnnounceBody() @trusted
    {
        auto config = lifecycle.getConfig();
        immutable queueSize = lifecycle.getLocalQueue().size();
        auto loadFactor = communication.calculateLoadFactor(
            queueSize, config.localQueueSize, 
            lifecycle.getState(), config.maxConcurrentActions);
        
        communication.announceToPeers(lifecycle.getId(), config.listenAddress, 
            queueSize, loadFactor, lifecycle.getPeerRegistry(), 
            lifecycle.getCoordinatorTransport());
    }
    
    /// Check if worker is running
    bool isRunning() @trusted => taskScope !is null && !taskScope.isCancelled();
}
