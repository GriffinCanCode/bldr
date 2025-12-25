module engine.runtime.hermetic.sandbox.cgroups;

version(linux):

import std.file : exists, mkdirRecurse, readText, write, rmdirRecurse;
import std.path : buildPath;
import std.conv : to;
import std.string : strip, splitLines;
import std.uuid : randomUUID;
import std.datetime : Duration, msecs;

import engine.runtime.hermetic.core.spec : ResourceLimits;
import engine.runtime.hermetic.sandbox.contract;
import infrastructure.errors;

/// Cgroup v2 resource controller
/// 
/// Design: Single unified hierarchy (cgroup v2) with:
/// - memory.max: Hard memory limit with OOM kill
/// - cpu.weight: Proportional CPU allocation
/// - io.max: I/O bandwidth limits
/// - pids.max: Process count limits
final class CgroupController
{
    private string cgroupPath;
    private ResourceLimits limits;
    private bool initialized;
    
    private this(string path, ResourceLimits lim) @safe
    {
        cgroupPath = path;
        limits = lim;
        initialized = true;
    }
    
    /// Create cgroup with resource limits
    static BuildResult!CgroupController create(ResourceLimits limits) @system
    {
        immutable root = detectCgroupRoot();
        if (root.length == 0)
            return BuildResult!CgroupController.err(sandboxError(
                SandboxErrorKind.Initialization, "cgroup v2 not available"));
        
        // Create unique cgroup under builder hierarchy
        immutable cgPath = buildPath(root, "builder", randomUUID().toString());
        
        try
        {
            mkdirRecurse(cgPath);
        }
        catch (Exception e)
        {
            return BuildResult!CgroupController.err(sandboxError(
                SandboxErrorKind.Permission, "Cannot create cgroup: " ~ e.msg));
        }
        
        auto controller = new CgroupController(cgPath, limits);
        
        // Apply limits
        auto applyResult = controller.applyLimits();
        if (applyResult.isErr)
            return BuildResult!CgroupController.err(applyResult.unwrapErr());
        
        return BuildResult!CgroupController.ok(controller);
    }
    
    /// Add process to cgroup
    void addProcess(int pid) @system
    {
        if (!initialized)
            return;
        
        try
        {
            write(buildPath(cgroupPath, "cgroup.procs"), pid.to!string ~ "\n");
        }
        catch (Exception) {}
    }
    
    /// Get current metrics from cgroup
    CgroupMetrics metrics() @system
    {
        CgroupMetrics m;
        
        if (!initialized)
            return m;
        
        try
        {
            // Memory stats
            auto memCurrent = readPath("memory.current");
            auto memPeak = readPath("memory.peak");
            auto memEvents = readKeyValue("memory.events");
            
            m.currentMemory = parseBytes(memCurrent);
            m.peakMemory = parseBytes(memPeak);
            m.oomKilled = (memEvents.get("oom_kill", "0") != "0");
            
            // CPU stats
            auto cpuStat = readKeyValue("cpu.stat");
            m.userTime = msecs(parseBytes(cpuStat.get("user_usec", "0")) / 1000);
            m.systemTime = msecs(parseBytes(cpuStat.get("system_usec", "0")) / 1000);
            
            // I/O stats
            auto ioStat = readPath("io.stat");
            parseIoStats(ioStat, m);
            
            // Process count
            auto procs = readPath("pids.current");
            m.processes = cast(uint) parseBytes(procs);
        }
        catch (Exception) {}
        
        return m;
    }
    
    /// Cleanup cgroup (must be empty)
    void cleanup() @system
    {
        if (!initialized)
            return;
        
        // Kill any remaining processes
        try
        {
            write(buildPath(cgroupPath, "cgroup.kill"), "1");
        }
        catch (Exception) {}
        
        // Wait briefly for processes to die
        import core.thread : Thread;
        import core.time : msecs;
        Thread.sleep(10.msecs);
        
        // Remove cgroup
        try
        {
            rmdirRecurse(cgroupPath);
        }
        catch (Exception) {}
        
        initialized = false;
    }
    
    private BuildResult!void applyLimits() @system
    {
        try
        {
            // Memory limit
            if (limits.maxMemoryBytes > 0)
            {
                write(buildPath(cgroupPath, "memory.max"), limits.maxMemoryBytes.to!string);
                
                // Set soft limit at 90% for graceful handling
                immutable softLimit = limits.maxMemoryBytes * 9 / 10;
                write(buildPath(cgroupPath, "memory.high"), softLimit.to!string);
            }
            
            // CPU weight (1-10000, default 100)
            if (limits.cpuShares > 0)
            {
                // Convert from cgroup v1 shares (2-262144, default 1024) to v2 weight
                immutable weight = (limits.cpuShares * 100) / 1024;
                immutable clampedWeight = weight < 1 ? 1 : (weight > 10000 ? 10000 : weight);
                write(buildPath(cgroupPath, "cpu.weight"), clampedWeight.to!string);
            }
            
            // Process limit
            if (limits.maxProcesses > 0)
            {
                write(buildPath(cgroupPath, "pids.max"), limits.maxProcesses.to!string);
            }
            
            // I/O limits (if device known)
            if (limits.maxDiskIO > 0)
            {
                // TODO: Detect block device and apply rbps/wbps limits
            }
            
            return BuildResult!void.ok();
        }
        catch (Exception e)
        {
            return BuildResult!void.err(sandboxError(
                SandboxErrorKind.Permission, "Cannot apply cgroup limits: " ~ e.msg));
        }
    }
    
    private string readPath(string filename) @system
    {
        return exists(buildPath(cgroupPath, filename)) ? 
               readText(buildPath(cgroupPath, filename)).strip : "";
    }
    
    private string[string] readKeyValue(string filename) @system
    {
        string[string] result;
        auto content = readPath(filename);
        
        foreach (line; content.splitLines)
        {
            auto parts = line.strip.split(" ");
            if (parts.length >= 2)
                result[parts[0]] = parts[1];
        }
        
        return result;
    }
    
    private static ulong parseBytes(string s) @safe pure nothrow
    {
        import std.conv : to;
        try
        {
            return s.strip.to!ulong;
        }
        catch (Exception)
        {
            return 0;
        }
    }
    
    private static void parseIoStats(string content, ref CgroupMetrics m) @safe
    {
        // Format: "major:minor rbytes=X wbytes=Y ..."
        import std.regex : regex, matchAll;
        
        foreach (line; content.splitLines)
        {
            auto rbMatch = line.matchAll(regex(`rbytes=(\d+)`));
            auto wbMatch = line.matchAll(regex(`wbytes=(\d+)`));
            
            foreach (match; rbMatch)
                m.diskRead += parseBytes(match[1]);
            foreach (match; wbMatch)
                m.diskWrite += parseBytes(match[1]);
        }
    }
    
    private static string[] split(string s, string delim) @safe pure
    {
        import std.algorithm : splitter;
        import std.array : array;
        return s.splitter(delim).array;
    }
    
    ~this() @system { cleanup(); }
}

/// Metrics collected from cgroup
struct CgroupMetrics
{
    ulong currentMemory;
    ulong peakMemory;
    Duration userTime;
    Duration systemTime;
    ulong diskRead;
    ulong diskWrite;
    uint processes;
    bool oomKilled;
}

/// Detect cgroup v2 unified hierarchy mount point
private string detectCgroupRoot() @system nothrow
{
    // Check standard cgroup v2 mount point
    if (exists("/sys/fs/cgroup/cgroup.controllers"))
        return "/sys/fs/cgroup";
    
    // Check systemd mount point
    if (exists("/sys/fs/cgroup/unified/cgroup.controllers"))
        return "/sys/fs/cgroup/unified";
    
    return "";
}

/// Check if cgroup v2 is available
bool isCgroupV2Available() @system nothrow
{
    return detectCgroupRoot().length > 0;
}

@system unittest
{
    // Test cgroup detection
    if (isCgroupV2Available())
    {
        auto result = CgroupController.create(ResourceLimits.hermetic());
        assert(result.isOk);
        
        auto controller = result.unwrap();
        auto metrics = controller.metrics();
        
        assert(metrics.peakMemory >= 0);
        controller.cleanup();
    }
}


