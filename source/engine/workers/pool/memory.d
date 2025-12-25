module engine.workers.pool.memory;

import core.time : Duration, MonoTime, seconds, msecs;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.algorithm : max, min;
import std.conv : to;
import std.process : ProcessPipes, tryWait;
import engine.workers.protocol.types : WorkerId;
import infrastructure.utils.logging.logger;

/// Memory pressure level
enum MemoryPressure : ubyte
{
    Normal,     /// < 70% usage
    Elevated,   /// 70-85% usage  
    High,       /// 85-95% usage
    Critical    /// > 95% usage (OOM imminent)
}

/// Memory metrics for a worker process
struct WorkerMemory
{
    WorkerId id;
    size_t heapUsedBytes;
    size_t heapMaxBytes;
    size_t rssBytes;          /// Resident set size
    MonoTime lastSample;
    MemoryPressure pressure;
    
    /// Calculate heap usage ratio [0.0, 1.0]
    float heapUsageRatio() const pure nothrow @nogc @safe
    {
        return heapMaxBytes > 0 ? cast(float)heapUsedBytes / heapMaxBytes : 0.0f;
    }
    
    /// Check if at OOM risk
    bool isOOMRisk() const pure nothrow @nogc @safe
    {
        return pressure >= MemoryPressure.High;
    }
    
    /// Check if critical (should restart immediately)
    bool isCritical() const pure nothrow @nogc @safe
    {
        return pressure == MemoryPressure.Critical;
    }
}

/// Memory thresholds configuration
struct MemoryThresholds
{
    float normalMax = 0.70f;      /// Below this is normal
    float elevatedMax = 0.85f;    /// Below this is elevated
    float highMax = 0.95f;        /// Below this is high, above is critical
    size_t minHeapMB = 256;       /// Minimum heap to track
    size_t maxHeapMB = 8192;      /// Maximum expected heap
    
    MemoryPressure pressureFor(float ratio) const pure nothrow @nogc @safe
    {
        if (ratio >= highMax) return MemoryPressure.Critical;
        if (ratio >= elevatedMax) return MemoryPressure.High;
        if (ratio >= normalMax) return MemoryPressure.Elevated;
        return MemoryPressure.Normal;
    }
}

/// Memory monitor - collects memory metrics from worker processes
/// Single responsibility: memory observation and OOM risk detection
final class WorkerMemoryMonitor
{
    private MemoryThresholds thresholds;
    private WorkerMemory[string] metrics;
    private Mutex mutex;
    private shared bool running;
    private Thread pollThread;
    private Duration pollInterval;
    
    // Statistics
    private shared size_t _oomDetections;
    private shared size_t _samples;
    
    this(MemoryThresholds thresholds = MemoryThresholds.init,
         Duration pollInterval = seconds(5)) @trusted
    {
        this.thresholds = thresholds;
        this.pollInterval = pollInterval;
        this.mutex = new Mutex();
    }
    
    /// Start monitoring
    void start() @trusted
    {
        if (atomicLoad(running)) return;
        atomicStore(running, true);
        pollThread = new Thread(&pollLoop);
        pollThread.start();
        Logger.info("Worker memory monitor started");
    }
    
    /// Stop monitoring
    void stop() @trusted
    {
        atomicStore(running, false);
        if (pollThread !is null)
        {
            pollThread.join();
            pollThread = null;
        }
        Logger.info("Worker memory monitor stopped");
    }
    
    /// Register worker for monitoring
    void register(WorkerId id, size_t maxHeapBytes) @trusted
    {
        synchronized (mutex)
        {
            metrics[id.toString()] = WorkerMemory(
                id, 0, maxHeapBytes, 0,
                MonoTime.currTime, MemoryPressure.Normal
            );
        }
    }
    
    /// Update memory metrics for worker
    void update(WorkerId id, size_t heapUsed, size_t rss = 0) @trusted
    {
        synchronized (mutex)
        {
            if (auto m = id.toString() in metrics)
            {
                m.heapUsedBytes = heapUsed;
                if (rss > 0) m.rssBytes = rss;
                m.lastSample = MonoTime.currTime;
                m.pressure = thresholds.pressureFor(m.heapUsageRatio());
                
                atomicOp!"+="(_samples, 1);
                
                if (m.isCritical())
                {
                    atomicOp!"+="(_oomDetections, 1);
                    Logger.warning("OOM risk detected: " ~ id.toString() ~
                                 " (heap: " ~ (heapUsed / 1024 / 1024).to!string ~ "MB)");
                }
            }
        }
    }
    
    /// Get memory metrics for worker
    WorkerMemory getMetrics(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            if (auto m = id.toString() in metrics)
                return *m;
            return WorkerMemory.init;
        }
    }
    
    /// Get pressure level for worker
    MemoryPressure getPressure(WorkerId id) @trusted
    {
        synchronized (mutex)
        {
            if (auto m = id.toString() in metrics)
                return m.pressure;
            return MemoryPressure.Normal;
        }
    }
    
    /// Check if worker is at OOM risk
    bool isOOMRisk(WorkerId id) @trusted
    {
        return getPressure(id) >= MemoryPressure.High;
    }
    
    /// Check if worker is critical (needs immediate restart)
    bool isCritical(WorkerId id) @trusted
    {
        return getPressure(id) == MemoryPressure.Critical;
    }
    
    /// Get all workers at OOM risk
    WorkerId[] getAtRisk() @trusted
    {
        WorkerId[] result;
        synchronized (mutex)
        {
            foreach (ref m; metrics)
            {
                if (m.isOOMRisk())
                    result ~= m.id;
            }
        }
        return result;
    }
    
    /// Unregister worker
    void unregister(WorkerId id) @trusted
    {
        synchronized (mutex)
            metrics.remove(id.toString());
    }
    
    /// Statistics
    struct MemoryStats
    {
        size_t monitored;
        size_t atRisk;
        size_t critical;
        size_t totalSamples;
        size_t oomDetections;
        size_t totalHeapMB;
        size_t totalRssMB;
    }
    
    MemoryStats getStats() @trusted
    {
        MemoryStats stats;
        stats.totalSamples = atomicLoad(_samples);
        stats.oomDetections = atomicLoad(_oomDetections);
        
        synchronized (mutex)
        {
            stats.monitored = metrics.length;
            foreach (ref m; metrics)
            {
                if (m.isCritical()) stats.critical++;
                else if (m.isOOMRisk()) stats.atRisk++;
                stats.totalHeapMB += m.heapUsedBytes / 1024 / 1024;
                stats.totalRssMB += m.rssBytes / 1024 / 1024;
            }
        }
        
        return stats;
    }
    
    private void pollLoop() @trusted
    {
        while (atomicLoad(running))
        {
            Thread.sleep(pollInterval);
            if (!atomicLoad(running)) break;
            
            // Check for stale metrics (worker may have died)
            auto now = MonoTime.currTime;
            auto staleThreshold = pollInterval * 3;
            
            synchronized (mutex)
            {
                foreach (key, ref m; metrics)
                {
                    if (now - m.lastSample > staleThreshold)
                    {
                        // Mark as unknown - coordinator should check if alive
                        m.pressure = MemoryPressure.Normal;
                    }
                }
            }
        }
    }
}

/// Parse JVM GC log output for memory metrics
/// Returns (heapUsed, heapMax) in bytes, or (0, 0) on parse failure
auto parseJVMMemory(string gcOutput) pure @safe
{
    struct Result { size_t used; size_t max; }
    
    // Simple heuristic: look for patterns like "Heap: 512M of 2048M"
    // Real implementation would parse -Xlog:gc output
    return Result(0, 0);
}

/// Parse Node.js memory from process.memoryUsage() JSON output
auto parseNodeMemory(string memOutput) pure @safe
{
    struct Result { size_t heapUsed; size_t heapTotal; size_t rss; }
    
    // Would parse: {"heapUsed": 12345678, "heapTotal": 23456789, "rss": 34567890}
    return Result(0, 0, 0);
}

