module engine.distributed.worker.lifecycle;

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
import infrastructure.utils.memory.numa : NUMATopology;
import engine.distributed.worker.peers;
import engine.distributed.worker.steal;
import engine.distributed.worker.adaptive;
import engine.distributed.memory;
import engine.distributed.memory.local;
import engine.distributed.metrics.steal : StealTelemetry;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Worker configuration
struct WorkerConfig
{
    string coordinatorUrl;                          // Coordinator address
    size_t maxConcurrentActions = 8;                // Max parallel execution
    size_t localQueueSize = 256;                    // Local work queue
    bool enableSandboxing = true;                   // Hermetic execution?
    bool enableWorkStealing = true;                 // Enable P2P work-stealing?
    string listenAddress;                           // Listen address for P2P
    Capabilities defaultCapabilities;               // Default sandbox settings
    Duration heartbeatInterval = 5.seconds;         // Heartbeat frequency
    Duration peerAnnounceInterval = 10.seconds;     // Peer announce frequency
    StealConfig stealConfig = defaultStealConfig(); // Work-stealing config (adaptive by default)
}

/// Default steal config with adaptive thresholds enabled
StealConfig defaultStealConfig() pure nothrow @safe @nogc
{
    StealConfig cfg;
    cfg.enableAdaptive = true;  // Adaptive tuning on by default for optimal load balancing
    return cfg;
}

/// Worker lifecycle manager
struct WorkerLifecycle
{
    private WorkerId id;
    private WorkerConfig config;
    private WorkStealingDeque!ActionRequest localQueue;
    private Transport coordinatorTransport;
    private shared WorkerState state;
    private shared bool running;
    private SystemMetrics metrics;
    
    // Work-stealing components
    private PeerRegistry peerRegistry;
    private StealEngine stealEngine;
    private StealTelemetry stealTelemetry;
    
    // Memory optimization: shared pools as fallback (thread-local is primary)
    private ArenaPool arenaPool;
    private BufferPool bufferPool;
    
    /// Initialize lifecycle
    void initialize(WorkerConfig config) @trusted
    {
        this.config = config;
        // Use NUMA-local allocation for work-stealing deque on multi-socket systems
        this.localQueue = WorkStealingDeque!ActionRequest(config.localQueueSize, NUMATopology.currentNode());
        atomicStore(state, WorkerState.Idle);
        atomicStore(running, false);
        
        // Configure thread-local pools (primary path - zero sync)
        ThreadLocalBufferPool.configure(64 * 1024, 32);
        ThreadLocalBufferPool.preallocate(8);
        
        // Keep shared pools as fallback for cross-thread transfers
        this.arenaPool = new ArenaPool(64 * 1024, 16);
        this.bufferPool = new BufferPool(64 * 1024, 64);
        bufferPool.preallocate(8);
    }
    
    /// Start worker
    Result!DistributedError start() @trusted
    {
        if (atomicLoad(running)) return Ok!DistributedError();
        
        auto transportResult = TransportFactory.create(config.coordinatorUrl);
        if (transportResult.isErr) return Result!DistributedError.err(transportResult.unwrapErr());
        coordinatorTransport = transportResult.unwrap();
        
        auto registerResult = registerWithCoordinator();
        if (registerResult.isErr) return Result!DistributedError.err(registerResult.unwrapErr());
        id = registerResult.unwrap();
        
        if (config.enableWorkStealing)
        {
            peerRegistry = new PeerRegistry(id);
            stealEngine = new StealEngine(id, peerRegistry, config.stealConfig);
            stealTelemetry = new StealTelemetry();
            structuredLog.info("workstealing_enabled").emit();
        }
        
        atomicStore(running, true);
        structuredLog.info("worker_started_").field("detail", "Worker started: " ~ id.toString()).emit();
        return Ok!DistributedError();
    }
    
    /// Stop worker - cleanup transport and logging (threads managed by TaskScope in Worker)
    void stop() @trusted
    {
        atomicStore(running, false);
        
        // Transport cleanup
        if (coordinatorTransport !is null) coordinatorTransport.close();
        
        // Log memory statistics (thread-local + shared)
        auto localStats = LocalMemoryStats.collect();
        structuredLog.info("memory_stats")
            .field("arena_allocs", localStats.arena.totalAllocations)
            .field("arena_resets", localStats.arena.totalResets)
            .field("buffer_reused", localStats.buffers.totalReused)
            .field("buffer_created", localStats.buffers.totalCreated)
            .emit();
        
        // Clear thread-local memory
        resetThreadLocalMemory();
        
        // Log statistics
        if (stealTelemetry !is null) structuredLog.info("workstealing_stats_").field("detail", "Work-stealing stats: " ~ stealTelemetry.getStats().toString()).emit();
        
        if (stealEngine !is null && stealEngine.isAdaptiveEnabled())
        {
            auto adaptiveState = stealEngine.getAdaptiveState();
            auto stats = stealEngine.getAdaptiveStats();
            structuredLog.info("adaptive_thresholds_").field("detail", "Adaptive thresholds: " ~ adaptiveState.toString()).emit();
            structuredLog.info("adaptive_stats_").field("detail", "Adaptive stats: " ~ stats.toString()).emit();
        }
        structuredLog.info("worker_stopped_").field("detail", "Worker stopped: " ~ id.toString()).emit();
    }
    
    /// Register with coordinator
    private Result!(WorkerId, DistributedError) registerWithCoordinator() @trusted
    {
        import engine.distributed.protocol.messages;
        import std.socket : Socket, TcpSocket;
        
        try
        {
            auto reg = WorkerRegistration("worker-" ~ uniform!uint().to!string, config.defaultCapabilities, collectMetrics());
            auto regData = serializeRegistration(reg);
            
            auto socket = coordinatorTransport;
            if (!socket.isConnected())
            {
                auto connectResult = cast(HttpTransport)socket;
                if (connectResult is null) return Err!(WorkerId, DistributedError)(new DistributedError("Invalid transport"));
                auto connResult = connectResult.connect();
                if (connResult.isErr) return Err!(WorkerId, DistributedError)(connResult.unwrapErr());
            }
            
            ubyte[1] typeBytes = [cast(ubyte)MessageType.Registration];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)regData.length;
            
            return Ok!(WorkerId, DistributedError)(WorkerId(uniform!ulong()));
        }
        catch (Exception e) { return Err!(WorkerId, DistributedError)(new DistributedError("Registration failed: " ~ e.msg)); }
    }
    
    /// Collect system metrics
    private SystemMetrics collectMetrics() @trusted
    {
        import core.memory : GC;
        auto stats = GC.stats();
        immutable queueSize = localQueue.size();
        immutable activeActions = atomicLoad(state) == WorkerState.Executing ? 1 : 0;
        immutable queueLoad = queueSize > 0 ? cast(float)queueSize / config.localQueueSize : 0.0f;
        immutable actionLoad = activeActions > 0 ? cast(float)activeActions / config.maxConcurrentActions : 0.0f;
        
        return SystemMetrics(
            queueLoad * 0.5f + actionLoad * 0.5f,  // cpuUsage
            stats.usedSize > 0 ? cast(float)stats.usedSize / stats.usedSize : 0.0f,  // memoryUsage
            getDiskUsage(),  // diskUsage
            queueSize,  // queueDepth
            activeActions  // activeActions
        );
    }
    
    /// Get disk usage for current working directory (platform-specific)
    private float getDiskUsage() @trusted
    {
        version(Posix)
        {
            import core.sys.posix.sys.statvfs;
            import std.file : getcwd;
            import std.string : toStringz;
            
            statvfs_t stat;
            if (statvfs(toStringz(getcwd()), &stat) == 0 && stat.f_blocks > 0)
                return cast(float)(stat.f_blocks - stat.f_bavail) * stat.f_frsize / (stat.f_blocks * stat.f_frsize);
            return 0.2f;
        }
        else version(Windows)
        {
            import core.sys.windows.windows;
            import std.file : getcwd;
            import std.utf : toUTF16;
            
            ULARGE_INTEGER freeBytesAvailable, totalBytes, freeBytes;
            if (GetDiskFreeSpaceExW((getcwd() ~ "\0").toUTF16.ptr, &freeBytesAvailable, &totalBytes, &freeBytes) && totalBytes.QuadPart > 0)
                return cast(float)(totalBytes.QuadPart - freeBytes.QuadPart) / totalBytes.QuadPart;
            return 0.2f;
        }
        else return 0.2f;
    }
    
    /// Backoff strategy (exponential with jitter)
    void backoff(size_t attempt) @trusted
    {
        import core.time : msecs;
        import std.algorithm : min;
        
        if (attempt < 10) Thread.yield();
        else if (attempt < 20) Thread.sleep((min(1 << (attempt - 10), 100) + uniform(0, min(1 << (attempt - 10), 100) / 2)).msecs);
        else Thread.sleep(100.msecs);
    }
    
    /// Access methods
    WorkerId getId() @trusted => id;
    WorkerConfig getConfig() @trusted => config;
    ref WorkStealingDeque!ActionRequest getLocalQueue() @trusted => localQueue;
    Transport getCoordinatorTransport() @trusted => coordinatorTransport;
    WorkerState getState() @trusted => atomicLoad(state);
    void setState(WorkerState newState) @trusted { atomicStore(state, newState); }
    bool isRunning() @trusted => atomicLoad(running);
    shared(bool*) getRunningPtr() @trusted => &running;
    PeerRegistry getPeerRegistry() @trusted => peerRegistry;
    StealEngine getStealEngine() @trusted => stealEngine;
    StealTelemetry getStealTelemetry() @trusted => stealTelemetry;
    SystemMetrics getMetrics() @trusted => collectMetrics();
    
    /// Adaptive threshold accessors (for monitoring and debugging)
    bool isAdaptiveEnabled() @trusted => stealEngine !is null && stealEngine.isAdaptiveEnabled();
    ThresholdState getAdaptiveState() @trusted => stealEngine !is null ? stealEngine.getAdaptiveState() : ThresholdState.init;
    AdaptiveStats getAdaptiveStats() @trusted => stealEngine !is null ? stealEngine.getAdaptiveStats() : AdaptiveStats.init;
    
    /// Thread-local memory statistics (for monitoring)
    LocalMemoryStats getLocalMemoryStats() @trusted nothrow @nogc => LocalMemoryStats.collect();
}

