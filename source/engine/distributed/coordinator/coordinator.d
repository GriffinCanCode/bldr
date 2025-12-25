module engine.distributed.coordinator.coordinator;

import std.socket;
import std.datetime : Duration, Clock, seconds;
import std.algorithm : filter, map;
import std.array : array;
import std.conv : to;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.utils.concurrency.structured : TaskScope, VoidTask;
import engine.graph : BuildGraph;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.hash : AffinityKey, extractAffinity;
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
    
    /// Enable adaptive work-stealing thresholds (auto-tune based on success rates)
    bool enableAdaptiveStealThresholds = true;
    
    /// Enable consistent hashing for affinity-based worker assignment
    /// Workers assigned to same language/toolchain build warm caches
    bool enableAffinityRouting = true;
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
    private Mutex mutex;
    
    // Structured concurrency: TaskScope guarantees thread cleanup
    private TaskScope taskScope;
    private VoidTask acceptTask;
    private VoidTask healthTask;
    
    // Peer registry for work-stealing
    private PeerRegistry peerRegistry;
    
    this(BuildGraph graph, CoordinatorConfig config) @trusted
    {
        this.graph = graph;
        this.config = config;
        this.registry = new WorkerRegistry(config.workerTimeout, config.enableAffinityRouting);
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
    
    /// Start coordinator server using structured concurrency
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
                
                // Create TaskScope for hierarchical task management
                taskScope = new TaskScope("coordinator");
                
                // Launch accept and health as structured tasks
                acceptTask = taskScope.launchBackground("accept-loop", () @trusted => acceptLoopBody());
                healthTask = taskScope.launchPeriodic("health-check", config.heartbeatInterval, 
                    () @trusted => healthCheckBody());
                
                Logger.info("Coordinator started on " ~ config.host ~ ":" ~ config.port.to!string);
                return Ok!DistributedError();
            }
            catch (Exception e)
            {
                return Result!DistributedError.err(new DistributedError("Failed to start coordinator: " ~ e.msg));
            }
        }
    }
    
    /// Stop coordinator - TaskScope guarantees all tasks complete
    void stop() @trusted
    {
        atomicStore(running, false);
        
        if (listener !is null)
        {
            try { listener.shutdown(SocketShutdown.BOTH); listener.close(); }
            catch (Exception) {}
        }
        
        // TaskScope ensures all tasks complete before continuing
        if (taskScope !is null)
        {
            taskScope.cancelAndJoin();
            taskScope = null;
        }
        
        scheduler.shutdown();
        
        if (peerRegistry !is null)
        {
            auto stats = peerRegistry.getStats();
            Logger.info("Peer registry stats: " ~ stats.totalPeers.to!string ~ " total, " ~ stats.alivePeers.to!string ~ " alive");
        }
        
        Logger.info("Coordinator stopped");
    }
    
    /// Select best worker considering affinity, load, and work-stealing
    private Result!(WorkerId, DistributedError) selectBestWorker(ActionRequest request) @trusted
    {
        // Use affinity-based selection when enabled
        auto workerResult = config.enableAffinityRouting && request !is null
            ? registry.selectWorkerForAction(request)
            : registry.selectWorker(request !is null ? request.capabilities : Capabilities.init);
        
        if (workerResult.isErr || !config.enableWorkStealing || peerRegistry is null) 
            return workerResult;
        
        auto workerId = workerResult.unwrap();
        auto peerResult = peerRegistry.getPeer(workerId);
        
        // Only redirect if worker is heavily loaded AND we have less loaded peers
        if (peerResult.isOk && atomicLoad(peerResult.unwrap().loadFactor) > 0.85)
        {
            // When affinity routing is enabled, prefer affinity workers even under load
            // unless they're critically overloaded (>0.95)
            if (config.enableAffinityRouting && atomicLoad(peerResult.unwrap().loadFactor) < 0.95)
                return workerResult;
            
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
    
    /// Legacy overload for backward compatibility
    private Result!(WorkerId, DistributedError) selectBestWorker(Capabilities caps) @trusted
    {
        return selectBestWorker(null);
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
            // Use affinity-aware worker selection
            auto workerResult = selectBestWorker(request);
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
    
    /// Accept loop body (called by TaskScope.launchBackground)
    private void acceptLoopBody() @trusted
    {
        if (!atomicLoad(running) || taskScope.isCancelled()) return;
        
        try
        {
            listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 1.seconds);
            auto client = listener.accept();
            // Handle client in a new thread (could also use TaskScope)
            (new Thread(() => messageHandler.handleClient(client))).start();
        }
        catch (SocketAcceptException) {} // Timeout, continue
        catch (Exception e) { if (atomicLoad(running)) Logger.error("Accept failed: " ~ e.msg); }
    }
    
    /// Health check body (called periodically by TaskScope.launchPeriodic)
    private void healthCheckBody() @trusted
    {
        // Health monitor runs its own monitoring - this is just a heartbeat
        // The actual health checking is handled by healthMonitor
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
        bool affinityRoutingEnabled;
    }
    
    CoordinatorStats getStats() @trusted
    {
        CoordinatorStats stats;
        stats.workerCount = registry.count();
        stats.healthyWorkerCount = registry.healthyCount();
        stats.affinityRoutingEnabled = config.enableAffinityRouting;
        
        auto schedulerStats = scheduler.getStats();
        stats.pendingActions = schedulerStats.pending + schedulerStats.ready;
        stats.executingActions = schedulerStats.executing;
        stats.completedActions = schedulerStats.completed;
        stats.failedActions = schedulerStats.failed;
        
        return stats;
    }
    
    /// Check if affinity routing is enabled
    bool isAffinityRoutingEnabled() const @safe nothrow @nogc => config.enableAffinityRouting;
}



