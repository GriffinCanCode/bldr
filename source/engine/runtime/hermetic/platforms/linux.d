module engine.runtime.hermetic.platforms.linux;

version(linux):

import core.sys.linux.sched;
import core.sys.linux.unistd;
import core.sys.posix.sys.wait;
import core.sys.posix.unistd : fork, execve, pipe, close, read, write, dup2;
import core.sys.posix.fcntl;
import core.sys.posix.sys.mount;
import std.string : toStringz, fromStringz;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, writeText;
import std.path : buildPath;
import std.algorithm : map;
import std.array : array;
import core.stdc.errno : errno, ENOENT;
import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.security.seccomp;
import infrastructure.errors;

/// Linux namespace-based sandbox implementation
/// Uses clone() with namespace flags for isolation
/// 
/// Design: Leverages Linux kernel namespaces for hermetic execution:
/// - CLONE_NEWNS: Mount namespace for filesystem isolation
/// - CLONE_NEWPID: PID namespace for process isolation
/// - CLONE_NEWNET: Network namespace for network isolation
/// - CLONE_NEWIPC: IPC namespace for IPC isolation
/// - CLONE_NEWUTS: UTS namespace for hostname isolation
/// - CLONE_NEWUSER: User namespace for privilege isolation
/// 
/// This provides strong isolation without requiring root privileges
struct LinuxSandbox
{
    private SandboxSpec spec;
    private string rootDir;
    private string cgroupPath;
    
    /// Create sandbox from spec
    static Result!LinuxSandbox create(SandboxSpec spec, string workDir) @system
    {
        LinuxSandbox sandbox;
        sandbox.spec = spec;
        sandbox.rootDir = workDir;
        
        // Create cgroup for resource limits
        auto cgroupResult = sandbox.setupCgroup();
        if (cgroupResult.isErr)
            return Result!LinuxSandbox.err(cgroupResult.unwrapErr());
        
        return Result!LinuxSandbox.ok(sandbox);
    }
    
    /// Execute command in sandbox
    Result!ExecutionOutput execute(string[] command, string workingDir) @system
    {
        // Create pipes for stdout/stderr
        int[2] stdoutPipe;
        int[2] stderrPipe;
        
        if (pipe(stdoutPipe.ptr) != 0 || pipe(stderrPipe.ptr) != 0)
            return Result!ExecutionOutput.err("Failed to create pipes");
        
        // Clone with namespace flags
        immutable cloneFlags = 
            CLONE_NEWNS |    // Mount namespace
            CLONE_NEWPID |   // PID namespace
            CLONE_NEWNET |   // Network namespace (hermetic)
            CLONE_NEWIPC |   // IPC namespace
            CLONE_NEWUTS |   // UTS namespace
            CLONE_NEWUSER;   // User namespace
        
        // Allocate stack for child (1MB)
        enum STACK_SIZE = 1024 * 1024;
        ubyte[] stack = new ubyte[STACK_SIZE];
        void* stackTop = stack.ptr + STACK_SIZE;
        
        // Prepare args for child
        ChildArgs args;
        args.command = command;
        args.workingDir = workingDir;
        args.spec = &spec;
        args.rootDir = rootDir;
        args.stdoutFd = stdoutPipe[1];
        args.stderrFd = stderrPipe[1];
        
        // Clone child process with namespaces
        immutable pid = clone(&childEntrypoint, stackTop, cloneFlags | SIGCHLD, &args);
        
        if (pid < 0)
        {
            close(stdoutPipe[0]);
            close(stdoutPipe[1]);
            close(stderrPipe[0]);
            close(stderrPipe[1]);
            return Result!ExecutionOutput.err("Failed to clone process: errno " ~ errno.to!string);
        }
        
        // Parent: close write ends, read output
        close(stdoutPipe[1]);
        close(stderrPipe[1]);
        
        // Setup user namespace mapping
        auto uidMapResult = setupUserNamespace(pid);
        if (uidMapResult.isErr)
            return Result!ExecutionOutput.err(uidMapResult.unwrapErr());
        
        // Read stdout/stderr
        string stdout;
        string stderr;
        
        char[4096] buffer;
        ssize_t n;
        
        // Read stdout
        while ((n = .read(stdoutPipe[0], buffer.ptr, buffer.length)) > 0)
            stdout ~= buffer[0 .. n].idup;
        
        // Read stderr
        while ((n = .read(stderrPipe[0], buffer.ptr, buffer.length)) > 0)
            stderr ~= buffer[0 .. n].idup;
        
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        
        // Wait for child
        int status;
        if (waitpid(pid, &status, 0) < 0)
            return Result!ExecutionOutput.err("Failed to wait for child");
        
        ExecutionOutput output;
        output.stdout = stdout;
        output.stderr = stderr;
        output.exitCode = WEXITSTATUS(status);
        
        // Cleanup cgroup
        cleanupCgroup();
        
        return Result!ExecutionOutput.ok(output);
    }
    
    /// Setup cgroup for resource limits
    private Result!void setupCgroup() @system
    {
        import std.random : uniform;
        import std.uuid : randomUUID;
        
        // Use cgroup v2 if available, fallback to v1
        immutable cgroupRoot = exists("/sys/fs/cgroup/cgroup.controllers") ? 
            "/sys/fs/cgroup" : "/sys/fs/cgroup/cpu,cpuacct";
        
        if (!exists(cgroupRoot))
            return Result!void.err("Cgroups not available");
        
        // Create unique cgroup
        cgroupPath = buildPath(cgroupRoot, "builder", randomUUID().toString());
        
        try
        {
            mkdirRecurse(cgroupPath);
        }
        catch (Exception e)
        {
            return Result!void.err("Failed to create cgroup: " ~ e.msg);
        }
        
        // Apply resource limits
        if (spec.resources.maxMemoryBytes > 0)
        {
            auto memLimit = buildPath(cgroupPath, "memory.max");
            if (exists(dirName(memLimit)))
            {
                try
                {
                    writeText(memLimit, spec.resources.maxMemoryBytes.to!string);
                }
                catch (Exception) {}
            }
        }
        
        if (spec.resources.cpuShares > 0)
        {
            auto cpuWeight = buildPath(cgroupPath, "cpu.weight");
            if (exists(dirName(cpuWeight)))
            {
                try
                {
                    writeText(cpuWeight, spec.resources.cpuShares.to!string);
                }
                catch (Exception) {}
            }
        }
        
        return Result!void.ok();
    }
    
    /// Cleanup cgroup
    private void cleanupCgroup() @system
    {
        import std.file : rmdirRecurse;
        
        if (!cgroupPath.empty && exists(cgroupPath))
        {
            try
            {
                rmdirRecurse(cgroupPath);
            }
            catch (Exception) {}
        }
    }
    
    /// Setup user namespace UID/GID mapping
    private static Result!void setupUserNamespace(pid_t pid) @system
    {
        import core.sys.posix.unistd : getuid, getgid;
        
        immutable uid = getuid();
        immutable gid = getgid();
        
        // Write UID map: inside uid 0 -> outside current uid
        immutable uidMapPath = buildPath("/proc", pid.to!string, "uid_map");
        immutable uidMap = "0 " ~ uid.to!string ~ " 1\n";
        
        try
        {
            writeText(uidMapPath, uidMap);
        }
        catch (Exception e)
        {
            return Result!void.err("Failed to setup UID mapping: " ~ e.msg);
        }
        
        // Deny setgroups
        immutable setgroupsPath = buildPath("/proc", pid.to!string, "setgroups");
        try
        {
            writeText(setgroupsPath, "deny\n");
        }
        catch (Exception) {}
        
        // Write GID map
        immutable gidMapPath = buildPath("/proc", pid.to!string, "gid_map");
        immutable gidMap = "0 " ~ gid.to!string ~ " 1\n";
        
        try
        {
            writeText(gidMapPath, gidMap);
        }
        catch (Exception e)
        {
            return Result!void.err("Failed to setup GID mapping: " ~ e.msg);
        }
        
        return Result!void.ok();
    }
}

/// Arguments passed to child process
private struct ChildArgs
{
    string[] command;
    string workingDir;
    const(SandboxSpec)* spec;
    string rootDir;
    int stdoutFd;
    int stderrFd;
}

/// Child process entrypoint (runs in new namespaces)
private extern(C) int childEntrypoint(void* arg) @system nothrow
{
    auto args = cast(ChildArgs*)arg;
    
    try
    {
        // Redirect stdout/stderr
        dup2(args.stdoutFd, 1);
        dup2(args.stderrFd, 2);
        close(args.stdoutFd);
        close(args.stderrFd);
        
        // Setup mount namespace
        auto mountResult = setupMounts(args.spec, args.rootDir);
        if (mountResult.isErr)
        {
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "Mount setup failed\n".ptr);
            return 1;
        }
        
        // Change to working directory
        import core.sys.posix.unistd : chdir;
        if (chdir(toStringz(args.workingDir)) != 0)
        {
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "chdir failed\n".ptr);
            return 1;
        }
        
        // Build environment
        auto env = buildEnvironment(args.spec);
        
        // Install seccomp-bpf filter (must be done before exec)
        // This blocks dangerous syscalls like ptrace, mount, personality, etc.
        if (installSeccompFilter(SeccompPolicy.strict()) != 0)
        {
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "seccomp filter installation failed\n".ptr);
            return 1;
        }
        
        // Prepare argv and envp
        const(char)*[] argv = new const(char)*[args.command.length + 1];
        foreach (i, cmd; args.command)
            argv[i] = toStringz(cmd);
        argv[$ - 1] = null;
        
        const(char)*[] envp = new const(char)*[env.length + 1];
        foreach (i, e; env)
            envp[i] = toStringz(e);
        envp[$ - 1] = null;
        
        // Execute command
        execve(argv[0], argv.ptr, envp.ptr);
        
        // If we get here, exec failed
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "execve failed\n".ptr);
        return 127;
    }
    catch (Exception e)
    {
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "Exception in child\n".ptr);
        return 1;
    }
}

/// Setup mount namespace with filesystem isolation
private Result!void setupMounts(const(SandboxSpec)* spec, string rootDir) @system
{
    import core.sys.posix.sys.mount : mount, umount2, MS_BIND, MS_RDONLY, MS_NOSUID, MS_NODEV, MS_NOEXEC;
    
    // Make / private to prevent mount propagation
    if (mount(null, "/".ptr, null, MS_PRIVATE | MS_REC, null) != 0)
        return Result!void.err("Failed to make / private");
    
    // Create minimal tmpfs root
    immutable newRoot = buildPath(rootDir, "root");
    try
    {
        if (!exists(newRoot))
            mkdirRecurse(newRoot);
    }
    catch (Exception e)
    {
        return Result!void.err("Failed to create new root: " ~ e.msg);
    }
    
    // Mount tmpfs as new root
    if (mount("tmpfs".ptr, toStringz(newRoot), "tmpfs".ptr, 0, "size=100m".ptr) != 0)
        return Result!void.err("Failed to mount tmpfs root");
    
    // Bind mount input paths (read-only)
    foreach (inPath; spec.inputs.paths)
    {
        auto mountPoint = buildPath(newRoot, inPath[1 .. $]); // Remove leading /
        
        try
        {
            if (!exists(dirName(mountPoint)))
                mkdirRecurse(dirName(mountPoint));
        }
        catch (Exception) {}
        
        // Bind mount
        if (mount(toStringz(inPath), toStringz(mountPoint), null, MS_BIND, null) == 0)
        {
            // Remount read-only
            mount(null, toStringz(mountPoint), null, MS_REMOUNT | MS_BIND | MS_RDONLY, null);
        }
    }
    
    // Bind mount output paths (read-write)
    foreach (outPath; spec.outputs.paths)
    {
        auto mountPoint = buildPath(newRoot, outPath[1 .. $]);
        
        try
        {
            if (!exists(dirName(mountPoint)))
                mkdirRecurse(dirName(mountPoint));
        }
        catch (Exception) {}
        
        mount(toStringz(outPath), toStringz(mountPoint), null, MS_BIND, null);
    }
    
    // Bind mount temp paths (read-write)
    foreach (tempPath; spec.temps.paths)
    {
        auto mountPoint = buildPath(newRoot, tempPath[1 .. $]);
        
        try
        {
            if (!exists(dirName(mountPoint)))
                mkdirRecurse(dirName(mountPoint));
        }
        catch (Exception) {}
        
        mount(toStringz(tempPath), toStringz(mountPoint), null, MS_BIND, null);
    }
    
    // Mount essential directories (proc, dev, sys)
    immutable proc = buildPath(newRoot, "proc");
    immutable dev = buildPath(newRoot, "dev");
    immutable sys = buildPath(newRoot, "sys");
    
    try
    {
        if (!exists(proc)) mkdirRecurse(proc);
        if (!exists(dev)) mkdirRecurse(dev);
        if (!exists(sys)) mkdirRecurse(sys);
    }
    catch (Exception) {}
    
    mount("proc".ptr, toStringz(proc), "proc".ptr, MS_NOSUID | MS_NODEV | MS_NOEXEC, null);
    mount("tmpfs".ptr, toStringz(dev), "tmpfs".ptr, MS_NOSUID, "size=10m,mode=755".ptr);
    mount("sysfs".ptr, toStringz(sys), "sysfs".ptr, MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_RDONLY, null);
    
    // Pivot root
    import core.sys.posix.unistd : chroot;
    if (chroot(toStringz(newRoot)) != 0)
        return Result!void.err("Failed to chroot");
    
    // Change to root directory
    import core.sys.posix.unistd : chdir;
    chdir("/".ptr);
    
    return Result!void.ok();
}

/// Build environment from spec
private string[] buildEnvironment(const(SandboxSpec)* spec) @safe
{
    string[] env;
    
    foreach (key, value; spec.environment.vars)
        env ~= key ~ "=" ~ value;
    
    return env;
}

/// Execution output
struct ExecutionOutput
{
    string stdout;
    string stderr;
    int exitCode;
}

/// Result type
private struct Result(T)
{
    private bool _isOk;
    private T _value;
    private string _error;
    
    static Result ok(T val) @safe
    {
        Result r;
        r._isOk = true;
        r._value = val;
        return r;
    }
    
    static Result ok() @safe
    {
        Result r;
        r._isOk = true;
        return r;
    }
    
    static Result err(string error) @safe
    {
        Result r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    bool isOk() @safe const pure nothrow { return _isOk; }
    bool isErr() @safe const pure nothrow { return !_isOk; }
    
    T unwrap() @safe
    {
        if (!_isOk)
            assert(false, "Result unwrap failed: " ~ _error);
        return _value;
    }
    
    string unwrapErr() @safe const
    {
        if (_isOk)
            assert(false, "Result is ok, not an error");
        return _error;
    }
}

// Additional imports needed
import core.sys.posix.sys.mount : MS_PRIVATE, MS_REC;
import std.path : dirName;

private enum MS_BIND = 4096;
private enum MS_REMOUNT = 32;
private enum MS_RDONLY = 1;
private enum MS_NOSUID = 2;
private enum MS_NODEV = 4;
private enum MS_NOEXEC = 8;

