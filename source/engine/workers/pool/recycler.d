module engine.workers.pool.recycler;

import core.time : Duration, MonoTime, seconds, minutes, msecs;
import core.atomic;
import core.sync.mutex : Mutex;
import std.algorithm : filter, map, maxElement, minElement;
import std.array : array;
import std.conv : to;
import engine.workers.protocol.types : WorkerId, WorkerState;
import infrastructure.utils.logging;

/// Worker warmth level - indicates JVM/V8 optimization state
/// Cold → Warm: ~2-3s for JVM, ~200ms for V8
/// Warm → Hot: Additional runtime optimizations kick in
enum WarmthLevel : ubyte
{
    Cold,       /// Just started, no JIT optimization
    Warming,    /// Initial compilations done, JIT warming
    Warm,       /// Steady state, good performance
    Hot         /// Fully optimized, peak performance
}

/// Warmth thresholds (requests completed)
struct WarmthThresholds
{
    uint coldToWarming = 1;    /// After first request
    uint warmingToWarm = 5;    /// Basic JIT kicks in
    uint warmToHot = 50;       /// Full optimization
    
    WarmthLevel levelFor(uint requests) const pure nothrow @nogc @safe
    {
        if (requests >= warmToHot) return WarmthLevel.Hot;
        if (requests >= warmingToWarm) return WarmthLevel.Warm;
        if (requests >= coldToWarming) return WarmthLevel.Warming;
        return WarmthLevel.Cold;
    }
}

/// Per-worker warmth tracking
struct WorkerWarmth
{
    WorkerId id;
    WarmthLevel level = WarmthLevel.Cold;
    uint requestsCompleted;
    MonoTime lastActivity;
    MonoTime startTime;
    Duration totalActiveTime;
    
    /// Record completed request, update warmth
    void recordRequest(WarmthThresholds thresholds) @safe
    {
        requestsCompleted++;
        lastActivity = MonoTime.currTime;
        level = thresholds.levelFor(requestsCompleted);
    }
    
    /// Calculate idle duration
    Duration idleDuration() const @safe
    {
        return MonoTime.currTime - lastActivity;
    }
    
    /// Calculate uptime
    Duration uptime() const @safe
    {
        return MonoTime.currTime - startTime;
    }
    
    /// Warmth score [0.0, 1.0] for prioritization
    float score() const pure nothrow @nogc @safe
    {
        final switch (level)
        {
            case WarmthLevel.Cold: return 0.0f;
            case WarmthLevel.Warming: return 0.33f;
            case WarmthLevel.Warm: return 0.66f;
            case WarmthLevel.Hot: return 1.0f;
        }
    }
}

/// Recycling policy configuration
struct RecyclingPolicy
{
    Duration maxIdleTime = minutes(10);     /// Evict after idle
    Duration minKeepWarmTime = minutes(2);  /// Keep warm workers at least this long
    Duration hotWorkerBonus = minutes(5);   /// Extra idle time for hot workers
    uint maxRequestsBeforeRecycle = 10_000; /// Recycle after N requests
    bool preferWarmWorkers = true;          /// Prefer warm over cold for new work
    bool keepHotAcrossBuilds = true;        /// Persist hot workers between builds
}

/// Recycler - manages warmth state and recycling decisions
/// Single responsibility: warmth tracking and recycle/keep decisions
final class WorkerRecycler
{
    private RecyclingPolicy policy;
    private WarmthThresholds thresholds;
    private WorkerWarmth[string] warmthRegistry;
    private Mutex mutex;
    
    // Statistics
    private shared size_t _recycled;
    private shared size_t _preserved;
    private shared size_t _warmStartups;
    
    this(RecyclingPolicy policy = RecyclingPolicy.init,
         WarmthThresholds thresholds = WarmthThresholds.init) @trusted
    {
        this.policy = policy;
        this.thresholds = thresholds;
        this.mutex = new Mutex();
    }
    
    /// Register new worker
    void register(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            auto key = id.toString();
            warmthRegistry[key] = WorkerWarmth(
                id,
                WarmthLevel.Cold,
                0,
                MonoTime.currTime,
                MonoTime.currTime,
                Duration.zero
            );
        }
    }
    
    /// Record completed request
    void recordRequest(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            if (auto w = id.toString() in warmthRegistry)
            {
                w.recordRequest(thresholds);
                if (w.level >= WarmthLevel.Warm)
                    atomicOp!"+="(_warmStartups, 1);
            }
        }
    }
    
    /// Get warmth level for worker
    WarmthLevel getWarmth(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            if (auto w = id.toString() in warmthRegistry)
                return w.level;
            return WarmthLevel.Cold;
        }
    }
    
    /// Should this worker be recycled (terminated and replaced)?
    bool shouldRecycle(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            auto w = id.toString() in warmthRegistry;
            if (w is null) return true;
            
            // Request limit reached
            if (w.requestsCompleted >= policy.maxRequestsBeforeRecycle)
                return true;
            
            return false;
        }
    }
    
    /// Should this worker be evicted due to idle timeout?
    bool shouldEvict(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            auto w = id.toString() in warmthRegistry;
            if (w is null) return true;
            
            auto idle = w.idleDuration();
            auto maxIdle = policy.maxIdleTime;
            
            // Hot workers get bonus idle time
            if (w.level == WarmthLevel.Hot && policy.keepHotAcrossBuilds)
                maxIdle += policy.hotWorkerBonus;
            
            // Warm workers get minimum keep time
            if (w.level >= WarmthLevel.Warm && w.uptime() < policy.minKeepWarmTime)
                return false;
            
            return idle > maxIdle;
        }
    }
    
    /// Select best worker from available pool (prefer warm)
    WorkerId selectBest(WorkerId[] available) @trusted
    {
        if (available.length == 0)
            return WorkerId.init;
        
        if (!policy.preferWarmWorkers || available.length == 1)
            return available[0];
        
        synchronized (mutex)
        {
            WorkerId best = available[0];
            float bestScore = -1.0f;
            
            foreach (id; available)
            {
                if (auto w = id.toString() in warmthRegistry)
                {
                    if (w.score() > bestScore)
                    {
                        bestScore = w.score();
                        best = id;
                    }
                }
            }
            
            return best;
        }
    }
    
    /// Unregister worker
    void unregister(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            auto key = id.toString();
            if (auto w = key in warmthRegistry)
            {
                if (shouldRecycle(id))
                    atomicOp!"+="(_recycled, 1);
                else
                    atomicOp!"+="(_preserved, 1);
                
                warmthRegistry.remove(key);
            }
        }
    }
    
    /// Get workers that should be evicted
    WorkerId[] getEvictable() @trusted
    {
        WorkerId[] result;
        
        synchronized (mutex)
        {
            foreach (key, ref w; warmthRegistry)
            {
                if (shouldEvict(w.id))
                    result ~= w.id;
            }
        }
        
        return result;
    }
    
    /// Statistics
    struct RecyclerStats
    {
        size_t tracked;
        size_t recycled;
        size_t preserved;
        size_t warmStartups;
        size_t[WarmthLevel] byLevel;
    }
    
    RecyclerStats getStats() @trusted
    {
        RecyclerStats stats;
        stats.recycled = atomicLoad(_recycled);
        stats.preserved = atomicLoad(_preserved);
        stats.warmStartups = atomicLoad(_warmStartups);
        
        synchronized (mutex)
        {
            stats.tracked = warmthRegistry.length;
            foreach (ref w; warmthRegistry)
                stats.byLevel[w.level] = stats.byLevel.get(w.level, 0) + 1;
        }
        
        return stats;
    }
    
    /// Estimated speedup from warm workers
    float estimatedSpeedup() @trusted
    {
        auto stats = getStats();
        if (stats.tracked == 0) return 1.0f;
        
        // Weight by warmth level: Hot=20x, Warm=10x, Warming=3x, Cold=1x
        float totalWeight = 0;
        synchronized (mutex)
        {
            foreach (ref w; warmthRegistry)
            {
                final switch (w.level)
                {
                    case WarmthLevel.Cold: totalWeight += 1.0f; break;
                    case WarmthLevel.Warming: totalWeight += 3.0f; break;
                    case WarmthLevel.Warm: totalWeight += 10.0f; break;
                    case WarmthLevel.Hot: totalWeight += 20.0f; break;
                }
            }
        }
        
        return totalWeight / stats.tracked;
    }
}

