module engine.distributed.coordinator.scheduler;

import std.algorithm : map, filter, maxElement, sort, uniq, each;
import std.array : array;
import std.container : DList;
import std.datetime : Duration, msecs;
import std.conv : to;
import core.sync.mutex : Mutex;
import core.sync.rwmutex : ReadWriteMutex;
import core.atomic;
import core.thread : Thread;
import engine.graph : BuildGraph, BuildNode;
import engine.distributed.protocol.protocol;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.profile : ProfileGuidedScheduler, ActionProfile;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.errors;
import infrastructure.utils.logging;
import Concurrency = infrastructure.utils.concurrency.priority;

/// Action scheduling state
private enum ActionState
{
    Pending,    // Waiting for dependencies
    Ready,      // Ready to execute
    Scheduled,  // Assigned to worker
    Executing,  // Currently running
    Completed,  // Finished successfully
    Failed      // Execution failed
}

/// Internal action tracking
private class ActionInfo
{
    ActionId id;
    ActionRequest request;
    ActionState state;
    WorkerId assignedWorker;
    size_t retries;
    Priority priority;
    shared size_t remainingDeps; // Atomic counter for O(1) readiness check

    this(ActionId id, ActionRequest request, Priority priority, size_t initialDeps)
    {
        this.id = id;
        this.request = request;
        this.state = initialDeps == 0 ? ActionState.Ready : ActionState.Pending;
        this.assignedWorker = WorkerId(0);
        this.retries = 0;
        this.priority = priority;
        atomicStore(this.remainingDeps, initialDeps);
    }
}

/// Scheduler shard for lock striping
private class SchedulerShard
{
    Mutex mutex;
    ActionInfo[ActionId] actions;
    Concurrency.PriorityQueue!ActionId readyQueue;
    
    // Mapping for dependencies within this shard (ActionId -> TargetId)
    TargetId[ActionId] actionToTarget;

    this()
    {
        this.mutex = new Mutex();
        this.readyQueue = Concurrency.PriorityQueue!ActionId(64);
    }
}

/// Target mapping shard
private class TargetShard
{
    ReadWriteMutex mutex;
    ActionId[TargetId] targetToAction;

    this()
    {
        this.mutex = new ReadWriteMutex();
    }
}

/// Distributed scheduler with lock striping and O(1) dependency tracking
/// Replaces coarse-grained mutex with fine-grained sharding
/// Supports profile-guided scheduling for critical-path optimization
final class DistributedScheduler
{
    private BuildGraph graph;
    private WorkerRegistry registry;
    private shared bool running;
    
    // Sharded state
    private enum SHARD_COUNT = 32;
    private SchedulerShard[SHARD_COUNT] shards;
    private TargetShard[SHARD_COUNT] targetShards;
    
    // Profile-guided scheduling (optional)
    private ProfileGuidedScheduler profileScheduler;
    private bool profileGuidedEnabled;
    
    private enum size_t MAX_RETRIES = 3;
    
    this(BuildGraph graph, WorkerRegistry registry) @trusted
    {
        this.graph = graph;
        this.registry = registry;
        atomicStore(running, true);
        this.profileGuidedEnabled = false;
        
        foreach (i; 0 .. SHARD_COUNT)
        {
            shards[i] = new SchedulerShard();
            targetShards[i] = new TargetShard();
        }
    }
    
    /// Enable profile-guided scheduling with economic estimator
    void enableProfileGuidedScheduling(ProfileGuidedScheduler scheduler) @trusted
    {
        this.profileScheduler = scheduler;
        this.profileGuidedEnabled = scheduler !is null;
        
        if (profileGuidedEnabled)
        {
            auto stats = scheduler.getStats();
            structuredLog.info("profile_guided_scheduling_enabled")
                .field("actions_profiled", stats.totalActions)
                .field("max_critical_path_ms", stats.maxCriticalPathCost)
                .emit();
        }
    }
    
    /// Check if profile-guided scheduling is active
    bool isProfileGuided() const pure @safe nothrow @nogc => profileGuidedEnabled;
    
    /// Get shard index for ActionId
    private size_t getShardIndex(ActionId id) const pure nothrow @safe @nogc
    {
        return id.toHash() % SHARD_COUNT;
    }

    /// Get shard index for TargetId
    private size_t getTargetShardIndex(TargetId id) const @trusted
    {
        return id.toHash() % SHARD_COUNT;
    }
    
    Result!DistributedError schedule(ActionRequest request, TargetId targetId = TargetId.init) @trusted
    {
        immutable shardIdx = getShardIndex(request.id);
        auto shard = shards[shardIdx];
        
        // 1. Register TargetId mapping if provided
        if (targetId != TargetId.init)
        {
            auto targetShard = targetShards[getTargetShardIndex(targetId)];
            synchronized (targetShard.mutex.writer)
            {
                targetShard.targetToAction[targetId] = request.id;
            }
            
            synchronized (shard.mutex)
            {
                shard.actionToTarget[request.id] = targetId;
            }
        }

        // 2. Calculate dependencies count
        size_t dependencyCount = 0;
        // Use graph if available (more reliable for determining dependencies)
        BuildNode graphNode;
        if (targetId != TargetId.init)
        {
            graphNode = graph.getNodeByKey(targetId.toString());
            dependencyCount = graphNode !is null ? graphNode.dependencyIds.length : request.inputs.length;
        }
        else
        {
            dependencyCount = request.inputs.length;
        }

        // 3. Create and Insert ActionInfo
        // We insert with full dependency count first to avoid race where we mark it ready too early
        synchronized (shard.mutex)
        {
            if (request.id in shard.actions) return Ok!DistributedError();
            
            auto info = new ActionInfo(request.id, request, request.priority, dependencyCount);
            shard.actions[request.id] = info;
            
            // If no dependencies, it's ready immediately
            if (dependencyCount == 0)
                addReady(shard, info);
        }

        // 4. Check dependencies (The "Insert then Check" pattern)
        if (dependencyCount > 0 && graphNode !is null)
        {
            foreach (depId; graphNode.dependencyIds)
                checkDependencyAndDecrement(depId, request.id, shardIdx);
        }
        else if (dependencyCount > 0)
        {
             // Fallback for non-graph inputs (using artifact IDs)
             foreach (input; request.inputs)
             {
                 checkDependencyActionAndDecrement(input.id, request.id, shardIdx);
             }
        }

        return Ok!DistributedError();
    }
    
    /// Check if dependency is complete, and if so, decrement dependent's counter
    private void checkDependencyAndDecrement(TargetId depTargetId, ActionId dependentId, size_t dependentShardIdx) @trusted
    {
        // Find ActionId for this TargetId
        ActionId depActionId;
        bool found = false;
        
        auto targetShard = targetShards[getTargetShardIndex(depTargetId)];
        synchronized (targetShard.mutex.reader)
        {
            if (auto ptr = depTargetId in targetShard.targetToAction)
            {
                depActionId = *ptr;
                found = true;
            }
        }

        if (found)
        {
            checkDependencyActionAndDecrement(depActionId, dependentId, dependentShardIdx);
        }
        // If not found, it means dependency hasn't been scheduled yet. 
        // Action will wait until dependency completes and triggers it.
    }

    private void checkDependencyActionAndDecrement(ActionId depActionId, ActionId dependentId, size_t dependentShardIdx) @trusted
    {
        auto depShard = shards[getShardIndex(depActionId)];
        bool isComplete = false;

        synchronized (depShard.mutex)
        {
            if (auto info = depActionId in depShard.actions)
            {
                isComplete = (info.state == ActionState.Completed);
            }
        }

        if (isComplete)
        {
            decrementDependency(dependentId, dependentShardIdx);
        }
    }

    private void decrementDependency(ActionId dependentId, size_t shardIdx) @trusted
    {
        auto shard = shards[shardIdx];
        synchronized (shard.mutex)
        {
            if (auto info = dependentId in shard.actions)
            {
                // Only decrement if pending
                if (info.state == ActionState.Pending)
                {
                    if (atomicOp!"-="(info.remainingDeps, 1) == 0)
                    {
                        info.state = ActionState.Ready;
                        addReady(shard, *info);
                    }
                }
            }
        }
    }

    private void addReady(SchedulerShard shard, ActionInfo info) @trusted
    {
        auto cp = toConcurrencyPriority(info.priority);
        size_t cost = 0, depth = 0, dependents = 0;
        
        // Use profile data if available for critical-path scheduling
        if (profileGuidedEnabled && profileScheduler !is null)
        {
            if (auto targetId = info.id in shard.actionToTarget)
            {
                if (auto profile = profileScheduler.getProfile(targetId.toString()))
                {
                    cost = profile.criticalPathCost;
                    depth = profile.depth;
                    dependents = profile.dependentCount;
                }
            }
        }
        
        auto task = new Concurrency.PriorityTask!ActionId(info.id, cp, cost, depth, dependents);
        shard.readyQueue.insert(task);
    }
    
    private Concurrency.Priority toConcurrencyPriority(Priority p) pure nothrow @nogc
    {
        final switch (p)
        {
            case Priority.Low: return Concurrency.Priority.Low;
            case Priority.Normal: return Concurrency.Priority.Normal;
            case Priority.High: return Concurrency.Priority.High;
            case Priority.Critical: return Concurrency.Priority.Critical;
        }
    }

    /// Get next ready action (scans shards)
    Result!(ActionRequest, DistributedError) dequeueReady() @trusted
    {
        // To avoid contention on shard 0, start at random offset or round-robin
        import std.random : uniform;
        size_t startIdx = uniform(0, SHARD_COUNT);

        // First pass: Look for High/Critical priority
        for (size_t i = 0; i < SHARD_COUNT; i++)
        {
            auto idx = (startIdx + i) % SHARD_COUNT;
            auto shard = shards[idx];
            
            // Optimization: Check size before locking
            if (shard.readyQueue.empty) continue;

            synchronized (shard.mutex)
            {
                if (!shard.readyQueue.empty)
                {
                    // Check if highest priority is worth taking (optimization)
                    auto peek = shard.readyQueue.peek();
                    if (peek.priority >= Concurrency.Priority.High)
                    {
                        auto task = shard.readyQueue.extractMax();
                        if (auto info = task.payload in shard.actions)
                        {
                            info.state = ActionState.Scheduled;
                            return Ok!(ActionRequest, DistributedError)(info.request);
                        }
                    }
                }
            }
        }

        // Second pass: Take any ready
        for (size_t i = 0; i < SHARD_COUNT; i++)
        {
            auto idx = (startIdx + i) % SHARD_COUNT;
            auto shard = shards[idx];
            
            if (shard.readyQueue.empty) continue;

            synchronized (shard.mutex)
            {
                if (!shard.readyQueue.empty)
                {
                    auto task = shard.readyQueue.extractMax();
                    if (auto info = task.payload in shard.actions)
                    {
                        info.state = ActionState.Scheduled;
                        return Ok!(ActionRequest, DistributedError)(info.request);
                    }
                }
            }
        }
        
        return Err!(ActionRequest, DistributedError)(new DistributedError("No ready actions"));
    }
    
    /// Assign action to worker
    Result!DistributedError assign(ActionId action, WorkerId worker) @trusted
    {
        auto shard = shards[getShardIndex(action)];
        synchronized (shard.mutex)
        {
            if (auto info = action in shard.actions)
            {
                info.assignedWorker = worker;
                info.state = ActionState.Executing;
                registry.markInProgress(worker, action);
                return Ok!DistributedError();
            }
        }
        return Result!DistributedError.err(new DistributedError("Action not found: " ~ action.toString()));
    }
    
    /// Handle action completion
    void onComplete(ActionId action, ActionResult result) @trusted
    {
        auto shardIdx = getShardIndex(action);
        auto shard = shards[shardIdx];
        TargetId targetId;
        bool foundTarget = false;

        // 1. Mark completed
        synchronized (shard.mutex)
        {
            if (auto info = action in shard.actions)
            {
                info.state = ActionState.Completed;
                registry.markCompleted(info.assignedWorker, action, result.duration);
                
                if (auto tPtr = action in shard.actionToTarget)
                {
                    targetId = *tPtr;
                    foundTarget = true;
                }
            }
            else return; // Action not found
        }
        
        // 2. Notify dependents
        if (foundTarget)
        {
             if (auto node = graph.getNodeByKey(targetId.toString()))
             {
                 // Use Graph to find dependent TargetIds
                 foreach (dependentTargetId; node.dependentIds)
                 {
                     // Find ActionId for dependent TargetId
                     auto targetShard = targetShards[getTargetShardIndex(dependentTargetId)];
                     ActionId dependentActionId;
                     bool foundDep = false;
                     
                     synchronized (targetShard.mutex.reader)
                     {
                         if (auto ptr = dependentTargetId in targetShard.targetToAction)
                         {
                             dependentActionId = *ptr;
                             foundDep = true;
                         }
                     }
                     
                     if (foundDep)
                     {
                         decrementDependency(dependentActionId, getShardIndex(dependentActionId));
                     }
                 }
             }
        }
        // If not in graph (unlikely for distributed), manual scan is too slow.
        // We assume graph mode for performance.
    }
    
    /// Handle action failure with intelligent retry strategy
    void onFailure(ActionId action, string error) @trusted
    {
        auto shardIdx = getShardIndex(action);
        auto shard = shards[shardIdx];
        
        synchronized (shard.mutex)
        {
            if (auto info = action in shard.actions)
            {
                registry.markFailed(info.assignedWorker, action);
                structuredLog.warning("action_failed")
                    .field("action", action.toString())
                    .field("attempt", info.retries + 1)
                    .field("max_retries", MAX_RETRIES)
                    .field("error", error)
                    .emit();
                
                if (info.retries < MAX_RETRIES)
                {
                    info.retries++;
                    info.state = ActionState.Ready;
                    addReady(shard, *info);
                    structuredLog.info("action_queued_for_retry")
                        .field("action", action.toString())
                        .emit();
                }
                else
                {
                    info.state = ActionState.Failed;
                    structuredLog.error("action_failed_permanently")
                        .field("action", action.toString())
                        .field("attempts", MAX_RETRIES)
                        .emit();
                    propagateFailure(action, shardIdx);
                }
            }
        }
    }
    
    /// Propagate failure to dependent actions
    private void propagateFailure(ActionId failedAction, size_t shardIdx) @trusted
    {
        // Simple propagation: Check graph dependents and mark them Failed
        auto shard = shards[shardIdx];
        TargetId targetId;
        bool foundTarget = false;
        
        // Already holding lock? No, `onFailure` calls this.
        // But `onFailure` holds lock!
        // Avoid nested lock on same shard?
        // `propagateFailure` is called inside `onFailure`'s synchronized block?
        // Yes. So we already hold `shard` lock.
        
        if (auto tPtr = failedAction in shard.actionToTarget)
        {
            targetId = *tPtr;
            foundTarget = true;
        }
        
        if (foundTarget)
        {
            // We need to access Graph and then Other Shards.
            // We are holding Current Shard Lock.
            // This is potentially risky if we loop back. 
            // But propagation goes downstream.
            
            if (auto node = graph.getNodeByKey(targetId.toString()))
            {
                foreach (dependentTargetId; node.dependentIds)
                    markDependentFailed(dependentTargetId);
            }
        }
    }
    
    private void markDependentFailed(TargetId dependentTargetId) @trusted
    {
        auto targetShard = targetShards[getTargetShardIndex(dependentTargetId)];
        ActionId dependentActionId;
        bool found = false;
        
        synchronized (targetShard.mutex.reader)
        {
            if (auto ptr = dependentTargetId in targetShard.targetToAction)
            {
                dependentActionId = *ptr;
                found = true;
            }
        }
        
        if (found)
        {
            auto idx = getShardIndex(dependentActionId);
            auto shard = shards[idx];
            
            // Warning: Locking another shard while holding one.
            // Safe if DAG order.
            synchronized (shard.mutex)
            {
                if (auto info = dependentActionId in shard.actions)
                {
                    if (info.state != ActionState.Failed && info.state != ActionState.Completed)
                    {
                        info.state = ActionState.Failed;
                        structuredLog.debug_("dependent_marked_failed")
                            .field("action", dependentActionId.toString())
                            .emit();
                        
                        // Recurse
                        propagateFailure(dependentActionId, idx);
                    }
                }
            }
        }
    }
    
    /// Handle worker failure (reassign its work)
    void onWorkerFailure(WorkerId worker) @trusted
        {
            auto inProgress = registry.inProgressActions(worker);
            
            foreach (actionId; inProgress)
        {
            auto shard = shards[getShardIndex(actionId)];
            synchronized (shard.mutex)
            {
                if (auto info = actionId in shard.actions)
                {
                    info.state = ActionState.Ready;
                    info.assignedWorker = WorkerId(0);
                    info.retries++;
                    addReady(shard, *info);
                }
            }
        }
        structuredLog.info("actions_reassigned")
            .field("count", inProgress.length)
            .field("worker", worker.toString())
            .emit();
    }
    
    SchedulerStats getStats() @trusted
    {
        SchedulerStats stats;
        
        foreach (shard; shards)
        {
            synchronized (shard.mutex)
            {
                foreach (info; shard.actions.values)
                {
                    final switch (info.state)
                    {
                        case ActionState.Pending: stats.pending++; break;
                        case ActionState.Ready: stats.ready++; break;
                        case ActionState.Scheduled: stats.scheduled++; break;
                        case ActionState.Executing: stats.executing++; break;
                        case ActionState.Completed: stats.completed++; break;
                        case ActionState.Failed: stats.failed++; break;
                    }
                }
            }
        }
        return stats;
    }
    
    struct SchedulerStats
    {
        size_t pending;
        size_t ready;
        size_t scheduled;
        size_t executing;
        size_t completed;
        size_t failed;
    }
    
    void shutdown() @trusted { atomicStore(running, false); }
    bool isRunning() @trusted { return atomicLoad(running); }
}
