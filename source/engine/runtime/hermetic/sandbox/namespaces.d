module engine.runtime.hermetic.sandbox.namespaces;

version(linux):

import core.sys.linux.sched;
import core.sys.posix.unistd : fork, execve, pipe, close, read, write, dup2, getuid, getgid, chdir;
import core.sys.posix.fcntl;
import core.sys.posix.sys.wait;
import core.stdc.errno : errno;
import core.stdc.string : strerror;
import std.string : toStringz, fromStringz;
import std.conv : to, octal;
import std.file : exists, mkdirRecurse, readText, write, rmdirRecurse;
import std.path : buildPath, dirName;
import std.uuid : randomUUID;
import std.datetime : Duration, msecs;
import core.time : MonoTime;

import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.core.executor : Output;
import engine.runtime.hermetic.sandbox.contract;
import engine.runtime.hermetic.sandbox.cgroups;
import engine.runtime.hermetic.security.seccomp;  // Use existing seccomp
import infrastructure.errors;

/// Linux namespace sandbox using clone() with full isolation
/// 
/// Implements: CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS
/// Uses pivot_root (not chroot) for proper root filesystem isolation
final class NamespaceSandbox : ISandbox
{
    private SandboxSpec _spec;
    private string rootDir;
    private string cgroupPath;
    private CgroupController cgroup;
    private bool initialized;
    
    private this(SandboxSpec spec, string root, CgroupController cg) @safe
    {
        _spec = spec;
        rootDir = root;
        cgroup = cg;
        initialized = true;
    }
    
    /// Factory constructor with validation
    static BuildResult!NamespaceSandbox create(SandboxSpec spec, string workDir) @system
    {
        auto validResult = spec.validate();
        if (validResult.isErr)
            return BuildResult!NamespaceSandbox.err(sandboxError(
                SandboxErrorKind.Initialization, validResult.unwrapErr()));
        
        // Create isolated root directory
        immutable root = buildPath(workDir, ".sandbox", randomUUID().toString());
        try
        {
            mkdirRecurse(root);
        }
        catch (Exception e)
        {
            return BuildResult!NamespaceSandbox.err(sandboxError(
                SandboxErrorKind.Initialization, "Cannot create sandbox root: " ~ e.msg));
        }
        
        // Setup cgroup for resource limits
        auto cgResult = CgroupController.create(spec.resources);
        if (cgResult.isErr)
            return BuildResult!NamespaceSandbox.err(cgResult.unwrapErr());
        
        return BuildResult!NamespaceSandbox.ok(
            new NamespaceSandbox(spec, root, cgResult.unwrap()));
    }
    
    private SandboxMetrics _metrics;
    
    BuildResult!Output execute(string[] command, string workDir) @system
    {
        return executeWithTimeout(command, Duration.zero, workDir);
    }
    
    BuildResult!Output executeWithTimeout(string[] command, Duration timeout, string workDir) @system
    {
        if (!initialized)
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Initialization, "Sandbox not initialized"));
        
        if (command.length == 0)
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Initialization, "Empty command"));
        
        immutable startTime = MonoTime.currTime;
        
        // Create communication pipes
        int[2] stdoutPipe, stderrPipe, syncPipe;
        if (pipe(stdoutPipe.ptr) != 0 || pipe(stderrPipe.ptr) != 0 || pipe(syncPipe.ptr) != 0)
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Initialization, "Pipe creation failed"));
        
        // Clone with all namespace flags
        enum int CLONE_FLAGS = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | 
                               CLONE_NEWNET | CLONE_NEWIPC | CLONE_NEWUTS | SIGCHLD;
        
        // Stack for clone (required for CLONE_VM)
        enum STACK_SIZE = 1024 * 1024;
        auto stack = new ubyte[STACK_SIZE];
        
        // Prepare child args
        auto args = new ChildContext();
        args.command = command;
        args.workDir = workDir.length > 0 ? workDir : rootDir;
        args.spec = &_spec;
        args.rootDir = rootDir;
        args.stdoutFd = stdoutPipe[1];
        args.stderrFd = stderrPipe[1];
        args.syncReadFd = syncPipe[0];
        
        // Clone child process
        immutable pid = clone(&childMain, stack.ptr + STACK_SIZE, CLONE_FLAGS, args);
        
        if (pid < 0)
        {
            closePipes(stdoutPipe, stderrPipe, syncPipe);
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Initialization, 
                "clone() failed: " ~ fromStringz(strerror(errno)).idup));
        }
        
        // Parent: setup user namespace mappings
        close(stdoutPipe[1]);
        close(stderrPipe[1]);
        close(syncPipe[0]);
        
        if (!setupUidGidMapping(pid))
        {
            close(syncPipe[1]);
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Permission, "UID/GID mapping failed"));
        }
        
        // Add child to cgroup before signaling
        if (cgroup !is null)
            cgroup.addProcess(pid);
        
        // Signal child to continue after mapping setup
        write(syncPipe[1], "G".ptr, 1);
        close(syncPipe[1]);
        
        // Read output with optional timeout
        string stdout, stderr;
        immutable hasTimeout = timeout > Duration.zero;
        immutable deadline = hasTimeout ? startTime + timeout : MonoTime.init;
        
        stdout = readPipeWithTimeout(stdoutPipe[0], deadline);
        stderr = readPipeWithTimeout(stderrPipe[0], deadline);
        
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        
        // Wait for child
        int status;
        waitpid(pid, &status, 0);
        
        immutable endTime = MonoTime.currTime;
        
        // Collect metrics
        _metrics.wallTime = cast(Duration)(endTime - startTime);
        if (cgroup !is null)
        {
            auto cgMetrics = cgroup.metrics();
            _metrics.userTime = cgMetrics.userTime;
            _metrics.systemTime = cgMetrics.systemTime;
            _metrics.peakMemory = cgMetrics.peakMemory;
            _metrics.memoryExceeded = cgMetrics.oomKilled;
        }
        _metrics.timeExceeded = hasTimeout && endTime > deadline;
        
        // Build output using central Output type
        Output output;
        output.stdout = stdout;
        output.stderr = stderr;
        output.exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        output.hermetic = true;
        
        return BuildResult!Output.ok(output);
    }
    
    const(SandboxSpec) spec() @safe const pure nothrow => _spec;
    IsolationLevel isolation() @safe const pure nothrow => IsolationLevel.Full;
    SandboxMetrics metrics() @safe const => _metrics;
    
    void cleanup() @system nothrow
    {
        if (cgroup !is null)
        {
            try { cgroup.cleanup(); } catch (Exception) {}
        }
        if (rootDir.length > 0 && exists(rootDir))
        {
            try { rmdirRecurse(rootDir); } catch (Exception) {}
        }
        initialized = false;
    }
    
    ~this() @system { cleanup(); }
}

/// Child process context passed through clone
private final class ChildContext
{
    string[] command;
    string workDir;
    const(SandboxSpec)* spec;
    string rootDir;
    int stdoutFd, stderrFd, syncReadFd;
}

/// Child process entry point (runs in new namespaces)
private extern(C) int childMain(void* arg) @system nothrow
{
    auto ctx = cast(ChildContext) arg;
    
    try
    {
        // Wait for parent to setup UID/GID mapping
        char[1] buf;
        .read(ctx.syncReadFd, buf.ptr, 1);
        close(ctx.syncReadFd);
        
        // Redirect stdio
        dup2(ctx.stdoutFd, 1);
        dup2(ctx.stderrFd, 2);
        close(ctx.stdoutFd);
        close(ctx.stderrFd);
        
        // Setup root filesystem with pivot_root
        if (!setupRootfs(ctx.spec, ctx.rootDir))
            return 1;
        
        // Change to working directory
        if (chdir(toStringz(ctx.workDir)) != 0)
            return 1;
        
        // Drop capabilities and install seccomp filter
        if (installSeccompFilter(SeccompPolicy.strict()) != 0)
            return 1;
        
        // Build environment
        auto envVars = buildEnvp(ctx.spec);
        
        // Prepare argv
        auto argv = new const(char)*[ctx.command.length + 1];
        foreach (i, cmd; ctx.command)
            argv[i] = toStringz(cmd);
        argv[$ - 1] = null;
        
        // Execute
        execve(argv[0], argv.ptr, envVars.ptr);
        return 127; // exec failed
    }
    catch (Exception)
    {
        return 1;
    }
}

/// Setup root filesystem using pivot_root for proper isolation
private bool setupRootfs(const(SandboxSpec)* spec, string root) @system nothrow
{
    import core.sys.posix.sys.mount;
    
    try
    {
        // Make current mounts private to prevent propagation
        if (mount(null, "/".ptr, null, MS_PRIVATE | MS_REC, null) != 0)
            return false;
        
        // Mount tmpfs as new root
        if (mount("tmpfs".ptr, toStringz(root), "tmpfs".ptr, 
                  MS_NOSUID | MS_NODEV, "size=1G,mode=755".ptr) != 0)
            return false;
        
        // Create directory structure
        immutable dirs = ["proc", "dev", "sys", "tmp", "workspace"];
        foreach (d; dirs)
        {
            auto path = buildPath(root, d);
            if (!exists(path))
                mkdirRecurse(path);
        }
        
        // Bind mount input paths (read-only)
        foreach (inPath; spec.inputs.paths)
            bindMountReadOnly(inPath, root);
        
        // Bind mount output paths (read-write)
        foreach (outPath; spec.outputs.paths)
            bindMountReadWrite(outPath, root);
        
        // Bind mount temp paths (read-write)
        foreach (tmpPath; spec.temps.paths)
            bindMountReadWrite(tmpPath, root);
        
        // Mount special filesystems
        immutable proc = buildPath(root, "proc");
        immutable dev = buildPath(root, "dev");
        immutable sys = buildPath(root, "sys");
        
        mount("proc".ptr, toStringz(proc), "proc".ptr, MS_NOSUID | MS_NODEV | MS_NOEXEC, null);
        mount("tmpfs".ptr, toStringz(dev), "tmpfs".ptr, MS_NOSUID | MS_NODEV, "size=10m,mode=755".ptr);
        mount("sysfs".ptr, toStringz(sys), "sysfs".ptr, MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, null);
        
        // Create essential device nodes (in dev tmpfs)
        createDeviceNodes(dev);
        
        // Pivot root (requires put_old inside new root)
        immutable oldRoot = buildPath(root, ".old");
        if (!exists(oldRoot))
            mkdirRecurse(oldRoot);
        
        if (pivotRoot(toStringz(root), toStringz(oldRoot)) != 0)
        {
            // Fallback to chroot if pivot_root fails
            import core.sys.posix.unistd : chroot;
            if (chroot(toStringz(root)) != 0)
                return false;
        }
        else
        {
            // Unmount old root
            import core.sys.posix.unistd : chdir;
            chdir("/".ptr);
            umount2("/.old".ptr, MNT_DETACH);
            rmdirRecurse("/.old");
        }
        
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

/// Setup UID/GID mapping for user namespace
private bool setupUidGidMapping(int pid) @system nothrow
{
    try
    {
        immutable uid = getuid();
        immutable gid = getgid();
        
        // Deny setgroups first (required before GID mapping)
        .write(buildPath("/proc", pid.to!string, "setgroups"), "deny\n");
        
        // Map current user to root inside namespace
        immutable uidMap = "0 " ~ uid.to!string ~ " 1\n";
        immutable gidMap = "0 " ~ gid.to!string ~ " 1\n";
        
        .write(buildPath("/proc", pid.to!string, "uid_map"), uidMap);
        .write(buildPath("/proc", pid.to!string, "gid_map"), gidMap);
        
        return true;
    }
    catch (Exception)
    {
        return false;
    }
}

/// Bind mount path read-only
private void bindMountReadOnly(string src, string rootDir) @system
{
    import core.sys.posix.sys.mount;
    
    if (!exists(src))
        return;
    
    auto dst = buildPath(rootDir, src[1 .. $]); // Remove leading /
    auto parent = dirName(dst);
    
    if (!exists(parent))
        mkdirRecurse(parent);
    if (!exists(dst))
        mkdirRecurse(dst);
    
    if (mount(toStringz(src), toStringz(dst), null, MS_BIND | MS_REC, null) == 0)
        mount(null, toStringz(dst), null, MS_REMOUNT | MS_BIND | MS_RDONLY | MS_REC, null);
}

/// Bind mount path read-write
private void bindMountReadWrite(string src, string rootDir) @system
{
    import core.sys.posix.sys.mount;
    
    if (!exists(src))
        mkdirRecurse(src);
    
    auto dst = buildPath(rootDir, src[1 .. $]);
    auto parent = dirName(dst);
    
    if (!exists(parent))
        mkdirRecurse(parent);
    if (!exists(dst))
        mkdirRecurse(dst);
    
    mount(toStringz(src), toStringz(dst), null, MS_BIND | MS_REC, null);
}

/// Create minimal device nodes
private void createDeviceNodes(string devPath) @system
{
    import core.sys.posix.sys.stat : mknod, S_IFCHR;
    
    // null, zero, random, urandom (major, minor pairs)
    immutable devices = [
        tuple("null", 1, 3),
        tuple("zero", 1, 5),
        tuple("random", 1, 8),
        tuple("urandom", 1, 9),
    ];
    
    foreach (dev; devices)
    {
        auto path = buildPath(devPath, dev[0]);
        mknod(toStringz(path), S_IFCHR | octal!666, makedev(dev[1], dev[2]));
    }
}

/// Build environment variables array
private const(char)*[] buildEnvp(const(SandboxSpec)* spec) @system
{
    auto envp = new const(char)*[spec.environment.vars.length + 1];
    size_t i = 0;
    foreach (k, v; spec.environment.vars)
        envp[i++] = toStringz(k ~ "=" ~ v);
    envp[$ - 1] = null;
    return envp;
}

/// Read from pipe with timeout
private string readPipeWithTimeout(int fd, MonoTime deadline) @system nothrow
{
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    
    string result;
    char[4096] buf;
    immutable hasDeadline = deadline != MonoTime.init;
    
    while (true)
    {
        // Calculate remaining timeout
        int timeoutMs = -1;
        if (hasDeadline)
        {
            immutable remaining = deadline - MonoTime.currTime;
            if (remaining <= Duration.zero)
                break;
            timeoutMs = cast(int) remaining.total!"msecs";
        }
        
        // Poll for data
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        
        int pollRet = poll(&pfd, 1, timeoutMs);
        if (pollRet <= 0)
            break;
        
        // Read available data
        ssize_t n = .read(fd, buf.ptr, buf.length);
        if (n <= 0)
            break;
        
        result ~= buf[0 .. n].idup;
    }
    
    return result;
}

/// Close all pipe file descriptors
private void closePipes(int[2] p1, int[2] p2, int[2] p3) @system nothrow
{
    foreach (p; [p1, p2, p3])
        foreach (fd; p)
            close(fd);
}

// System call wrappers
private extern(C) int pivotRoot(const(char)* newRoot, const(char)* putOld) @system nothrow
{
    import core.sys.posix.unistd : syscall;
    enum SYS_pivot_root = 155; // x86_64
    return cast(int) syscall(SYS_pivot_root, newRoot, putOld);
}

private uint makedev(int major, int minor) @safe pure nothrow @nogc
{
    return cast(uint)((major << 8) | minor);
}

// Required mount flags
private enum : uint
{
    MS_RDONLY = 1,
    MS_NOSUID = 2,
    MS_NODEV = 4,
    MS_NOEXEC = 8,
    MS_REMOUNT = 32,
    MS_BIND = 4096,
    MS_REC = 16384,
    MS_PRIVATE = 1 << 18,
    MNT_DETACH = 2,
}

private extern(C) int umount2(const(char)* target, int flags) @system nothrow;

private import std.typecons : tuple;


