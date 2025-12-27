module engine.runtime.hermetic.tracing.linux;

version(linux):

import core.sys.posix.unistd : fork, execve, pipe, close, read, write, dup2, getpid;
import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS, WIFSTOPPED, WSTOPSIG;
import core.sys.posix.signal : kill, SIGSTOP, SIGKILL, SIGCONT;
import core.sys.linux.unistd : syscall;
import core.stdc.errno : errno, ESRCH;
import core.stdc.string : strerror;
import core.time : MonoTime;
import std.datetime : Duration, msecs;
import std.string : toStringz, fromStringz;
import std.conv : to;
import std.path : buildPath;
import std.file : exists;
import std.algorithm : canFind;

import engine.runtime.hermetic.tracing.tracer;
import infrastructure.errors;

/// ptrace request constants
private enum : int
{
    PTRACE_TRACEME     = 0,
    PTRACE_PEEKTEXT    = 1,
    PTRACE_PEEKDATA    = 2,
    PTRACE_PEEKUSER    = 3,
    PTRACE_POKETEXT    = 4,
    PTRACE_POKEDATA    = 5,
    PTRACE_POKEUSER    = 6,
    PTRACE_CONT        = 7,
    PTRACE_KILL        = 8,
    PTRACE_SINGLESTEP  = 9,
    PTRACE_GETREGS     = 12,
    PTRACE_SETREGS     = 13,
    PTRACE_ATTACH      = 16,
    PTRACE_DETACH      = 17,
    PTRACE_SYSCALL     = 24,
    PTRACE_SETOPTIONS  = 0x4200,
    PTRACE_GETEVENTMSG = 0x4201,
    PTRACE_GETSIGINFO  = 0x4202,
    PTRACE_GETREGSET   = 0x4204,
    PTRACE_SEIZE       = 0x4206,
    PTRACE_INTERRUPT   = 0x4207,
}

/// ptrace options
private enum : int
{
    PTRACE_O_TRACESYSGOOD   = 0x00000001,
    PTRACE_O_TRACEFORK      = 0x00000002,
    PTRACE_O_TRACEVFORK     = 0x00000004,
    PTRACE_O_TRACECLONE     = 0x00000008,
    PTRACE_O_TRACEEXEC      = 0x00000010,
    PTRACE_O_TRACEVFORKDONE = 0x00000020,
    PTRACE_O_TRACEEXIT      = 0x00000040,
    PTRACE_O_TRACESECCOMP   = 0x00000080,
}

/// ptrace events
private enum : int
{
    PTRACE_EVENT_FORK       = 1,
    PTRACE_EVENT_VFORK      = 2,
    PTRACE_EVENT_CLONE      = 3,
    PTRACE_EVENT_EXEC       = 4,
    PTRACE_EVENT_VFORK_DONE = 5,
    PTRACE_EVENT_EXIT       = 6,
    PTRACE_EVENT_SECCOMP    = 7,
}

/// x86_64 user registers structure
private struct UserRegs
{
    ulong r15, r14, r13, r12, rbp, rbx, r11, r10;
    ulong r9, r8, rax, rcx, rdx, rsi, rdi, orig_rax;
    ulong rip, cs, eflags, rsp, ss, fs_base, gs_base, ds, es, fs, gs;
}

/// x86_64 syscall numbers to names mapping
private immutable string[uint] syscallNames;

shared static this()
{
    syscallNames = [
        0: "read", 1: "write", 2: "open", 3: "close", 4: "stat",
        5: "fstat", 6: "lstat", 7: "poll", 8: "lseek", 9: "mmap",
        10: "mprotect", 11: "munmap", 12: "brk", 13: "rt_sigaction",
        14: "rt_sigprocmask", 21: "access", 22: "pipe", 32: "dup",
        33: "dup2", 39: "getpid", 41: "socket", 42: "connect",
        43: "accept", 44: "sendto", 45: "recvfrom", 46: "sendmsg",
        47: "recvmsg", 49: "bind", 50: "listen", 56: "clone",
        57: "fork", 58: "vfork", 59: "execve", 60: "exit",
        61: "wait4", 62: "kill", 72: "fcntl", 78: "getdents",
        79: "getcwd", 80: "chdir", 82: "rename", 83: "mkdir",
        84: "rmdir", 85: "creat", 86: "link", 87: "unlink",
        88: "symlink", 89: "readlink", 90: "chmod", 92: "chown",
        95: "umask", 96: "gettimeofday", 101: "ptrace", 105: "setuid",
        106: "setgid", 107: "geteuid", 108: "getegid", 110: "getppid",
        137: "statfs", 138: "fstatfs", 157: "prctl", 165: "mount",
        166: "umount2", 186: "gettid", 200: "tkill", 202: "futex",
        217: "getdents64", 231: "exit_group", 257: "openat",
        258: "mkdirat", 259: "mknodat", 260: "fchownat", 262: "newfstatat",
        263: "unlinkat", 264: "renameat", 265: "linkat", 266: "symlinkat",
        267: "readlinkat", 268: "fchmodat", 269: "faccessat",
        288: "accept4", 302: "prlimit64", 316: "renameat2",
        318: "getrandom", 332: "statx", 435: "clone3",
    ];
}

/// Get syscall name from number
private string getSyscallName(uint num) @safe pure nothrow
{
    if (auto name = num in syscallNames)
        return *name;
    return "syscall_" ~ num.to!string;
}

/// Linux syscall tracer using ptrace
final class LinuxSyscallTracer : ISyscallTracer
{
    private SyscallPolicy policy;
    private SyscallEvent[] events;
    private int[int] tracedPids;  // pid -> state (0=syscall-enter, 1=syscall-exit)
    private MonoTime traceStart;
    private bool active;
    
    private this(SyscallPolicy policy) @safe
    {
        this.policy = policy;
    }
    
    /// Create Linux syscall tracer
    static BuildResult!LinuxSyscallTracer create(SyscallPolicy policy) @system
    {
        if (!isLinuxTracingAvailable())
            return Err!(LinuxSyscallTracer, BuildError)(
                Errors.system("ptrace not available", Internal.NotSupported).build());
        
        return Ok!(LinuxSyscallTracer, BuildError)(new LinuxSyscallTracer(policy));
    }
    
    /// Execute command with syscall tracing
    BuildResult!TraceResult trace(string[] command, string workingDir) @system
    {
        if (command.length == 0)
            return Err!(TraceResult, BuildError)(
                Errors.system("Empty command", Config.InvalidInput).build());
        
        events = [];
        tracedPids.clear();
        traceStart = MonoTime.currTime;
        active = true;
        
        // Create pipes for stdout/stderr
        int[2] stdoutPipe, stderrPipe;
        if (pipe(stdoutPipe.ptr) != 0 || pipe(stderrPipe.ptr) != 0)
            return Err!(TraceResult, BuildError)(
                Errors.system("Failed to create pipes", System.ProcessSpawnFailed).build());
        
        immutable pid = fork();
        
        if (pid < 0)
        {
            closeAllPipes(stdoutPipe, stderrPipe);
            return Err!(TraceResult, BuildError)(
                Errors.system("Fork failed: " ~ errnoString(), System.ProcessSpawnFailed).build());
        }
        
        if (pid == 0)
        {
            // Child process
            childProcess(command, workingDir, stdoutPipe, stderrPipe);
            assert(false); // Never reached
        }
        
        // Parent process: trace syscalls
        close(stdoutPipe[1]);
        close(stderrPipe[1]);
        
        // Wait for child to stop (PTRACE_TRACEME + raise(SIGSTOP))
        int status;
        if (waitpid(pid, &status, 0) < 0)
        {
            kill(pid, SIGKILL);
            close(stdoutPipe[0]);
            close(stderrPipe[0]);
            return Err!(TraceResult, BuildError)(
                Errors.system("waitpid failed", System.ProcessCrashed).build());
        }
        
        // Set ptrace options
        if (ptrace(PTRACE_SETOPTIONS, pid, null, cast(void*)(
            PTRACE_O_TRACESYSGOOD |
            (policy.traceChildProcesses ? (PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE) : 0) |
            PTRACE_O_TRACEEXEC
        )) != 0)
        {
            kill(pid, SIGKILL);
            close(stdoutPipe[0]);
            close(stderrPipe[0]);
            return Err!(TraceResult, BuildError)(
                Errors.system("PTRACE_SETOPTIONS failed", System.ProcessSpawnFailed).build());
        }
        
        tracedPids[pid] = 0;
        
        // Continue child and trace syscalls
        ptrace(PTRACE_SYSCALL, pid, null, null);
        
        // Trace loop
        auto traceResult = traceLoop();
        
        active = false;
        immutable traceDuration = MonoTime.currTime - traceStart;
        
        // Read stdout/stderr
        string stdout = readPipe(stdoutPipe[0]);
        string stderr = readPipe(stderrPipe[0]);
        
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        
        TraceResult result;
        result.events = events;
        result.exitCode = traceResult.exitCode;
        result.stdout = stdout;
        result.stderr = stderr;
        result.traceDuration = traceDuration;
        result.traceSuccessful = traceResult.success;
        result.traceError = traceResult.error;
        
        return Ok!(TraceResult, BuildError)(result);
    }
    
    /// Get tracer capabilities
    TracerCapabilities capabilities() @safe const pure nothrow
    {
        TracerCapabilities caps;
        caps.canTraceFiles = true;
        caps.canTraceNetwork = true;
        caps.canTraceArgs = true;
        caps.canFollowForks = true;
        caps.requiresRoot = false;  // Unprivileged ptrace via TRACEME
        caps.platform = "linux";
        return caps;
    }
    
    /// Cleanup
    void cleanup() @system nothrow
    {
        // Kill any remaining traced processes
        foreach (pid, _; tracedPids)
        {
            try { kill(pid, SIGKILL); }
            catch (Exception) {}
        }
        tracedPids.clear();
        events = [];
        active = false;
    }
    
    private:
    
    /// Trace loop result
    struct TraceLoopResult
    {
        int exitCode;
        bool success;
        string error;
    }
    
    /// Main trace loop
    TraceLoopResult traceLoop() @system
    {
        TraceLoopResult result;
        result.success = true;
        
        while (tracedPids.length > 0)
        {
            int status;
            immutable pid = waitpid(-1, &status, __WALL);
            
            if (pid < 0)
            {
                if (errno == ESRCH || tracedPids.length == 0)
                    break;
                result.success = false;
                result.error = "waitpid error: " ~ errnoString();
                break;
            }
            
            if (WIFEXITED(status))
            {
                if (pid in tracedPids)
                {
                    result.exitCode = WEXITSTATUS(status);
                    tracedPids.remove(pid);
                }
                continue;
            }
            
            if (!WIFSTOPPED(status))
                continue;
            
            immutable sig = WSTOPSIG(status);
            
            // Check for syscall stop (SIGTRAP | 0x80)
            if (sig == (SIGTRAP | 0x80))
            {
                handleSyscallStop(pid);
                ptrace(PTRACE_SYSCALL, pid, null, null);
            }
            // Check for ptrace events
            else if (sig == SIGTRAP)
            {
                immutable event = (status >> 16) & 0xff;
                handlePtraceEvent(pid, event);
                ptrace(PTRACE_SYSCALL, pid, null, null);
            }
            else
            {
                // Deliver signal to tracee
                ptrace(PTRACE_SYSCALL, pid, null, cast(void*)sig);
            }
        }
        
        return result;
    }
    
    /// Handle syscall stop
    void handleSyscallStop(int pid) @system
    {
        if (pid !in tracedPids)
            return;
        
        UserRegs regs;
        if (ptrace(PTRACE_GETREGS, pid, null, &regs) != 0)
            return;
        
        immutable state = tracedPids[pid];
        
        if (state == 0)
        {
            // Syscall entry
            SyscallEvent event;
            event.timestamp = (MonoTime.currTime - traceStart).total!"nsecs";
            event.syscallNumber = cast(int)regs.orig_rax;
            event.syscallName = getSyscallName(cast(uint)regs.orig_rax);
            event.pid = pid;
            
            // Extract arguments based on syscall
            if (policy.traceSyscallArgs)
                event.args = extractArgs(pid, regs);
            
            // Filter based on policy
            if (shouldTrace(event))
                events ~= event;
            
            tracedPids[pid] = 1;  // Switch to exit state
        }
        else
        {
            // Syscall exit: update return value
            if (events.length > 0 && events[$ - 1].pid == pid)
                events[$ - 1].returnValue = cast(long)regs.rax;
            
            tracedPids[pid] = 0;  // Switch to entry state
        }
    }
    
    /// Handle ptrace events (fork, vfork, clone)
    void handlePtraceEvent(int pid, int event) @system
    {
        if (event == PTRACE_EVENT_FORK || event == PTRACE_EVENT_VFORK || 
            event == PTRACE_EVENT_CLONE)
        {
            // Get new child PID
            c_ulong newPid;
            if (ptrace(PTRACE_GETEVENTMSG, pid, null, &newPid) == 0)
            {
                tracedPids[cast(int)newPid] = 0;
                ptrace(PTRACE_SYSCALL, cast(int)newPid, null, null);
            }
        }
    }
    
    /// Extract syscall arguments
    string[] extractArgs(int pid, ref UserRegs regs) @system
    {
        string[] args;
        immutable syscall = getSyscallName(cast(uint)regs.orig_rax);
        
        // File path syscalls
        static immutable pathSyscalls = [
            "open", "openat", "stat", "lstat", "access", "faccessat",
            "readlink", "readlinkat", "unlink", "unlinkat", "rename",
            "mkdir", "mkdirat", "rmdir", "chmod", "chown", "execve"
        ];
        
        if (pathSyscalls.canFind(syscall))
        {
            // First arg is typically path (or second for *at variants)
            ulong pathAddr = syscall.canFind("at") && !syscall.canFind("stat") ? regs.rsi : regs.rdi;
            immutable path = readString(pid, pathAddr);
            if (path.length > 0)
                args ~= path;
        }
        
        // Socket syscalls - extract domain/type
        if (syscall == "socket")
            args ~= ["domain=" ~ regs.rdi.to!string, "type=" ~ regs.rsi.to!string];
        
        // Connect - would need to read sockaddr, simplified here
        if (syscall == "connect")
            args ~= "fd=" ~ regs.rdi.to!string;
        
        return args;
    }
    
    /// Read null-terminated string from tracee memory
    string readString(int pid, ulong addr) @system
    {
        if (addr == 0)
            return "";
        
        char[256] buffer;
        size_t i;
        
        while (i < buffer.length - 1)
        {
            immutable word = ptrace(PTRACE_PEEKDATA, pid, cast(void*)addr, null);
            if (word == -1 && errno != 0)
                break;
            
            auto bytes = cast(ubyte*)&word;
            foreach (j; 0 .. (void*).sizeof)
            {
                if (bytes[j] == 0 || i >= buffer.length - 1)
                {
                    buffer[i] = '\0';
                    return buffer[0 .. i].idup;
                }
                buffer[i++] = cast(char)bytes[j];
            }
            addr += (void*).sizeof;
        }
        
        buffer[i] = '\0';
        return buffer[0 .. i].idup;
    }
    
    /// Check if syscall should be traced based on policy
    bool shouldTrace(ref SyscallEvent event) @safe const pure nothrow
    {
        immutable name = event.syscallName;
        
        // File operations
        static immutable fileOps = ["open", "openat", "stat", "lstat", "fstat", "access",
            "faccessat", "readlink", "unlink", "rename", "mkdir", "rmdir", "chmod", "creat"];
        if (fileOps.canFind(name))
            return policy.traceFileOps;
        
        // Network operations
        static immutable netOps = ["socket", "connect", "bind", "listen", "accept",
            "sendto", "recvfrom", "sendmsg", "recvmsg"];
        if (netOps.canFind(name))
            return policy.traceNetworkOps;
        
        // Process operations
        static immutable procOps = ["fork", "vfork", "clone", "clone3", "execve", "exit", "exit_group"];
        if (procOps.canFind(name))
            return policy.traceProcessOps;
        
        // Memory operations
        static immutable memOps = ["mmap", "munmap", "mprotect", "brk"];
        if (memOps.canFind(name))
            return policy.traceMemoryOps;
        
        return true;  // Trace by default
    }
    
    /// Child process entry point
    static void childProcess(string[] command, string workDir, 
        int[2] stdoutPipe, int[2] stderrPipe) @system
    {
        // Close read ends
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        
        // Redirect stdout/stderr
        dup2(stdoutPipe[1], 1);
        dup2(stderrPipe[1], 2);
        close(stdoutPipe[1]);
        close(stderrPipe[1]);
        
        // Request to be traced
        ptrace(PTRACE_TRACEME, 0, null, null);
        
        // Stop ourselves for tracer to set options
        kill(getpid(), SIGSTOP);
        
        // Change directory if specified
        if (workDir.length > 0)
        {
            import core.sys.posix.unistd : chdir;
            chdir(toStringz(workDir));
        }
        
        // Prepare argv
        const(char)*[] argv = new const(char)*[command.length + 1];
        foreach (i, cmd; command)
            argv[i] = toStringz(cmd);
        argv[$ - 1] = null;
        
        // Prepare minimal environment
        const(char)*[] envp = [
            "PATH=/usr/bin:/bin".ptr,
            "HOME=/tmp".ptr,
            null
        ];
        
        execve(argv[0], argv.ptr, envp.ptr);
        
        // If exec fails, exit
        import core.stdc.stdlib : _exit;
        _exit(127);
    }
}

/// Read all data from pipe
private string readPipe(int fd) @system
{
    string result;
    char[4096] buffer;
    ssize_t n;
    
    while ((n = read(fd, buffer.ptr, buffer.length)) > 0)
        result ~= buffer[0 .. n].idup;
    
    return result;
}

/// Close all pipe file descriptors
private void closeAllPipes(int[2] p1, int[2] p2) @system nothrow
{
    close(p1[0]); close(p1[1]);
    close(p2[0]); close(p2[1]);
}

/// Get errno as string
private string errnoString() @trusted
{
    return cast(string)fromStringz(strerror(errno));
}

/// ptrace syscall wrapper
private extern(C) c_long ptrace(int request, int pid, void* addr, void* data) @system nothrow
{
    enum SYS_ptrace = 101;
    return syscall(SYS_ptrace, request, pid, addr, data);
}

/// Check if Linux tracing is available
bool isLinuxTracingAvailable() @system nothrow
{
    // Check if ptrace is available by trying TRACEME on ourselves
    // (Will fail gracefully if in a container without CAP_SYS_PTRACE)
    return true;  // ptrace TRACEME doesn't require special privileges
}

/// waitpid flags
private enum __WALL = 0x40000000;
private enum SIGTRAP = 5;

/// c_ulong for ptrace
private alias c_long = long;
private alias c_ulong = ulong;

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing Linux syscall tracer...");
    
    // Test syscall name lookup
    assert(getSyscallName(2) == "open");
    assert(getSyscallName(59) == "execve");
    assert(getSyscallName(41) == "socket");
    
    // Test capabilities
    auto tracerResult = LinuxSyscallTracer.create(SyscallPolicy.hermetic());
    if (tracerResult.isOk)
    {
        auto tracer = tracerResult.unwrap();
        auto caps = tracer.capabilities();
        
        assert(caps.canTraceFiles);
        assert(caps.canTraceNetwork);
        assert(caps.platform == "linux");
        
        tracer.cleanup();
    }
    
    writeln("✓ Linux syscall tracer tests passed");
}

