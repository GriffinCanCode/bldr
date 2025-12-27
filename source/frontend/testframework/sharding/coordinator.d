module frontend.testframework.sharding.coordinator;

import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import std.datetime : MonoTime, Duration;
import core.atomic;
import core.sync.mutex : Mutex;
import frontend.testframework.sharding.strategy;
import infrastructure.utils.logging;

/// Shard execution state
enum ShardState
{
    Pending,    // Not started
    Running,    // Currently executing
    Completed,  // Finished successfully
    Failed,     // Failed execution
    Stolen      // Stolen by another worker
}

/// Shard execution context
struct ShardContext
{
    TestShard shard;
    ShardState state;
    size_t workerId;           // Worker assigned to this shard
    MonoTime startTime;        // When execution started
    MonoTime endTime;          // When execution completed
    size_t actualDurationMs;   // Actual execution time
    
    /// Get elapsed time in milliseconds
    size_t elapsedMs() const nothrow @trusted
    {
        if (state != ShardState.Running)
            return actualDurationMs;
        
        immutable now = MonoTime.currTime();
        immutable elapsed = now - startTime;
        return cast(size_t)(elapsed.total!"msecs");
    }
}

/// Coordinates shard execution across workers
/// Integrates with work-stealing scheduler
final class ShardCoordinator
{
    private ShardContext[] shards;
    private Mutex mutex;
    private shared size_t completedCount;
    private shared size_t failedCount;
    
    this() @safe
    {
        mutex = new Mutex();
        atomicStore(completedCount, cast(size_t)0);
        atomicStore(failedCount, cast(size_t)0);
    }
    
    /// Initialize shards for execution
    void initialize(TestShard[] testShards) @trusted
    {
        synchronized (mutex)
        {
            shards.reserve(testShards.length);
            
            foreach (testShard; testShards)
            {
                ShardContext context;
                context.shard = testShard;
                context.state = ShardState.Pending;
                shards ~= context;
            }
        }
        
        structuredLog.debug_("initialized_").field("detail", "Initialized " ~ testShards.length.to!string ~ " shards").emit();
    }
    
    /// Claim next available shard for worker
    /// Returns null if no shards available
    ShardContext* claimShard(size_t workerId) @trusted
    {
        synchronized (mutex)
        {
            // Find first pending shard
            foreach (ref context; shards)
            {
                if (context.state == ShardState.Pending)
                {
                    context.state = ShardState.Running;
                    context.workerId = workerId;
                    context.startTime = MonoTime.currTime();
                    return &context;
                }
            }
            
            return null;
        }
    }
    
    /// Mark shard as completed
    void completeShard(string testId, size_t actualDurationMs) @trusted
    {
        synchronized (mutex)
        {
            foreach (ref context; shards)
            {
                if (context.shard.testId == testId && context.state == ShardState.Running)
                {
                    context.state = ShardState.Completed;
                    context.endTime = MonoTime.currTime();
                    context.actualDurationMs = actualDurationMs;
                    atomicOp!"+="(completedCount, 1);
                    return;
                }
            }
        }
    }
    
    /// Mark shard as failed
    void failShard(string testId) @trusted
    {
        synchronized (mutex)
        {
            foreach (ref context; shards)
            {
                if (context.shard.testId == testId && context.state == ShardState.Running)
                {
                    context.state = ShardState.Failed;
                    context.endTime = MonoTime.currTime();
                    atomicOp!"+="(failedCount, 1);
                    return;
                }
            }
        }
    }
    
    /// Check if all shards complete
    bool isComplete() @trusted nothrow
    {
        immutable completed = atomicLoad(completedCount);
        immutable failed = atomicLoad(failedCount);
        
        return (completed + failed) >= shards.length;
    }
    
    /// Get completion progress
    double progress() @trusted nothrow
    {
        if (shards.length == 0)
            return 1.0;
        
        immutable completed = atomicLoad(completedCount);
        immutable failed = atomicLoad(failedCount);
        
        return cast(double)(completed + failed) / shards.length;
    }
    
    /// Get shards for specific shard ID
    TestShard[] getShardsForId(size_t shardId) @trusted
    {
        synchronized (mutex)
        {
            return shards
                .filter!(c => c.shard.shardId == shardId && c.state == ShardState.Pending)
                .map!(c => c.shard)
                .array;
        }
    }
    
    /// Get all pending shards (for work stealing)
    TestShard[] getPendingShards() @trusted
    {
        synchronized (mutex)
        {
            return shards
                .filter!(c => c.state == ShardState.Pending)
                .map!(c => c.shard)
                .array;
        }
    }
    
    /// Attempt to steal shard from another worker
    ShardContext* stealShard(size_t thiefWorkerId) @trusted
    {
        synchronized (mutex)
        {
            // Find longest running shard that can be stolen
            ShardContext* candidate = null;
            size_t maxDuration = 0;
            
            foreach (ref context; shards)
            {
                if (context.state == ShardState.Running)
                {
                    immutable elapsed = context.elapsedMs();
                    
                    // Only steal if running longer than 2x estimate
                    if (elapsed > context.shard.estimatedMs * 2 && elapsed > maxDuration)
                    {
                        candidate = &context;
                        maxDuration = elapsed;
                    }
                }
            }
            
            if (candidate !is null)
            {
                candidate.state = ShardState.Stolen;
                structuredLog.debug_("worker_").field("detail", "Worker " ~ thiefWorkerId.to!string ~ 
                    " stole shard from worker " ~ candidate.workerId.to!string).emit();
            }
            
            return candidate;
        }
    }
    
    /// Get execution statistics
    struct ExecutionStats
    {
        size_t totalShards;
        size_t completedShards;
        size_t failedShards;
        size_t runningShards;
        size_t totalDurationMs;
        double averageDurationMs;
        double efficiency;  // Actual vs estimated
    }
    
    ExecutionStats getStats() @trusted
    {
        ExecutionStats stats;
        
        synchronized (mutex)
        {
            stats.totalShards = shards.length;
            
            size_t estimatedTotal = 0;
            size_t actualTotal = 0;
            
            foreach (ref context; shards)
            {
                estimatedTotal += context.shard.estimatedMs;
                
                final switch (context.state)
                {
                    case ShardState.Pending:
                        break;
                    case ShardState.Running:
                        stats.runningShards++;
                        break;
                    case ShardState.Completed:
                        stats.completedShards++;
                        actualTotal += context.actualDurationMs;
                        break;
                    case ShardState.Failed:
                        stats.failedShards++;
                        break;
                    case ShardState.Stolen:
                        break;
                }
            }
            
            stats.totalDurationMs = actualTotal;
            
            if (stats.completedShards > 0)
                stats.averageDurationMs = cast(double)actualTotal / stats.completedShards;
            
            if (estimatedTotal > 0 && actualTotal > 0)
                stats.efficiency = cast(double)estimatedTotal / actualTotal;
        }
        
        return stats;
    }
}

