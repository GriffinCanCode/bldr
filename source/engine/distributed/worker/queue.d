module engine.distributed.worker.queue;

import std.datetime : Duration, MonoTime;
import std.datetime : msecs;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import infrastructure.utils.concurrency.deque : WorkStealingDeque;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport;
import engine.distributed.worker.peers;
import infrastructure.errors : Result, Ok, Err;
import infrastructure.utils.logging;

/// Distributed queue manager
/// Bridges local work-stealing deque with network steal protocol
/// Optimized for minimal contention and zero-copy operations
final class DistributedQueue
{
    private WorkStealingDeque!ActionRequest* localQueue;
    private PeerRegistry peers;
    private Transport transport;
    private WorkerId selfId;
    private Mutex mutex;
    
    // Statistics
    private shared size_t localPushes;
    private shared size_t localPops;
    private shared size_t stealsGiven;
    private shared size_t stealsReceived;
    
    // Configuration
    private immutable size_t minLocalReserve;  // Min work to keep before allowing steals
    private immutable size_t maxStealBatch;    // Max items to give per steal request
    
    this(
        ref WorkStealingDeque!ActionRequest localQueue,
        PeerRegistry peers,
        Transport transport,
        WorkerId selfId,
        size_t minLocalReserve = 2,
        size_t maxStealBatch = 1) @trusted
    {
        this.localQueue = &localQueue;
        this.peers = peers;
        this.transport = transport;
        this.selfId = selfId;
        this.minLocalReserve = minLocalReserve;
        this.maxStealBatch = maxStealBatch;
        this.mutex = new Mutex();
    }
    
    /// Push work to local queue
    /// Fast path - no synchronization with remote workers
    void push(ActionRequest action) @trusted
    {
        localQueue.push(action);
        atomicOp!"+="(localPushes, 1);
    }
    
    /// Pop work from local queue (owner-only operation)
    /// O(1) operation, lock-free
    ActionRequest pop() @trusted
    {
        auto action = localQueue.pop();
        if (action !is null)
            atomicOp!"+="(localPops, 1);
        return action;
    }
    
    /// Attempt to steal work from remote peer (returns action if successful, null otherwise)
    ActionRequest stealFromPeer(WorkerId victimId) @trusted
    {
        auto peerResult = peers.getPeer(victimId);
        if (peerResult.isErr) return null;
        
        auto req = StealRequest(selfId, victimId, Priority.Low);
        try
        {
            auto sendResult = transport.sendStealRequest(victimId, req);
            if (sendResult.isErr) { peers.markDead(victimId); return null; }
            
            auto receiveResult = transport.receiveStealResponse(100.msecs);
            if (receiveResult.isErr) return null;
            
            auto response = receiveResult.unwrap().payload;
            if (response.hasWork)
            {
                atomicOp!"+="(stealsReceived, 1);
                structuredLog.debug_("successfully_stole_work_from_").field("detail", "Successfully stole work from " ~ victimId.toString()).emit();
                return response.action;
            }
        }
        catch (Exception e) { structuredLog.error("steal_from_peer_failed_").field("detail", "Steal from peer failed: " ~ e.msg).emit(); peers.markDead(victimId); }
        return null;
    }
    
    /// Handle incoming steal request from remote peer (returns action to give, or null if insufficient work)
    ActionRequest handleStealRequest(StealRequest req) @trusted
    {
        immutable queueSize = localQueue.size();
        if (queueSize <= minLocalReserve)
        {
            structuredLog.debug_("rejecting_steal_from_").field("detail", "Rejecting steal from " ~ req.thief.toString() ~ " (queue too small: " ~ queueSize.to!string ~ ")").emit();
            return null;
        }
        
        auto stolen = localQueue.steal(); // Steal from bottom of our deque (FIFO for stealing) - gives away "oldest" work, keeping recent work local
        if (stolen !is null)
        {
            atomicOp!"+="(stealsGiven, 1);
            structuredLog.debug_("gave_work_to_").field("detail", "Gave work to " ~ req.thief.toString()).emit();
            peers.updateMetrics(selfId, localQueue.size(), calculateLoadFactor());
        }
        return stolen;
    }
    
    /// Handle batch steal request - give multiple items at once for network efficiency
    /// Returns array of actions (empty if insufficient work)
    ActionRequest[] handleBatchStealRequest(StealRequest req, size_t requestedCount) @trusted
    {
        immutable queueSize = localQueue.size();
        immutable available = queueSize > minLocalReserve ? queueSize - minLocalReserve : 0;
        
        if (available == 0)
        {
            structuredLog.debug_("rejecting_batch_steal_from_").field("detail", "Rejecting batch steal from " ~ req.thief.toString()).emit();
            return [];
        }
        
        // Respect maxStealBatch config
        immutable toSteal = available < requestedCount ? available : requestedCount;
        immutable actualSteal = toSteal < maxStealBatch ? toSteal : maxStealBatch;
        
        ActionRequest[] stolen;
        immutable count = localQueue.stealBatch(actualSteal, stolen);
        
        if (count > 0)
        {
            atomicOp!"+="(stealsGiven, count);
            structuredLog.debug_("gave_batch_work_to_").field("count", count).field("thief", req.thief.toString()).emit();
            peers.updateMetrics(selfId, localQueue.size(), calculateLoadFactor());
            return stolen[0 .. count];
        }
        return [];
    }
    
    /// Get current queue depth
    size_t depth() @trusted const
    {
        return localQueue.size();
    }
    
    /// Calculate load factor [0.0, 1.0]
    /// Used for peer selection and load balancing
    float calculateLoadFactor() @trusted const
    {
        immutable size = localQueue.size();
        immutable capacity = localQueue.capacity();
        
        if (capacity == 0)
            return 0.0f;
        
        return cast(float)size / cast(float)capacity;
    }
    
    /// Check if queue is empty
    bool empty() @trusted const
    {
        return localQueue.empty();
    }
    
    /// Get queue statistics
    struct QueueStats
    {
        size_t localPushes;
        size_t localPops;
        size_t stealsGiven;
        size_t stealsReceived;
        size_t currentDepth;
        float loadFactor;
        float stealEfficiency;  // stealsReceived / (stealsReceived + rejections)
    }
    
    QueueStats getStats() @trusted const
    {
        QueueStats stats = {localPushes: atomicLoad(localPushes), localPops: atomicLoad(localPops), 
            stealsGiven: atomicLoad(stealsGiven), stealsReceived: atomicLoad(stealsReceived),
            currentDepth: localQueue.size(), loadFactor: calculateLoadFactor()};
        
        immutable total = stats.stealsReceived + (stats.localPops - stats.stealsReceived);
        if (total > 0) stats.stealEfficiency = cast(float)stats.stealsReceived / cast(float)total;
        return stats;
    }
    
    /// Reset statistics
    void resetStats() @trusted
    {
        atomicStore(localPushes, cast(size_t)0);
        atomicStore(localPops, cast(size_t)0);
        atomicStore(stealsGiven, cast(size_t)0);
        atomicStore(stealsReceived, cast(size_t)0);
    }
}

/// Queue metrics for observability
struct QueueMetrics
{
    size_t depth;               // Current queue depth
    float loadFactor;           // Utilization [0.0, 1.0]
    size_t stealsPerSecond;     // Steal rate
    float stealSuccessRate;     // Successful steals / attempts
}

/// Multi-queue manager for worker with multiple priorities
/// Implements priority-based work distribution
final class PriorityQueueManager
{
    private DistributedQueue[Priority] queues;
    private PeerRegistry peers;
    private Transport transport;
    private WorkerId selfId;
    
    this(PeerRegistry peers, Transport transport, WorkerId selfId, size_t queueCapacity) @trusted
    {
        this.peers = peers;
        this.transport = transport;
        this.selfId = selfId;
        
        // Create queue for each priority level
        foreach (priority; [Priority.Critical, Priority.High, Priority.Normal, Priority.Low])
        {
            auto localQueue = WorkStealingDeque!ActionRequest(queueCapacity);
            queues[priority] = new DistributedQueue(
                localQueue, peers, transport, selfId
            );
        }
    }
    
    /// Push action to appropriate priority queue
    void push(ActionRequest action) @trusted
    {
        if (auto queue = action.priority in queues)
            queue.push(action);
        else
            queues[Priority.Normal].push(action);
    }
    
    /// Pop highest priority available work
    /// Checks queues in priority order
    ActionRequest pop() @trusted
    {
        // Try critical first
        if (auto queue = Priority.Critical in queues)
        {
            auto action = queue.pop();
            if (action !is null)
                return action;
        }
        
        // Try high
        if (auto queue = Priority.High in queues)
        {
            auto action = queue.pop();
            if (action !is null)
                return action;
        }
        
        // Try normal
        if (auto queue = Priority.Normal in queues)
        {
            auto action = queue.pop();
            if (action !is null)
                return action;
        }
        
        // Try low
        if (auto queue = Priority.Low in queues)
            return queue.pop();
        
        return null;
    }
    
    /// Steal from peer
    ActionRequest stealFromPeer(WorkerId victimId) @trusted
    {
        // Try to steal highest priority work available
        foreach (priority; [Priority.Critical, Priority.High, Priority.Normal, Priority.Low])
        {
            if (auto queue = priority in queues)
            {
                auto action = queue.stealFromPeer(victimId);
                if (action !is null)
                    return action;
            }
        }
        
        return null;
    }
    
    /// Handle incoming steal request
    ActionRequest handleStealRequest(StealRequest req) @trusted
    {
        // Give away lowest priority work first
        foreach (priority; [Priority.Low, Priority.Normal, Priority.High, Priority.Critical])
        {
            if (auto queue = priority in queues)
            {
                auto action = queue.handleStealRequest(req);
                if (action !is null)
                    return action;
            }
        }
        
        return null;
    }
    
    /// Get total depth across all queues
    size_t totalDepth() @trusted const
    {
        size_t total = 0;
        foreach (queue; queues.values)
            total += queue.depth();
        return total;
    }
    
    /// Calculate aggregate load factor
    float loadFactor() @trusted const
    {
        if (queues.length == 0)
            return 0.0f;
        
        float total = 0.0f;
        foreach (queue; queues.values)
            total += queue.calculateLoadFactor();
        
        return total / queues.length;
    }
}



