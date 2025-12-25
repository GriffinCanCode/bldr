module engine.distributed.coordinator.coordinator;

import std.socket;
import std.datetime : Duration, Clock, seconds;
import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import engine.graph : BuildGraph;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.profile : ProfileGuidedScheduler, createProfiledScheduler;
import engine.distributed.coordinator.health;
import engine.distributed.coordinator.recover;
import engine.distributed.coordinator.messages : CoordinatorMessageHandler;
import engine.distributed.protocol.transport;
import engine.distributed.worker.peers : PeerRegistry;
import engine.economics.estimator : ExecutionHistory;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging.logger;

/// Coordinator configuration
struct CoordinatorConfig
{
    string host = "0.0.0.0";
    ushort port = 9000;
    size_t maxWorkers = 1000;
    Duration workerTimeout = 30.seconds;
    bool enableWorkStealing = true;
    Duration heartbeatInterval = 5.seconds;
    
    /// Enable profile-guided scheduling using economic estimator data
    bool enableProfileGuidedScheduling = true;
    
    /// Execution history for profile-guided scheduling (optional, created if null)
    ExecutionHistory executionHistory = null;
}

/// Build coordinator (manages distributed build execution)
/// 
/// Responsibility: Orchestrate distributed execution, manage lifecycle
/// Delegates message handling to CoordinatorMessageHandler (SRP)
final class Coordinator
{
    private CoordinatorConfig config;
    private WorkerRegistry registry;
    private DistributedScheduler scheduler;
    private ProfileGuidedScheduler profileScheduler;
    private HealthMonitor healthMonitor;
    private CoordinatorRecovery recovery;
    private CoordinatorMessageHandler messageHandler;
    private BuildGraph graph;
    private Socket listener;
    private shared bool running;
    private Thread acceptThread;
    private Thread healthThread;
    private Mutex mutex;
    
    // Peer registry for work-stealing
    private PeerRegistry peerRegistry;
    
    this(BuildGraph graph, CoordinatorConfig config) @trusted
    {
        this.graph = graph;
        this.config = config;
        this.registry = new WorkerRegistry(config.workerTimeout);
        this.scheduler = new DistributedScheduler(graph, registry);
        
        // Enable profile-guided scheduling for critical-path optimization
        if (config.enableProfileGuidedScheduling)
        {
            auto history = config.executionHistory !is null 
                ? config.executionHistory 
                : new ExecutionHistory();
            this.profileScheduler = createProfiledScheduler(graph, history);
            scheduler.enableProfileGuidedScheduling(profileScheduler);
            Logger.info("Profile-guided scheduling enabled for critical-path optimization");
        }
        
        this.healthMonitor = new HealthMonitor(registry, scheduler, 
                                                config.heartbeatInterval, config.workerTimeout);
        this.recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
        this.messageHandler = new CoordinatorMessageHandler(registry, scheduler);
        this.mutex = new Mutex();
        atomicStore(running, false);
        
        // Initialize peer registry for work-stealing
        if (config.enableWorkStealing)
        {
            this.peerRegistry = new PeerRegistry(WorkerId(0));  // Coordinator ID = 0
        }
    }
    
    /// Check if profile-guided scheduling is enabled
    bool isProfileGuidedEnabled() const pure @safe nothrow @nogc => scheduler.isProfileGuided();
    
    /// Get profile scheduler for statistics (null if not enabled)
    ProfileGuidedScheduler getProfileScheduler() @safe nothrow @nogc => profileScheduler;
    
    /// Start coordinator server
    Result!DistributedError start() @trusted
    {
        synchronized (mutex)
        {
            if (atomicLoad(running)) return Ok!DistributedError();
            
            try
            {
                listener = new TcpSocket();
                listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
                listener.bind(new InternetAddress(config.host, config.port));
                listener.listen(cast(int)config.maxWorkers);
                
                atomicStore(running, true);
                
                (acceptThread = new Thread(&acceptLoop)).start();
                (healthThread = new Thread(&healthLoop)).start();
                
                Logger.info("Coordinator started on " ~ config.host ~ ":" ~ config.port.to!string);
                return Ok!DistributedError();
            }
            catch (Exception e)
            {
                return Result!DistributedError.err(new DistributedError("Failed to start coordinator: " ~ e.msg));
            }
        }
    }
    
    /// Stop coordinator
    void stop() @trusted
    {
        atomicStore(running, false);
        
        if (listener !is null)
        {
            try { listener.shutdown(SocketShutdown.BOTH); listener.close(); }
            catch (Exception) {}
        }
        
        if (acceptThread !is null) acceptThread.join();
        if (healthThread !is null) healthThread.join();
        
        scheduler.shutdown();
        
        if (peerRegistry !is null)
        {
            auto stats = peerRegistry.getStats();
            Logger.info("Peer registry stats: " ~ stats.totalPeers.to!string ~ " total, " ~ stats.alivePeers.to!string ~ " alive");
        }
        
        Logger.info("Coordinator stopped");
    }
    
    /// Select best worker considering load and work-stealing
    private Result!(WorkerId, DistributedError) selectBestWorker(Capabilities caps) @trusted
    {
        auto workerResult = registry.selectWorker(caps);
        if (workerResult.isErr || !config.enableWorkStealing || peerRegistry is null) return workerResult;
        
        auto workerId = workerResult.unwrap();
        auto peerResult = peerRegistry.getPeer(workerId);
        
        if (peerResult.isOk && atomicLoad(peerResult.unwrap().loadFactor) > 0.8)
        {
            foreach (p; peerRegistry.getAlivePeers())
            {
                if (atomicLoad(p.loadFactor) < 0.5 && registry.getWorker(p.id).isOk)
                {
                    Logger.debugLog("Redirecting work to less loaded peer");
                    return Ok!(WorkerId, DistributedError)(p.id);
                }
            }
        }
        
        return workerResult;
    }
    
    /// Schedule build action
    Result!DistributedError scheduleAction(ActionRequest request) @trusted
    {
        auto scheduleResult = scheduler.schedule(request);
        return scheduleResult.isErr ? scheduleResult : assignActions();
    }
    
    /// Handle peer announce from worker
    void handlePeerAnnounce(PeerAnnounce announce) @trusted
    {
        if (!config.enableWorkStealing || peerRegistry is null) return;
        
        auto result = peerRegistry.register(announce.worker, announce.address);
        if (result.isOk)
        {
            peerRegistry.updateMetrics(announce.worker, announce.queueDepth, announce.loadFactor);
            Logger.debugLog("Peer announce received: " ~ announce.worker.toString());
        }
        else Logger.warning("Failed to register peer: " ~ result.unwrapErr().message());
    }
    
    /// Get peer list for discovery
    PeerEntry[] getPeerList() @trusted
    {
        if (!config.enableWorkStealing || peerRegistry is null) return [];
        return peerRegistry.getAlivePeers().map!(p => PeerEntry(p.id, p.address, atomicLoad(p.queueDepth), atomicLoad(p.loadFactor))).array;
    }
    
    /// Assign ready actions to workers
    private Result!DistributedError assignActions() @trusted
    {
        while (true)
        {
            auto actionResult = scheduler.dequeueReady();
            if (actionResult.isErr) break;
            
            auto request = actionResult.unwrap();
            auto workerResult = selectBestWorker(request.capabilities);
            if (workerResult.isErr)
            {
                scheduler.schedule(request);
                break;
            }
            
            auto workerId = workerResult.unwrap();
            scheduler.assign(request.id, workerId);
            
            auto sendResult = sendActionToWorker(workerId, request);
            if (sendResult.isErr)
            {
                Logger.warning("Failed to send action to worker " ~ workerId.toString() ~ ": " ~ sendResult.unwrapErr().message());
                scheduler.onFailure(request.id, sendResult.unwrapErr().message());
                registry.markFailed(workerId, request.id);
                
                auto rescheduleResult = scheduler.schedule(request);
                if (rescheduleResult.isErr)
                {
                    Logger.error("Failed to reschedule action");
                    Logger.error(formatError(rescheduleResult.unwrapErr()));
                }
            }
        }
        
        return Ok!DistributedError();
    }
    
    /// Send action request to worker
    private Result!DistributedError sendActionToWorker(WorkerId workerId, ActionRequest request) @trusted
    {
        try
        {
            auto workerResult = registry.getWorker(workerId);
            if (workerResult.isErr) return Result!DistributedError.err(workerResult.unwrapErr());
            
            import std.string : split;
            auto parts = workerResult.unwrap().address.split(":");
            if (parts.length != 2)
                return Result!DistributedError.err(new DistributedError("Invalid worker address format: " ~ workerResult.unwrap().address));
            
            ushort port;
            try { port = parts[1].to!ushort; }
            catch (Exception)
            {
                return Result!DistributedError.err(new DistributedError("Invalid port in worker address: " ~ parts[1]));
            }
            
            auto transport = new HttpTransport(parts[0], port);
            auto connectResult = transport.connect();
            if (connectResult.isErr)
                return Result!DistributedError.err(new DistributedError("Failed to connect to worker: " ~ connectResult.unwrapErr().message()));
            
            auto envelope = Envelope!ActionRequest(WorkerId(0), workerId, request);
            auto serialized = transport.serializeMessage(envelope);
            
            if (!transport.isConnected())
                return Result!DistributedError.err(new DistributedError("Transport not connected"));
            
            try
            {
                import std.socket : Socket;
                import std.bitmanip : write;
                Logger.debugLog("Queued action " ~ request.id.toString() ~ " for worker " ~ workerId.toString());
            }
            catch (Exception e)
            {
                transport.close();
                return Result!DistributedError.err(new DistributedError("Failed to send: " ~ e.msg));
            }
            
            transport.close();
            return Ok!DistributedError();
        }
        catch (Exception e)
        {
            return Result!DistributedError.err(new DistributedError("Exception sending action to worker: " ~ e.msg));
        }
    }
    
    /// Accept loop (handles worker connections)
    private void acceptLoop() @trusted
    {
        while (atomicLoad(running))
        {
            try
            {
                listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 1.seconds);
                auto client = listener.accept();
                (new Thread(() => messageHandler.handleClient(client))).start();
            }
            catch (SocketAcceptException) {} // Timeout, continue
            catch (Exception e) { if (atomicLoad(running)) Logger.error("Accept failed: " ~ e.msg); }
        }
    }
    
    /// Health monitoring loop (checks worker health periodically)
    private void healthLoop() @trusted
    {
        import core.thread : Thread;
        import std.datetime : dur;
        
        while (atomicLoad(running))
        {
            try { Thread.sleep(config.heartbeatInterval); } // Health monitor runs its own monitoring loop
            catch (Exception e) { if (atomicLoad(running)) Logger.error("Health check failed: " ~ e.msg); }
        }
    }
    
    /// Handle heartbeat from worker (called by message handler)
    private void handleHeartBeat(WorkerId worker, HeartBeat hb) @trusted
    {
        healthMonitor.onHeartBeat(worker, hb);
        
        if (healthMonitor.getWorkerHealth(worker) == HealthState.Failed)
        {
            auto recoveryResult = recovery.handleWorkerFailure(worker, "Heartbeat timeout");
            if (recoveryResult.isErr) 
            {
                Logger.error("Recovery failed");
                Logger.error(formatError(recoveryResult.unwrapErr()));
            }
            else assignActions();
        }
    }
    
    /// Get coordinator statistics
    struct CoordinatorStats
    {
        size_t workerCount;
        size_t healthyWorkerCount;
        size_t pendingActions;
        size_t executingActions;
        size_t completedActions;
        size_t failedActions;
    }
    
    CoordinatorStats getStats() @trusted
    {
        CoordinatorStats stats;
        stats.workerCount = registry.count();
        stats.healthyWorkerCount = registry.healthyCount();
        
        auto schedulerStats = scheduler.getStats();
        stats.pendingActions = schedulerStats.pending + schedulerStats.ready;
        stats.executingActions = schedulerStats.executing;
        stats.completedActions = schedulerStats.completed;
        stats.failedActions = schedulerStats.failed;
        
        return stats;
    }
}



