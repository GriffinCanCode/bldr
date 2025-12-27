module engine.distributed.coordinator.recover;

import std.datetime : Duration, Clock, SysTime, seconds;
import std.algorithm : filter, map, sort, remove, min;
import std.array : array;
import std.container : DList;
import std.conv : to;
import std.range : walkLength;
import core.atomic;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.protocol;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.health;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging;

/// Work reassignment strategy
enum ReassignStrategy
{
    RoundRobin,     // Distribute evenly
    LeastLoaded,    // Assign to least loaded worker
    Affinity,       // Try to maintain locality
    Priority        // Prioritize critical work
}

/// Coordinator-side failure recovery
/// Handles work reassignment and worker blacklisting
final class CoordinatorRecovery
{
    private WorkerRegistry registry;
    private DistributedScheduler scheduler;
    private HealthMonitor healthMonitor;
    private Mutex mutex;
    
    // Blacklist management
    private WorkerBlacklist[WorkerId] blacklist;
    private immutable Duration maxBlacklistDuration = 300.seconds;
    
    // Reassignment queue (high priority for failed work)
    private DList!ActionId reassignmentQueue;
    private ReassignStrategy strategy;
    
    // Statistics
    private shared size_t totalFailures;
    private shared size_t successfulReassignments;
    private shared size_t failedReassignments;
    private shared size_t blacklistedWorkers;
    
    this(
        WorkerRegistry registry,
        DistributedScheduler scheduler,
        HealthMonitor healthMonitor,
        ReassignStrategy strategy = ReassignStrategy.Priority) @trusted
    {
        this.registry = registry;
        this.scheduler = scheduler;
        this.healthMonitor = healthMonitor;
        this.strategy = strategy;
        this.mutex = new Mutex();
    }
    
    /// Handle worker failure
    Result!DistributedError handleWorkerFailure(WorkerId worker, string reason) @trusted
    {
        atomicOp!"+="(totalFailures, 1);
        structuredLog.warning("handling_worker_failure_").field("detail", "Handling worker failure: " ~ worker.toString() ~ " (" ~ reason ~ ")").emit();
        
        synchronized (mutex)
        {
            auto inProgressActions = registry.inProgressActions(worker);
            if (inProgressActions.length == 0)
            {
                structuredLog.info("no_work_to_reassign_from_").field("detail", "No work to reassign from " ~ worker.toString()).emit();
                return Ok!DistributedError();
            }
            
            structuredLog.info("reassigning_").field("detail", "Reassigning " ~ inProgressActions.length.to!string ~ " actions from " ~ worker.toString()).emit();
            foreach (action; inProgressActions) reassignmentQueue.insertBack(action);
            
            scheduler.onWorkerFailure(worker);
            blacklistWorker(worker, reason);
            return reassignActions();
        }
    }
    
    /// Reassign actions from queue
    Result!DistributedError reassignActions() @trusted
    {
        synchronized (mutex)
        {
            while (!reassignmentQueue.empty)
            {
                auto action = reassignmentQueue.front;
                reassignmentQueue.removeFront();
                
                auto workerResult = selectWorkerForReassignment(action);
                if (workerResult.isErr)
                {
                    reassignmentQueue.insertFront(action);
                    atomicOp!"+="(failedReassignments, 1);
                    structuredLog.warning("no_workers_available_for_reassignment").emit();
                    return Result!DistributedError.err(new DistributedError("No available workers for reassignment"));
                }
                
                auto assignResult = scheduler.assign(action, workerResult.unwrap());
                if (assignResult.isErr)
                {
                    atomicOp!"+="(failedReassignments, 1);
                    structuredLog.error("failed_to_reassign_action").emit();
                    structuredLog.error("log_event").field("message", formatError(assignResult.unwrapErr())).emit();
                    return assignResult;
                }
                
                atomicOp!"+="(successfulReassignments, 1);
                structuredLog.info("reassigned_action_").field("detail", "Reassigned action " ~ action.toString() ~ " to worker " ~ workerResult.unwrap().toString()).emit();
            }
            return Ok!DistributedError();
        }
    }
    
    bool isBlacklisted(WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            if (auto entry = worker in blacklist)
            {
                if (entry.shouldRetry(Clock.currTime)) { removeFromBlacklist(worker); return false; }
                return true;
            }
            return false;
        }
    }
    
    void removeFromBlacklist(WorkerId worker) @trusted
    {
        synchronized (mutex) if (worker in blacklist)
        {
            blacklist.remove(worker);
            atomicOp!"-="(blacklistedWorkers, 1);
            structuredLog.info("worker_removed_from_blacklist_").field("detail", "Worker removed from blacklist: " ~ worker.toString()).emit();
        }
    }
    
    size_t pendingReassignments() @trusted
    {
        synchronized (mutex)
            return walkLength(reassignmentQueue[]);
    }
    
    /// Get recovery statistics
    struct RecoveryStats
    {
        size_t totalFailures;
        size_t successfulReassignments;
        size_t failedReassignments;
        size_t pendingReassignments;
        size_t blacklistedWorkers;
        float reassignmentSuccessRate;
    }
    
    RecoveryStats getStats() @trusted
    {
        RecoveryStats stats;
        stats.totalFailures = atomicLoad(totalFailures);
        stats.successfulReassignments = atomicLoad(successfulReassignments);
        stats.failedReassignments = atomicLoad(failedReassignments);
        stats.blacklistedWorkers = atomicLoad(blacklistedWorkers);
        synchronized (mutex) { stats.pendingReassignments = walkLength(reassignmentQueue[]); }
        
        immutable total = stats.successfulReassignments + stats.failedReassignments;
        if (total > 0) stats.reassignmentSuccessRate = cast(float)stats.successfulReassignments / cast(float)total;
        return stats;
    }
    
    /// Reset statistics
    void resetStats() @trusted
    {
        atomicStore(totalFailures, cast(size_t)0);
        atomicStore(successfulReassignments, cast(size_t)0);
        atomicStore(failedReassignments, cast(size_t)0);
    }
    
    private:
    
    /// Blacklist worker with exponential backoff
    void blacklistWorker(WorkerId worker, string reason) @trusted
    {
        if (auto entry = worker in blacklist)
        {
            entry.failureCount++;
            entry.lastFailure = Clock.currTime;
            immutable backoffSeconds = 1 << min(entry.failureCount, 8);
            immutable duration = min(seconds(backoffSeconds), maxBlacklistDuration);
            entry.nextRetryTime = Clock.currTime + duration;
            structuredLog.warning("worker_blacklist_extended_").field("detail", "Worker blacklist extended: " ~ worker.toString() ~ " (failures: " ~ entry.failureCount.to!string ~ ", next retry: " ~ backoffSeconds.to!string ~ "s)").emit();
        }
        else
        {
            blacklist[worker] = WorkerBlacklist(worker, reason, Clock.currTime, Clock.currTime + 5.seconds, 1);
            atomicOp!"+="(blacklistedWorkers, 1);
            structuredLog.info("worker_blacklisted_").field("detail", "Worker blacklisted: " ~ worker.toString() ~ " (reason: " ~ reason ~ ")").emit();
        }
    }
    
    /// Select worker for reassignment based on strategy
    Result!(WorkerId, DistributedError) selectWorkerForReassignment(ActionId action) @trusted
    {
        auto candidates = registry.healthyWorkers().filter!(w => !isBlacklisted(w.id)).array;
        if (candidates.length == 0) return Err!(WorkerId, DistributedError)(new WorkerError("No healthy workers available"));
        
        final switch (strategy)
        {
            case ReassignStrategy.RoundRobin: return selectRoundRobin(candidates);
            case ReassignStrategy.LeastLoaded: return selectLeastLoaded(candidates);
            case ReassignStrategy.Affinity: return selectAffinity(action, candidates);
            case ReassignStrategy.Priority: return selectPriority(action, candidates);
        }
    }
    
    /// Round-robin selection
    Result!(WorkerId, DistributedError) selectRoundRobin(WorkerInfo[] candidates) @trusted
    {
        static size_t nextIndex = 0;
        return Ok!(WorkerId, DistributedError)(candidates[(nextIndex++) % candidates.length].id);
    }
    
    /// Select least loaded worker
    Result!(WorkerId, DistributedError) selectLeastLoaded(WorkerInfo[] candidates) @trusted
    {
        import std.algorithm : minElement;
        return Ok!(WorkerId, DistributedError)(candidates.minElement!"a.load()".id);
    }
    
    /// Select worker with affinity (locality); in future, could track which worker has related artifacts cached
    Result!(WorkerId, DistributedError) selectAffinity(ActionId action, WorkerInfo[] candidates) @trusted => selectLeastLoaded(candidates);
    
    /// Select worker prioritizing health and capacity (score based on: health state, load, and recent completion rate)
    Result!(WorkerId, DistributedError) selectPriority(ActionId action, WorkerInfo[] candidates) @trusted
    {
        import std.algorithm : maxElement;
        
        struct ScoredWorker { WorkerId id; float score; }
        ScoredWorker[] scored;
        scored.reserve(candidates.length);
        
        foreach (worker; candidates)
        {
            float score = 0.0f;
            auto health = healthMonitor.getWorkerHealth(worker.id);
            final switch (health)
            {
                case HealthState.Healthy: score += 100.0f; break;
                case HealthState.Degraded: score += 50.0f; break;
                case HealthState.Failing: score += 25.0f; break;
                case HealthState.Failed: score += 0.0f; break;
                case HealthState.Recovering: score += 40.0f; break;
            }
            
            score += (1.0f - worker.load()) * 50.0f;
            immutable total = worker.completed + worker.failed;
            if (total > 0) score += (cast(float)worker.completed / cast(float)total) * 50.0f;
            scored ~= ScoredWorker(worker.id, score);
        }
        
        return Ok!(WorkerId, DistributedError)(scored.maxElement!"a.score".id);
    }
}

struct WorkerBlacklist
{
    WorkerId worker;
    string reason;
    SysTime lastFailure;
    SysTime nextRetryTime;
    size_t failureCount;
    
    bool shouldRetry(SysTime now) const pure @safe nothrow @nogc => now >= nextRetryTime;
}

/// Work reassignment manager
/// Handles bulk reassignment operations
final class ReassignmentManager
{
    private CoordinatorRecovery recovery;
    private WorkerRegistry registry;
    private Mutex mutex;
    
    // Reassignment batching
    private ActionId[] batchQueue;
    private immutable size_t batchSize = 10;
    
    this(CoordinatorRecovery recovery, WorkerRegistry registry) @trusted
    {
        this.recovery = recovery;
        this.registry = registry;
        this.mutex = new Mutex();
    }
    
    /// Add action to reassignment batch
    void addToBatch(ActionId action) @trusted
    {
        synchronized (mutex)
        {
            batchQueue ~= action;
            if (batchQueue.length >= batchSize) processBatch();
        }
    }
    
    /// Force process current batch
    void flush() @trusted
    {
        synchronized (mutex)
        {
            if (batchQueue.length > 0) processBatch();
        }
    }
    
    private:
    
    /// Process batch of reassignments
    void processBatch() @trusted
    {
        if (batchQueue.length == 0) return;
        structuredLog.info("processing_reassignment_batch_").field("detail", "Processing reassignment batch: " ~ batchQueue.length.to!string ~ " actions").emit();
        ActionId[][Priority] byPriority;
        foreach (action; batchQueue) {} // Would get priority from scheduler: byPriority[priority] ~= action;
        batchQueue.length = 0;
    }
}



