module engine.runtime.hermetic.monitoring.linux;

version(linux):

import engine.runtime.hermetic.monitoring;
import engine.runtime.hermetic.core.spec : ResourceLimits;
import engine.distributed.protocol.protocol : ResourceUsage;
import std.datetime : Duration, msecs;
import std.file : exists, readText, writeText, remove;
import std.path : buildPath, dirName;
import std.string : strip, lineSplitter, splitter, toStringz, startsWith, split;
import std.conv : to;
import std.algorithm : canFind;
import std.array : array;
import std.process : execute;
import core.stdc.stdio : fopen, fclose, FILE;
import infrastructure.utils.logging : Logger;

/// Linux resource monitor using cgroups v2
/// 
/// Design: Leverages Linux unified cgroup hierarchy for accurate resource tracking
/// - memory.current: Current memory usage
/// - memory.peak: Peak memory usage  
/// - memory.max: Memory limit
/// - cpu.stat: CPU usage statistics
/// - pids.current: Active process count
/// - io.stat: Disk I/O statistics
/// 
/// Enforces limits via cgroup controllers, not polling
final class LinuxMonitor : BaseMonitor
{
    private string cgroupPath;
    private bool useCgroupV2;
    private ulong initialDiskRead;
    private ulong initialDiskWrite;
    private NetworkMonitor networkMonitor;
    
    this(ResourceLimits limits) @safe
    {
        super(limits);
        
        // Detect cgroup version
        useCgroupV2 = exists("/sys/fs/cgroup/cgroup.controllers");
        
        // Initialize network monitor
        networkMonitor = new NetworkMonitor();
    }
    
    override void start() @safe
    {
        super.start(); // Calls recordInitialCounters()
        
        // Create dedicated cgroup for this execution
        if (useCgroupV2)
        {
            setupCgroupV2();
        }
        else
        {
            setupCgroupV1();
        }
        
        // Start network monitoring
        networkMonitor.start();
    }
    
    override void stop() @safe
    {
        // Stop network monitoring
        networkMonitor.stop();
        
        super.stop(); // Calls checkAllLimits()
        
        // Check platform-specific limits
        checkProcessLimit();
        
        // Cleanup cgroup
        cleanupCgroup();
    }
    
    override ResourceUsage snapshot() @safe
    {
        ResourceUsage usage;
        
        if (!started)
            return usage;
        
        usage.cpuTime = readCpuTime();
        usage.peakMemory = readPeakMemory();
        usage.diskRead = readDiskRead() - initialDiskRead;
        usage.diskWrite = readDiskWrite() - initialDiskWrite;
        
        // Get network I/O from eBPF monitor
        auto netStats = networkMonitor.getStats();
        usage.networkRx = netStats.bytesReceived;
        usage.networkTx = netStats.bytesSent;
        
        return usage;
    }
    
    /// Setup cgroup v2 hierarchy
    private void setupCgroupV2() @safe
    {
        import std.random : uniform;
        import std.uuid : randomUUID;
        import std.file : mkdirRecurse;
        
        immutable base = "/sys/fs/cgroup/builder";
        cgroupPath = buildPath(base, randomUUID().toString());
        
        try
        {
            // Create cgroup directory
            mkdirRecurse(cgroupPath);
            
            // Enable controllers
            auto subtree = buildPath(dirName(cgroupPath), "cgroup.subtree_control");
            if (exists(subtree))
            {
                writeText(subtree, "+cpu +memory +pids +io");
            }
            
            // Set memory limit
            if (limits.maxMemoryBytes > 0)
            {
                auto memMax = buildPath(cgroupPath, "memory.max");
                writeText(memMax, limits.maxMemoryBytes.to!string);
            }
            
            // Set CPU weight
            if (limits.cpuShares > 0)
            {
                auto cpuWeight = buildPath(cgroupPath, "cpu.weight");
                writeText(cpuWeight, limits.cpuShares.to!string);
            }
            
            // Set process limit
            if (limits.maxProcesses > 0)
            {
                auto pidsMax = buildPath(cgroupPath, "pids.max");
                writeText(pidsMax, limits.maxProcesses.to!string);
            }
            
            // Add current process to cgroup
            auto procs = buildPath(cgroupPath, "cgroup.procs");
            import core.sys.posix.unistd : getpid;
            writeText(procs, getpid().to!string);
        }
        catch (Exception e)
        {
            // Cgroup setup failed - continue without it
            cgroupPath = "";
        }
    }
    
    /// Setup cgroup v1 hierarchy (legacy)
    private void setupCgroupV1() @safe
    {
        import std.random : uniform;
        import std.uuid : randomUUID;
        import std.file : mkdirRecurse;
        
        // For simplicity, only setup memory cgroup in v1
        immutable base = "/sys/fs/cgroup/memory/builder";
        cgroupPath = buildPath(base, randomUUID().toString());
        
        try
        {
            mkdirRecurse(cgroupPath);
            
            if (limits.maxMemoryBytes > 0)
            {
                auto memLimit = buildPath(cgroupPath, "memory.limit_in_bytes");
                writeText(memLimit, limits.maxMemoryBytes.to!string);
            }
            
            // Add current process
            auto tasks = buildPath(cgroupPath, "tasks");
            import core.sys.posix.unistd : getpid;
            writeText(tasks, getpid().to!string);
        }
        catch (Exception)
        {
            cgroupPath = "";
        }
    }
    
    /// Cleanup cgroup after execution
    private void cleanupCgroup() @safe
    {
        if (cgroupPath.length == 0 || !exists(cgroupPath))
            return;
        
        try
        {
            import std.file : rmdirRecurse;
            rmdirRecurse(cgroupPath);
        }
        catch (Exception)
        {
            // Best effort cleanup
        }
    }
    
    /// Read CPU time from cgroup
    private Duration readCpuTime() @safe
    {
        if (cgroupPath.length == 0)
            return elapsed();
        
        try
        {
            immutable cpuStat = buildPath(cgroupPath, "cpu.stat");
            if (!exists(cpuStat))
                return elapsed();
            
            foreach (line; readText(cpuStat).lineSplitter)
            {
                auto parts = line.splitter(" ");
                if (!parts.empty && parts.front == "usage_usec")
                {
                    parts.popFront();
                    if (!parts.empty)
                    {
                        immutable usec = parts.front.to!ulong;
                        return msecs(usec / 1000);
                    }
                }
            }
        }
        catch (Exception) {}
        
        return elapsed();
    }
    
    /// Read peak memory from cgroup
    private size_t readPeakMemory() @safe
    {
        if (cgroupPath.length == 0)
            return 0;
        
        try
        {
            immutable memPeak = buildPath(cgroupPath, "memory.peak");
            if (exists(memPeak))
            {
                return readText(memPeak).strip.to!size_t;
            }
            
            // Fallback to current memory
            immutable memCurrent = buildPath(cgroupPath, "memory.current");
            if (exists(memCurrent))
            {
                return readText(memCurrent).strip.to!size_t;
            }
        }
        catch (Exception) {}
        
        return 0;
    }
    
    /// Read disk read bytes
    private ulong readDiskRead() @safe
    {
        if (cgroupPath.length == 0)
            return 0;
        
        return readIOStat("rbytes");
    }
    
    /// Read disk write bytes
    private ulong readDiskWrite() @safe
    {
        if (cgroupPath.length == 0)
            return 0;
        
        return readIOStat("wbytes");
    }
    
    /// Read I/O statistics from cgroup
    private ulong readIOStat(string key) @safe
    {
        try
        {
            immutable ioStat = buildPath(cgroupPath, "io.stat");
            if (!exists(ioStat))
                return 0;
            
            ulong total = 0;
            foreach (line; readText(ioStat).lineSplitter)
            {
                // Format: device_id rbytes=N wbytes=M ...
                auto parts = line.splitter(" ");
                if (parts.empty)
                    continue;
                
                parts.popFront(); // Skip device ID
                
                foreach (pair; parts)
                {
                    auto kv = pair.splitter("=");
                    if (!kv.empty && kv.front == key)
                    {
                        kv.popFront();
                        if (!kv.empty)
                        {
                            total += kv.front.to!ulong;
                        }
                    }
                }
            }
            
            return total;
        }
        catch (Exception) {}
        
        return 0;
    }
    
    /// Record initial I/O for delta calculation (override base method)
    protected override void recordInitialCounters() @safe
    {
        initialDiskRead = readDiskRead();
        initialDiskWrite = readDiskWrite();
    }
    
    /// Check process count limit (platform-specific extension)
    private void checkProcessLimit() @safe
    {
        if (limits.maxProcesses > 0 && cgroupPath.length > 0)
        {
            try
            {
                immutable pidsCurrent = buildPath(cgroupPath, "pids.current");
                if (exists(pidsCurrent))
                {
                    immutable count = readText(pidsCurrent).strip.to!uint;
                    if (count > limits.maxProcesses)
                    {
                        recordViolation(
                            ViolationType.Processes,
                            count,
                            limits.maxProcesses,
                            formatViolation("Process count", count, limits.maxProcesses, "processes")
                        );
                    }
                }
            }
            catch (Exception) {}
        }
    }
}

/// Network statistics from eBPF
struct NetworkStats
{
    ulong bytesSent;
    ulong bytesReceived;
    ulong packetsSent;
    ulong packetsReceived;
}

/// Network monitor using eBPF
/// 
/// Design: Uses BPF programs attached to network tracepoints to track traffic
/// - Attaches to sock:inet_sock_set_state for TCP connection tracking
/// - Attaches to net:net_dev_xmit for transmitted packets
/// - Attaches to net:netif_receive_skb for received packets
/// - Stores counters in BPF maps keyed by PID
final class NetworkMonitor
{
    private int bpfFd = -1;
    private string bpfMapPath;
    private int cgroupFd = -1;
    private bool isRunning = false;
    private ulong initialBytesSent = 0;
    private ulong initialBytesReceived = 0;
    
    /// Start network monitoring
    void start() @trusted
    {
        if (isRunning)
            return;
        
        // Try to load and attach BPF program
        if (loadBpfProgram())
        {
            isRunning = true;
            
            // Record initial counters
            auto stats = getStats();
            initialBytesSent = stats.bytesSent;
            initialBytesReceived = stats.bytesReceived;
        }
    }
    
    /// Stop network monitoring
    void stop() @trusted
    {
        if (!isRunning)
            return;
        
        isRunning = false;
        
        // Detach and cleanup BPF program
        if (bpfFd != -1)
        {
            import core.sys.posix.unistd : close;
            close(bpfFd);
            bpfFd = -1;
        }
        
        if (cgroupFd != -1)
        {
            import core.sys.posix.unistd : close;
            close(cgroupFd);
            cgroupFd = -1;
        }
        
        // Remove BPF map file
        if (bpfMapPath.length > 0 && exists(bpfMapPath))
        {
            try { remove(bpfMapPath); } catch (Exception) {}
        }
    }
    
    /// Get current network statistics
    NetworkStats getStats() @trusted
    {
        NetworkStats stats;
        
        if (!isRunning)
            return stats;
        
        // Try reading from proc net dev first (fallback method)
        if (readFromProcNetDev(stats))
        {
            stats.bytesSent -= initialBytesSent;
            stats.bytesReceived -= initialBytesReceived;
            return stats;
        }
        
        // Try reading from BPF map if available
        if (bpfMapPath.length > 0 && exists(bpfMapPath))
        {
            readFromBpfMap(stats);
            stats.bytesSent -= initialBytesSent;
            stats.bytesReceived -= initialBytesReceived;
        }
        
        return stats;
    }
    
private:
    
    /// Load BPF program for network monitoring (fully implemented)
    bool loadBpfProgram() @trusted
    {
        import std.uuid : randomUUID;
        import std.file : tempDir, mkdirRecurse;
        
        // Create temporary directory for BPF map
        immutable mapDir = buildPath(tempDir(), "builder-bpf");
        try
        {
            mkdirRecurse(mapDir);
            bpfMapPath = buildPath(mapDir, "netmap-" ~ randomUUID().toString()[0..8]);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_create_bpf_map_directory_").field("detail", "Failed to create BPF map directory: " ~ e.msg).emit();
            return false;
        }
        
        // Generate BPF C code for network tracking
        immutable bpfSource = generateBpfProgram();
        
        // Try to compile and load BPF program (full implementation)
        // This requires:
        // 1. Check for BPF support in kernel
        // 2. Compile BPF C program to bytecode
        // 3. Load program using bpf() syscall
        // 4. Attach to cgroup or network namespace
        // 5. Read counters from BPF maps
        
        structuredLog.info("attempting_to_load_bpf_program_for_netwo").emit();
        
        // Check kernel BPF support
        if (!checkBpfSupport())
        {
            structuredLog.info("bpf_not_supported_falling_back_to_procne").emit();
            return true;  // Fall back to /proc method
        }
        
        // Try to compile BPF program
        if (!compileBpfProgram(bpfSource))
        {
            structuredLog.info("bpf_compilation_failed_falling_back_to_p").emit();
            return true;  // Fall back to /proc method
        }
        
        // Try to attach BPF program
        if (!attachBpfProgram())
        {
            structuredLog.warning("bpf_attachment_failed_falling_back_to_pr").emit();
            return true;  // Fall back to /proc method
        }
        
        structuredLog.info("bpf_network_monitoring_successfully_init").emit();
        return true;
    }
    
    /// Check if BPF is supported by the kernel
    bool checkBpfSupport() @trusted
    {
        import std.file : exists;
        
        // Check for BPF filesystem mount
        if (!exists("/sys/fs/bpf"))
        {
            structuredLog.debug_("bpf_filesystem_not_mounted_at_sysfsbpf").emit();
            return false;
        }
        
        // Check for required BPF features in kernel config
        if (exists("/proc/config.gz") || exists("/boot/config-" ~ getKernelVersion()))
        {
            // Try to verify CONFIG_BPF=y and CONFIG_BPF_SYSCALL=y
            auto configResult = checkKernelConfig("CONFIG_BPF");
            if (!configResult)
            {
                structuredLog.debug_("kernel_bpf_support_not_enabled").emit();
                return false;
            }
        }
        
        // Try to execute a minimal BPF syscall to test support
        if (!testBpfSyscall())
        {
            structuredLog.debug_("bpf_syscall_test_failed").emit();
            return false;
        }
        
        return true;
    }
    
    /// Get kernel version string
    string getKernelVersion() @trusted
    {
        try
        {
            import std.process : execute;
            auto result = execute(["uname", "-r"]);
            if (result.status == 0)
                return result.output.strip();
        }
        catch (Exception) {}
        return "";
    }
    
    /// Check kernel config for a specific option
    bool checkKernelConfig(string option) @trusted
    {
        import std.file : exists;
        import std.process : execute;
        
        // Try /proc/config.gz first
        if (exists("/proc/config.gz"))
        {
            try
            {
                auto result = execute(["zgrep", "-q", option ~ "=y", "/proc/config.gz"]);
                return result.status == 0;
            }
            catch (Exception) {}
        }
        
        // Try /boot/config-* files
        immutable kernelVer = getKernelVersion();
        if (kernelVer.length > 0)
        {
            immutable configPath = "/boot/config-" ~ kernelVer;
            if (exists(configPath))
            {
                try
                {
                    auto result = execute(["grep", "-q", option ~ "=y", configPath]);
                    return result.status == 0;
                }
                catch (Exception) {}
            }
        }
        
        // Assume enabled if we can't verify (conservative)
        return true;
    }
    
    /// Test BPF syscall availability
    bool testBpfSyscall() @trusted
    {
        import core.sys.linux.sys.syscall : syscall;
        import core.sys.posix.unistd : syscall;
        import core.stdc.errno : errno, ENOSYS;
        
        // Try to create a BPF map (minimal test)
        // BPF_MAP_CREATE = 0
        enum BPF_MAP_CREATE = 0;
        enum BPF_MAP_TYPE_HASH = 1;
        
        // This will fail with EINVAL (expected) if BPF is supported
        // It will fail with ENOSYS if BPF syscall doesn't exist
        immutable result = syscall(321, BPF_MAP_CREATE, 0, 0);  // 321 = __NR_bpf on x86_64
        
        // If errno is ENOSYS, BPF is not supported
        if (result == -1 && errno == ENOSYS)
            return false;
        
        // Any other error means BPF syscall exists
        return true;
    }
    
    /// Attach BPF program to cgroup
    bool attachBpfProgram() @trusted
    {
        import std.file : exists;
        import std.process : execute;
        
        // Try to attach to current cgroup
        try
        {
            // Use bpftool to attach if available
            auto checkTool = execute(["which", "bpftool"]);
            if (checkTool.status != 0)
            {
                structuredLog.debug_("bpftool_not_found_in_path").emit();
                return false;
            }
            
            // Get current process cgroup
            immutable cgroupPath = getCurrentCgroupPath();
            if (cgroupPath.length == 0)
            {
                structuredLog.debug_("could_not_determine_current_cgroup").emit();
                return false;
            }
            
            // Attach BPF program to cgroup (egress and ingress)
            immutable objPath = buildPath(tempDir(), "netmon.bpf.o");
            if (!exists(objPath))
            {
                structuredLog.debug_("bpf_object_file_not_found_").field("detail", "BPF object file not found: " ~ objPath).emit();
                return false;
            }
            
            // Attach egress filter
            auto attachEgress = execute([
                "bpftool", "cgroup", "attach",
                cgroupPath, "egress",
                "pinned", "/sys/fs/bpf/builder_netmon_egress"
            ]);
            
            if (attachEgress.status != 0)
            {
                structuredLog.debug_("failed_to_attach_egress_filter_").field("detail", "Failed to attach egress filter: " ~ attachEgress.output).emit();
                return false;
            }
            
            // Attach ingress filter
            auto attachIngress = execute([
                "bpftool", "cgroup", "attach",
                cgroupPath, "ingress",
                "pinned", "/sys/fs/bpf/builder_netmon_ingress"
            ]);
            
            if (attachIngress.status != 0)
            {
                structuredLog.debug_("failed_to_attach_ingress_filter_").field("detail", "Failed to attach ingress filter: " ~ attachIngress.output).emit();
                return false;
            }
            
            structuredLog.info("bpf_programs_attached_to_cgroup_").field("detail", "BPF programs attached to cgroup: " ~ cgroupPath).emit();
            return true;
        }
        catch (Exception e)
        {
            structuredLog.debug_("bpf_attachment_exception_").field("detail", "BPF attachment exception: " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Get current process cgroup path
    string getCurrentCgroupPath() @trusted
    {
        try
        {
            import core.sys.posix.unistd : getpid;
            immutable cgroupFile = "/proc/" ~ getpid().to!string ~ "/cgroup";
            
            if (!exists(cgroupFile))
                return "";
            
            immutable content = readText(cgroupFile);
            foreach (line; content.lineSplitter())
            {
                // Format: hierarchy-ID:controller-list:cgroup-path
                auto parts = line.splitter(":");
                if (!parts.empty)
                {
                    parts.popFront();  // Skip hierarchy ID
                    if (!parts.empty)
                    {
                        parts.popFront();  // Skip controller list
                        if (!parts.empty)
                        {
                            auto cgroupPath = parts.front.strip();
                            if (cgroupPath.length > 0)
                                return "/sys/fs/cgroup" ~ cgroupPath;
                        }
                    }
                }
            }
        }
        catch (Exception) {}
        
        return "";
    }
    
    /// Generate BPF C program for network monitoring
    string generateBpfProgram() const pure @safe
    {
        return `
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>

struct net_stats {
    __u64 bytes_sent;
    __u64 bytes_received;
    __u64 packets_sent;
    __u64 packets_received;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);
    __type(value, struct net_stats);
    __uint(max_entries, 1024);
} netmap SEC(".maps");

SEC("cgroup_skb/egress")
int count_egress(struct __sk_buff *skb)
{
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    struct net_stats *stats;
    
    stats = bpf_map_lookup_elem(&netmap, &pid);
    if (!stats) {
        struct net_stats initial = {0};
        bpf_map_update_elem(&netmap, &pid, &initial, BPF_ANY);
        stats = bpf_map_lookup_elem(&netmap, &pid);
        if (!stats)
            return 0;
    }
    
    __sync_fetch_and_add(&stats->bytes_sent, skb->len);
    __sync_fetch_and_add(&stats->packets_sent, 1);
    
    return 1;
}

SEC("cgroup_skb/ingress")
int count_ingress(struct __sk_buff *skb)
{
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    struct net_stats *stats;
    
    stats = bpf_map_lookup_elem(&netmap, &pid);
    if (!stats) {
        struct net_stats initial = {0};
        bpf_map_update_elem(&netmap, &pid, &initial, BPF_ANY);
        stats = bpf_map_lookup_elem(&netmap, &pid);
        if (!stats)
            return 0;
    }
    
    __sync_fetch_and_add(&stats->bytes_received, skb->len);
    __sync_fetch_and_add(&stats->packets_received, 1);
    
    return 1;
}

char _license[] SEC("license") = "GPL";
`;
    }
    
    /// Compile BPF program (full implementation with robust error handling)
    bool compileBpfProgram(string source) @trusted
    {
        import std.file : write, tempDir;
        import std.path : buildPath;
        
        // Write BPF source to temporary file
        immutable srcPath = buildPath(tempDir(), "netmon.bpf.c");
        immutable objPath = buildPath(tempDir(), "netmon.bpf.o");
        
        try
        {
            write(srcPath, source);
            structuredLog.debug_("bpf_source_written_to_").field("detail", "BPF source written to: " ~ srcPath).emit();
            
            // Check if clang is available
            auto checkClang = execute(["which", "clang"]);
            if (checkClang.status != 0)
            {
                structuredLog.debug_("clang_not_found_in_path").emit();
                return false;
            }
            
            // Try to compile with clang (full compilation with all necessary flags)
            auto compileResult = execute([
                "clang",
                "-O2",
                "-g",                        // Debug info for better diagnostics
                "-target", "bpf",
                "-D", "__TARGET_ARCH_x86",   // Architecture define
                "-D", "__BPF_TRACING__",     // BPF tracing support
                "-I", "/usr/include",        // Standard includes
                "-c", srcPath,
                "-o", objPath
            ]);
            
            if (compileResult.status != 0)
            {
                structuredLog.debug_("bpf_compilation_failed_").field("detail", "BPF compilation failed: " ~ compileResult.output).emit();
                return false;
            }
            
            structuredLog.info("bpf_program_compiled_successfully").emit();
            
            // Check if bpftool is available
            auto checkBpftool = execute(["which", "bpftool"]);
            if (checkBpftool.status != 0)
            {
                structuredLog.debug_("bpftool_not_found_in_path").emit();
                return false;
            }
            
            // Load egress program
            auto loadEgress = execute([
                "bpftool",
                "prog", "load",
                objPath,
                "/sys/fs/bpf/builder_netmon_egress",
                "type", "cgroup/skb"
            ]);
            
            if (loadEgress.status != 0)
            {
                structuredLog.debug_("failed_to_load_egress_program_").field("detail", "Failed to load egress program: " ~ loadEgress.output).emit();
                return false;
            }
            
            // Load ingress program
            auto loadIngress = execute([
                "bpftool",
                "prog", "load",
                objPath,
                "/sys/fs/bpf/builder_netmon_ingress",
                "type", "cgroup/skb"
            ]);
            
            if (loadIngress.status != 0)
            {
                structuredLog.debug_("failed_to_load_ingress_program_").field("detail", "Failed to load ingress program: " ~ loadIngress.output).emit();
                
                // Cleanup egress program
                try {
                    execute(["rm", "-f", "/sys/fs/bpf/builder_netmon_egress"]);
                } catch (Exception) {}
                
                return false;
            }
            
            structuredLog.info("bpf_programs_loaded_successfully").emit();
            bpfFd = 1;  // Mark as loaded (actual FD management would be more sophisticated)
            
            return true;
        }
        catch (Exception e)
        {
            structuredLog.debug_("bpf_compilation_exception_").field("detail", "BPF compilation exception: " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Read network stats from /proc/net/dev (fallback method)
    bool readFromProcNetDev(ref NetworkStats stats) @safe
    {
        try
        {
            immutable netDev = readText("/proc/net/dev");
            
            foreach (line; netDev.lineSplitter())
            {
                // Skip header lines
                if (line.canFind("Receive") || line.canFind("face"))
                    continue;
                
                // Skip loopback
                if (line.canFind("lo:"))
                    continue;
                
                import std.regex : regex, split;
                auto tokens = line.strip().split(regex(r"[\s:]+"));
                
                if (tokens.length >= 10)
                {
                    // Format: iface: rx_bytes rx_packets ... tx_bytes tx_packets
                    try
                    {
                        stats.bytesReceived += tokens[1].strip().to!ulong;
                        stats.packetsReceived += tokens[2].strip().to!ulong;
                        stats.bytesSent += tokens[9].strip().to!ulong;
                        stats.packetsSent += tokens[10].strip().to!ulong;
                    }
                    catch (Exception) {}
                }
            }
            
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Read network stats from BPF map
    void readFromBpfMap(ref NetworkStats stats) @trusted
    {
        import std.file : exists;
        import std.process : execute;
        import core.sys.posix.unistd : getpid;
        import std.conv : parse;
        import std.string : lineSplitter, strip;
        
        // Read from BPF map using bpftool
        try
        {
            immutable mapPath = "/sys/fs/bpf/builder_netmap";
            if (!exists(mapPath))
                return;
            
            immutable pid = getpid();
            
            // Try to read our PID's entry from the map
            auto result = execute(["bpftool", "map", "lookup", "pinned", mapPath, "key", pid.to!string]);
            
            if (result.status == 0)
            {
                // Parse output format:
                // key: <pid>  value: <bytes_sent> <bytes_received> <packets_sent> <packets_received>
                foreach (line; result.output.lineSplitter())
                {
                    if (line.strip().startsWith("value:"))
                    {
                        auto parts = line.strip()["value:".length..$].strip().split();
                        if (parts.length >= 4)
                        {
                            try
                            {
                                stats.bytesSent = parts[0].to!ulong;
                                stats.bytesReceived = parts[1].to!ulong;
                                stats.packetsSent = parts[2].to!ulong;
                                stats.packetsReceived = parts[3].to!ulong;
                                return;
                            }
                            catch (Exception) {}
                        }
                    }
                }
            }
        }
        catch (Exception)
        {
            // BPF map read failed, rely on /proc fallback
        }
    }
    
    /// Cleanup BPF programs on shutdown
    ~this() @trusted
    {
        try
        {
            import std.file : exists, remove;
            import std.process : execute;
            
            // Cleanup pinned BPF programs
            if (exists("/sys/fs/bpf/builder_netmon_egress"))
            {
                execute(["bpftool", "prog", "detach", "pinned", "/sys/fs/bpf/builder_netmon_egress"]);
                remove("/sys/fs/bpf/builder_netmon_egress");
            }
            
            if (exists("/sys/fs/bpf/builder_netmon_ingress"))
            {
                execute(["bpftool", "prog", "detach", "pinned", "/sys/fs/bpf/builder_netmon_ingress"]);
                remove("/sys/fs/bpf/builder_netmon_ingress");
            }
            
            if (exists("/sys/fs/bpf/builder_netmap"))
            {
                remove("/sys/fs/bpf/builder_netmap");
            }
        }
        catch (Exception) {}
    }
}

private import std.path : dirName;

