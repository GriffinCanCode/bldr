module engine.runtime.hermetic.tracing.tracer;

import std.datetime : Duration, msecs;
import std.path : buildPath, absolutePath;
import std.conv : to;
import std.array : array;
import std.algorithm : filter, map, canFind, sort, uniq;
import infrastructure.errors;

/// Syscall event captured during tracing
struct SyscallEvent
{
    ulong timestamp;      // Nanoseconds since trace start
    int syscallNumber;    // Platform-specific syscall number
    string syscallName;   // Human-readable name
    string[] args;        // Stringified arguments
    long returnValue;     // Syscall return value
    int pid;              // Process ID
    int tid;              // Thread ID
    
    /// File path if syscall operates on files
    string filePath() const @safe pure nothrow
    {
        static immutable fileOps = [
            "open", "openat", "creat", "stat", "lstat", "fstat",
            "access", "faccessat", "readlink", "readlinkat",
            "unlink", "unlinkat", "rename", "renameat",
            "mkdir", "mkdirat", "rmdir", "chmod", "fchmod",
            "chown", "fchown", "link", "linkat", "symlink",
            "truncate", "ftruncate", "execve", "execveat"
        ];
        
        if (fileOps.canFind(syscallName) && args.length > 0)
            return args[0];
        return "";
    }
    
    /// Check if syscall is a network operation
    bool isNetworkOp() const @safe pure nothrow
    {
        static immutable netOps = [
            "socket", "connect", "bind", "listen", "accept", "accept4",
            "sendto", "recvfrom", "sendmsg", "recvmsg", "send", "recv",
            "setsockopt", "getsockopt", "getpeername", "getsockname"
        ];
        return netOps.canFind(syscallName);
    }
    
    /// Check if syscall accesses external resources
    bool isExternalAccess() const @safe pure nothrow
    {
        immutable path = filePath();
        if (path.length == 0) return false;
        
        // Non-hermetic paths
        static immutable externalPaths = [
            "/etc/", "/var/", "/home/", "/Users/",
            "/tmp/", "/proc/", "/sys/", "/dev/"
        ];
        
        foreach (ext; externalPaths)
            if (path.length >= ext.length && path[0 .. ext.length] == ext)
                return true;
        
        return isNetworkOp();
    }
}

/// Syscall policy for tracing
struct SyscallPolicy
{
    bool traceFileOps = true;        // Trace file operations
    bool traceNetworkOps = true;     // Trace network operations
    bool traceProcessOps = true;     // Trace process operations (fork, exec, etc.)
    bool traceMemoryOps = false;     // Trace memory operations (mmap, brk)
    bool traceSyscallArgs = true;    // Capture syscall arguments
    bool traceChildProcesses = true; // Follow forks
    string[] allowedPaths;           // Paths allowed for file access
    string[] deniedPaths;            // Paths explicitly denied
    Duration traceTimeout;           // Maximum trace duration
    
    /// Create hermetic policy (strict)
    static SyscallPolicy hermetic() @safe pure nothrow
    {
        SyscallPolicy p;
        p.traceTimeout = Duration.zero; // No timeout by default
        p.allowedPaths = ["/usr/", "/lib/", "/lib64/", "/bin/", "/sbin/"];
        p.deniedPaths = ["/home/", "/Users/", "/tmp/", "/var/"];
        return p;
    }
    
    /// Create permissive policy (logging only)
    static SyscallPolicy permissive() @safe pure nothrow
    {
        SyscallPolicy p;
        p.traceTimeout = Duration.zero;
        return p;
    }
    
    /// Add allowed path
    ref SyscallPolicy allow(string path) return @safe pure nothrow
    {
        allowedPaths ~= path;
        return this;
    }
    
    /// Add denied path
    ref SyscallPolicy deny(string path) return @safe pure nothrow
    {
        deniedPaths ~= path;
        return this;
    }
}

/// Result of syscall tracing
struct TraceResult
{
    SyscallEvent[] events;           // All captured syscall events
    int exitCode;                    // Process exit code
    string stdout;                   // Captured stdout
    string stderr;                   // Captured stderr
    Duration traceDuration;          // Total trace duration
    bool traceSuccessful;            // Whether tracing completed without errors
    string traceError;               // Error message if tracing failed
    
    /// Get unique files accessed
    string[] filesAccessed() const @safe
    {
        return events
            .map!(e => e.filePath())
            .filter!(p => p.length > 0)
            .array
            .sort
            .uniq
            .array;
    }
    
    /// Get network connections attempted (lazy range)
    auto networkAttempts() const @safe
    {
        return events.filter!(e => e.isNetworkOp());
    }
    
    /// Get external resource accesses (lazy range)
    auto externalAccesses() const @safe
    {
        return events.filter!(e => e.isExternalAccess());
    }
    
    /// Count syscalls by name
    size_t[string] syscallCounts() const @safe
    {
        size_t[string] counts;
        foreach (e; events)
        {
            if (e.syscallName in counts)
                counts[e.syscallName]++;
            else
                counts[e.syscallName] = 1;
        }
        return counts;
    }
}

/// Cross-platform syscall tracer interface
interface ISyscallTracer
{
    /// Execute command with syscall tracing
    BuildResult!TraceResult trace(string[] command, string workingDir) @system;
    
    /// Get tracer capabilities
    TracerCapabilities capabilities() @safe const pure nothrow;
    
    /// Cleanup resources
    void cleanup() @system nothrow;
}

/// Tracer capabilities
struct TracerCapabilities
{
    bool canTraceFiles;        // Can trace file operations
    bool canTraceNetwork;      // Can trace network operations
    bool canTraceArgs;         // Can capture syscall arguments
    bool canFollowForks;       // Can trace child processes
    bool requiresRoot;         // Requires root/admin privileges
    string platform;           // Platform identifier
}

/// Platform-independent syscall tracer factory
struct SyscallTracer
{
    private ISyscallTracer tracer;
    private SyscallPolicy policy;
    private bool initialized;
    
    /// Create tracer for current platform
    static BuildResult!SyscallTracer create(SyscallPolicy policy = SyscallPolicy.hermetic()) @system
    {
        SyscallTracer st;
        st.policy = policy;
        
        version(linux)
        {
            import engine.runtime.hermetic.tracing.linux : LinuxSyscallTracer;
            auto result = LinuxSyscallTracer.create(policy);
            if (result.isErr)
                return Err!(SyscallTracer, BuildError)(result.unwrapErr());
            st.tracer = result.unwrap();
        }
        else version(OSX)
        {
            import engine.runtime.hermetic.tracing.darwin : DarwinSyscallTracer;
            auto result = DarwinSyscallTracer.create(policy);
            if (result.isErr)
                return Err!(SyscallTracer, BuildError)(result.unwrapErr());
            st.tracer = result.unwrap();
        }
        else
        {
            return Err!(SyscallTracer, BuildError)(
                Errors.system("Syscall tracing not supported on this platform", 
                    ErrorCode.NotSupported).build());
        }
        
        st.initialized = true;
        return Ok!(SyscallTracer, BuildError)(st);
    }
    
    /// Execute command with syscall tracing
    BuildResult!TraceResult trace(string[] command, string workingDir = "") @system
    {
        if (!initialized || tracer is null)
            return Err!(TraceResult, BuildError)(
                Errors.system("Tracer not initialized", ErrorCode.NotInitialized).build());
        
        return tracer.trace(command, workingDir);
    }
    
    /// Get tracer capabilities
    TracerCapabilities capabilities() @safe const pure nothrow
    {
        if (tracer is null)
        {
            TracerCapabilities caps;
            caps.platform = "none";
            return caps;
        }
        return tracer.capabilities();
    }
    
    /// Get configured policy
    const(SyscallPolicy) getPolicy() @safe const pure nothrow => policy;
    
    /// Cleanup resources
    void cleanup() @system nothrow
    {
        if (tracer !is null)
            tracer.cleanup();
        initialized = false;
    }
}

/// Check if syscall tracing is available
bool isSyscallTracingAvailable() @system nothrow
{
    version(linux)
    {
        import engine.runtime.hermetic.tracing.linux : isLinuxTracingAvailable;
        return isLinuxTracingAvailable();
    }
    else version(OSX)
    {
        import engine.runtime.hermetic.tracing.darwin : isDarwinTracingAvailable;
        return isDarwinTracingAvailable();
    }
    else
        return false;
}

@safe unittest
{
    // Test policy creation
    auto hermetic = SyscallPolicy.hermetic();
    assert(hermetic.traceFileOps);
    assert(hermetic.traceNetworkOps);
    assert(hermetic.allowedPaths.length > 0);
    
    auto permissive = SyscallPolicy.permissive();
    assert(permissive.deniedPaths.length == 0);
    
    // Test event file path extraction
    SyscallEvent event;
    event.syscallName = "open";
    event.args = ["/etc/passwd"];
    assert(event.filePath() == "/etc/passwd");
    assert(event.isExternalAccess());
    
    // Test network detection
    SyscallEvent netEvent;
    netEvent.syscallName = "connect";
    assert(netEvent.isNetworkOp());
}

