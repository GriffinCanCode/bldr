module engine.runtime.hermetic.sandbox.darwin;

version(OSX):

import std.process : execute, Config, spawnProcess, wait, ProcessPipes, pipeProcess, Redirect, Pid;
import std.file : exists, mkdirRecurse, write, remove, tempDir;
import std.path : buildPath;
import std.string : strip;
import std.conv : to;
import std.uuid : randomUUID;
import std.datetime : Duration, msecs;
import core.time : MonoTime;

import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.core.executor : Output;
import engine.runtime.hermetic.sandbox.contract;
import engine.runtime.hermetic.sandbox.profiles;
import infrastructure.errors;

/// macOS sandbox using sandbox-exec with SBPL profiles
/// 
/// Design: Kernel-enforced sandboxing via XNU sandbox framework
/// - SBPL profiles compiled to kernel sandbox rules
/// - Deny-by-default security model
/// - Filesystem, network, IPC, and Mach restrictions
final class DarwinSandbox : ISandbox
{
    private SandboxSpec _spec;
    private string profilePath;
    private bool initialized;
    private SandboxMetrics _metrics;
    
    private this(SandboxSpec spec, string profile) @safe
    {
        _spec = spec;
        profilePath = profile;
        initialized = true;
    }
    
    /// Factory constructor with profile generation
    static BuildResult!DarwinSandbox create(SandboxSpec spec) @system
    {
        auto validResult = spec.validate();
        if (validResult.isErr)
            return BuildResult!DarwinSandbox.err(sandboxError(
                SandboxErrorKind.Initialization, validResult.unwrapErr()));
        
        // Generate SBPL profile
        auto profile = SBPLGenerator.generate(spec);
        
        // Write profile to temp file
        immutable profileDir = buildPath(tempDir(), "builder-sandbox");
        if (!exists(profileDir))
        {
            try { mkdirRecurse(profileDir); }
            catch (Exception e)
            {
                return BuildResult!DarwinSandbox.err(sandboxError(
                    SandboxErrorKind.Initialization, "Cannot create profile dir: " ~ e.msg));
            }
        }
        
        immutable profilePath = buildPath(profileDir, randomUUID().toString() ~ ".sb");
        
        try
        {
            write(profilePath, profile);
        }
        catch (Exception e)
        {
            return BuildResult!DarwinSandbox.err(sandboxError(
                SandboxErrorKind.Initialization, "Cannot write profile: " ~ e.msg));
        }
        
        return BuildResult!DarwinSandbox.ok(new DarwinSandbox(spec, profilePath));
    }
    
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
        
        // Build sandbox-exec command
        string[] sandboxCmd = ["sandbox-exec", "-f", profilePath] ~ command;
        
        // Build environment from spec
        string[string] env;
        foreach (k, v; _spec.environment.vars)
            env[k] = v;
        
        // Spawn with pipes for output capture
        try
        {
            auto pipes = pipeProcess(
                sandboxCmd,
                Redirect.stdout | Redirect.stderr,
                env,
                Config.none,
                workDir.length > 0 ? workDir : null
            );
            
            // Handle timeout if specified
            bool timedOut = false;
            if (timeout > Duration.zero)
            {
                timedOut = waitWithTimeout(pipes.pid, timeout);
                if (timedOut)
                {
                    import core.sys.posix.signal : kill, SIGKILL;
                    kill(pipes.pid.processID, SIGKILL);
                }
            }
            
            // Wait for completion
            auto exitCode = wait(pipes.pid);
            
            immutable endTime = MonoTime.currTime;
            
            // Read all output
            string stdout, stderr;
            foreach (chunk; pipes.stdout.byChunk(4096))
                stdout ~= cast(string) chunk;
            foreach (chunk; pipes.stderr.byChunk(4096))
                stderr ~= cast(string) chunk;
            
            // Collect metrics
            _metrics.wallTime = cast(Duration)(endTime - startTime);
            _metrics.timeExceeded = timedOut;
            collectRusageMetrics(_metrics);
            
            // Build result using central Output type
            Output output;
            output.stdout = stdout;
            output.stderr = stderr;
            output.exitCode = timedOut ? -1 : exitCode;
            output.hermetic = true;
            
            return BuildResult!Output.ok(output);
        }
        catch (Exception e)
        {
            return BuildResult!Output.err(sandboxError(
                SandboxErrorKind.Initialization, "Execution failed: " ~ e.msg));
        }
    }
    
    const(SandboxSpec) spec() @safe const pure nothrow => _spec;
    IsolationLevel isolation() @safe const pure nothrow => IsolationLevel.Filesystem;
    SandboxMetrics metrics() @safe const => _metrics;
    
    void cleanup() @system nothrow
    {
        if (profilePath.length > 0 && exists(profilePath))
        {
            try { remove(profilePath); }
            catch (Exception) {}
        }
        initialized = false;
    }
    
    ~this() @system { cleanup(); }
}

/// Wait for process with timeout
private bool waitWithTimeout(Pid pid, Duration timeout) @system
{
    import core.thread : Thread;
    import core.time : msecs;
    import core.sys.posix.sys.wait : waitpid, WNOHANG;
    
    immutable deadline = MonoTime.currTime + timeout;
    
    while (MonoTime.currTime < deadline)
    {
        int status;
        auto result = waitpid(pid.processID, &status, WNOHANG);
        
        if (result != 0)
            return false; // Process finished
        
        Thread.sleep(10.msecs);
    }
    
    return true; // Timed out
}

/// Collect resource usage metrics via getrusage
private void collectRusageMetrics(ref SandboxMetrics metrics) @system nothrow
{
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_CHILDREN;
    
    rusage usage;
    if (getrusage(RUSAGE_CHILDREN, &usage) == 0)
    {
        metrics.userTime = msecs(usage.ru_utime.tv_sec * 1000 + usage.ru_utime.tv_usec / 1000);
        metrics.systemTime = msecs(usage.ru_stime.tv_sec * 1000 + usage.ru_stime.tv_usec / 1000);
        metrics.peakMemory = usage.ru_maxrss * 1024; // macOS reports in KB
        metrics.diskRead = usage.ru_inblock * 512;   // Block size
        metrics.diskWrite = usage.ru_oublock * 512;
    }
}

/// Check if sandbox-exec is available
bool isDarwinSandboxAvailable() @system nothrow
{
    try
    {
        auto result = execute(["which", "sandbox-exec"]);
        return result.status == 0;
    }
    catch (Exception)
    {
        return false;
    }
}

@system unittest
{
    if (isDarwinSandboxAvailable())
    {
        auto spec = SandboxSpecBuilder.create()
            .input("/usr")
            .temp("/tmp/test-sandbox")
            .build();
        
        if (spec.isOk)
        {
            auto sandboxResult = DarwinSandbox.create(spec.unwrap());
            assert(sandboxResult.isOk);
            
            auto sandbox = sandboxResult.unwrap();
            auto execResult = sandbox.execute(["/bin/echo", "hello"], "/tmp");
            
            assert(execResult.isOk);
            auto output = execResult.unwrap();
            assert(output.exitCode == 0);
            assert(output.stdout.strip == "hello");
            
            sandbox.cleanup();
        }
    }
}


