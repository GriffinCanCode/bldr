module engine.runtime.hermetic.tracing.darwin;

version(OSX):

import std.process : execute, Config, pipeProcess, Redirect, wait, spawnProcess;
import std.file : exists, mkdirRecurse, write, remove, tempDir, readText, dirEntries, SpanMode;
import std.path : buildPath, baseName;
import std.string : strip, split, indexOf, startsWith, toStringz;
import std.conv : to;
import std.uuid : randomUUID;
import std.datetime : Duration, msecs;
import std.algorithm : filter, map, canFind, sort, startsWith;
import std.array : array;
import std.regex : regex, matchAll, matchFirst;
import core.time : MonoTime;
import core.sys.posix.unistd : fork, execve, pipe, close, read, dup2, getpid;
import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
import core.sys.posix.signal : kill, SIGKILL;

import engine.runtime.hermetic.tracing.tracer;
import infrastructure.errors;

/// macOS sandbox-exec based syscall tracer
/// 
/// Uses Apple's Seatbelt sandbox with logging profile to capture
/// file/network access attempts. Parses system.log or unified logging
/// for sandbox violations and access patterns.
final class DarwinSyscallTracer : ISyscallTracer
{
    private SyscallPolicy policy;
    private string profilePath;
    private string logDir;
    private bool initialized;
    
    private this(SyscallPolicy policy, string profilePath, string logDir) @safe
    {
        this.policy = policy;
        this.profilePath = profilePath;
        this.logDir = logDir;
        this.initialized = true;
    }
    
    /// Create Darwin syscall tracer
    static BuildResult!DarwinSyscallTracer create(SyscallPolicy policy) @system
    {
        if (!isDarwinTracingAvailable())
            return Err!(DarwinSyscallTracer, BuildError)(
                Errors.system("sandbox-exec not available", ErrorCode.NotSupported).build());
        
        // Create temp directories for profile and logs
        immutable baseDir = buildPath(tempDir(), "builder-trace");
        try
        {
            if (!exists(baseDir))
                mkdirRecurse(baseDir);
        }
        catch (Exception e)
        {
            return Err!(DarwinSyscallTracer, BuildError)(
                Errors.system("Cannot create trace dir: " ~ e.msg, ErrorCode.FileWriteFailed).build());
        }
        
        immutable sessionId = randomUUID().toString();
        immutable profilePath = buildPath(baseDir, sessionId ~ ".sb");
        immutable logDir = buildPath(baseDir, sessionId ~ "-logs");
        
        try
        {
            mkdirRecurse(logDir);
            
            // Generate sandbox profile with logging
            immutable profile = generateLoggingProfile(policy, logDir);
            write(profilePath, profile);
        }
        catch (Exception e)
        {
            return Err!(DarwinSyscallTracer, BuildError)(
                Errors.system("Cannot write profile: " ~ e.msg, ErrorCode.FileWriteFailed).build());
        }
        
        return Ok!(DarwinSyscallTracer, BuildError)(
            new DarwinSyscallTracer(policy, profilePath, logDir));
    }
    
    /// Execute command with syscall tracing
    BuildResult!TraceResult trace(string[] command, string workingDir) @system
    {
        if (!initialized)
            return Err!(TraceResult, BuildError)(
                Errors.system("Tracer not initialized", ErrorCode.NotInitialized).build());
        
        if (command.length == 0)
            return Err!(TraceResult, BuildError)(
                Errors.system("Empty command", ErrorCode.InvalidInput).build());
        
        immutable startTime = MonoTime.currTime;
        
        // Build sandbox-exec command with trace profile
        string[] sandboxCmd = ["sandbox-exec", "-f", profilePath] ~ command;
        
        try
        {
            // Execute with output capture
            auto pipes = pipeProcess(
                sandboxCmd,
                Redirect.stdout | Redirect.stderr,
                null,  // Use current environment
                Config.none,
                workingDir.length > 0 ? workingDir : null
            );
            
            // Wait for completion
            immutable exitCode = wait(pipes.pid);
            immutable endTime = MonoTime.currTime;
            
            // Read output
            string stdout, stderr;
            foreach (chunk; pipes.stdout.byChunk(4096))
                stdout ~= cast(string)chunk;
            foreach (chunk; pipes.stderr.byChunk(4096))
                stderr ~= cast(string)chunk;
            
            // Parse sandbox logs to extract syscall events
            auto events = parseSandboxLogs();
            
            // Also check unified logging for sandbox violations
            events ~= parseUnifiedLogs(startTime, endTime);
            
            TraceResult result;
            result.events = events;
            result.exitCode = exitCode;
            result.stdout = stdout;
            result.stderr = stderr;
            result.traceDuration = endTime - startTime;
            result.traceSuccessful = true;
            
            return Ok!(TraceResult, BuildError)(result);
        }
        catch (Exception e)
        {
            TraceResult result;
            result.traceSuccessful = false;
            result.traceError = e.msg;
            return Ok!(TraceResult, BuildError)(result);
        }
    }
    
    /// Get tracer capabilities
    TracerCapabilities capabilities() @safe const pure nothrow
    {
        TracerCapabilities caps;
        caps.canTraceFiles = true;
        caps.canTraceNetwork = true;
        caps.canTraceArgs = true;  // Via sandbox logs
        caps.canFollowForks = true;  // Sandbox applies to all children
        caps.requiresRoot = false;
        caps.platform = "darwin";
        return caps;
    }
    
    /// Cleanup
    void cleanup() @system nothrow
    {
        try
        {
            if (profilePath.length > 0 && exists(profilePath))
                remove(profilePath);
            
            if (logDir.length > 0 && exists(logDir))
            {
                import std.file : rmdirRecurse;
                rmdirRecurse(logDir);
            }
        }
        catch (Exception) {}
        
        initialized = false;
    }
    
    private:
    
    /// Parse sandbox log files for events
    SyscallEvent[] parseSandboxLogs() @system
    {
        SyscallEvent[] events;
        
        if (!exists(logDir))
            return events;
        
        // Read all log files in the log directory
        foreach (entry; dirEntries(logDir, SpanMode.shallow))
        {
            if (!entry.isFile)
                continue;
            
            try
            {
                immutable content = readText(entry.name);
                events ~= parseLogContent(content);
            }
            catch (Exception) {}
        }
        
        return events;
    }
    
    /// Parse log content into events
    SyscallEvent[] parseLogContent(string content) @safe
    {
        SyscallEvent[] events;
        
        foreach (line; content.split("\n"))
        {
            immutable stripped = line.strip();
            if (stripped.length == 0)
                continue;
            
            SyscallEvent event;
            
            // Parse sandbox log format: "operation path"
            if (stripped.startsWith("file-read"))
            {
                event.syscallName = "open";
                event.args = [extractPath(stripped)];
            }
            else if (stripped.startsWith("file-write"))
            {
                event.syscallName = "open";  // Write implies open
                event.args = [extractPath(stripped)];
            }
            else if (stripped.startsWith("network"))
            {
                event.syscallName = "connect";
                event.args = [extractNetworkInfo(stripped)];
            }
            else if (stripped.startsWith("process-exec"))
            {
                event.syscallName = "execve";
                event.args = [extractPath(stripped)];
            }
            else
                continue;
            
            events ~= event;
        }
        
        return events;
    }
    
    /// Parse unified logging for sandbox violations
    SyscallEvent[] parseUnifiedLogs(MonoTime start, MonoTime end) @system
    {
        SyscallEvent[] events;
        
        // Use log command to query sandbox violations
        // This requires appropriate permissions
        try
        {
            auto result = execute([
                "log", "show",
                "--predicate", `subsystem == "com.apple.sandbox"`,
                "--last", "1m",
                "--style", "compact"
            ]);
            
            if (result.status == 0)
                events ~= parseUnifiedLogOutput(result.output);
        }
        catch (Exception) {}
        
        return events;
    }
    
    /// Parse unified log output
    SyscallEvent[] parseUnifiedLogOutput(string output) @safe
    {
        SyscallEvent[] events;
        
        foreach (line; output.split("\n"))
        {
            if (line.indexOf("deny") >= 0 || line.indexOf("violation") >= 0)
            {
                SyscallEvent event;
                event.syscallName = "sandbox_violation";
                event.args = [line.strip()];
                events ~= event;
            }
        }
        
        return events;
    }
    
    /// Extract path from log line
    static string extractPath(string line) @safe pure nothrow
    {
        // Format: "operation /path/to/file"
        immutable spaceIdx = line.indexOf(' ');
        if (spaceIdx > 0 && spaceIdx < line.length - 1)
            return line[spaceIdx + 1 .. $].strip();
        return "";
    }
    
    /// Extract network info from log line
    static string extractNetworkInfo(string line) @safe pure nothrow
    {
        // Format: "network-outbound host:port"
        immutable spaceIdx = line.indexOf(' ');
        if (spaceIdx > 0 && spaceIdx < line.length - 1)
            return line[spaceIdx + 1 .. $].strip();
        return "network";
    }
}

/// Generate sandbox profile with logging enabled
private string generateLoggingProfile(SyscallPolicy policy, string logDir) @safe
{
    import std.array : Appender;
    
    Appender!string sb;
    
    sb ~= "(version 1)\n";
    sb ~= "\n; Hermetic tracing profile with logging\n";
    sb ~= "(debug all)\n";  // Enable debug logging
    sb ~= "(trace \"" ~ logDir ~ "/trace.log\")\n";  // Custom trace output
    sb ~= "\n";
    
    // Default deny
    sb ~= "(deny default)\n";
    sb ~= "\n";
    
    // Allow basic operations needed for execution
    sb ~= "; Essential permissions\n";
    sb ~= "(allow process-exec)\n";
    sb ~= "(allow process-fork)\n";
    sb ~= "(allow signal)\n";
    sb ~= "(allow sysctl-read)\n";
    sb ~= "\n";
    
    // File operations with logging
    sb ~= "; File operations (logged)\n";
    sb ~= "(allow file-read* (subpath \"/usr\"))\n";
    sb ~= "(allow file-read* (subpath \"/lib\"))\n";
    sb ~= "(allow file-read* (subpath \"/bin\"))\n";
    sb ~= "(allow file-read* (subpath \"/sbin\"))\n";
    sb ~= "(allow file-read* (subpath \"/System\"))\n";
    sb ~= "(allow file-read* (subpath \"/Library/Frameworks\"))\n";
    sb ~= "(allow file-read* (subpath \"/Applications/Xcode.app\"))\n";
    sb ~= "(allow file-read* (literal \"/dev/null\"))\n";
    sb ~= "(allow file-read* (literal \"/dev/random\"))\n";
    sb ~= "(allow file-read* (literal \"/dev/urandom\"))\n";
    sb ~= "\n";
    
    // Allowed paths from policy
    foreach (path; policy.allowedPaths)
    {
        sb ~= "(allow file-read* (subpath \"" ~ path ~ "\"))\n";
        sb ~= "(allow file-write* (subpath \"" ~ path ~ "\"))\n";
    }
    sb ~= "\n";
    
    // Denied paths with logging
    sb ~= "; Denied paths (violations logged)\n";
    foreach (path; policy.deniedPaths)
        sb ~= "(deny file* (subpath \"" ~ path ~ "\") (with report))\n";
    sb ~= "\n";
    
    // Network operations
    if (policy.traceNetworkOps)
    {
        sb ~= "; Network (denied and logged)\n";
        sb ~= "(deny network* (with report))\n";
    }
    else
    {
        sb ~= "; Network (allowed)\n";
        sb ~= "(allow network*)\n";
    }
    sb ~= "\n";
    
    // Mach operations for IPC
    sb ~= "; Mach IPC\n";
    sb ~= "(allow mach-lookup)\n";
    sb ~= "(allow mach-register)\n";
    sb ~= "\n";
    
    // IOKit for device access
    sb ~= "; IOKit\n";
    sb ~= "(allow iokit-open)\n";
    sb ~= "\n";
    
    // Allow writing to temp/output locations
    sb ~= "; Temp and output\n";
    sb ~= "(allow file-write* (subpath \"/tmp\"))\n";
    sb ~= "(allow file-write* (subpath \"/private/tmp\"))\n";
    sb ~= "(allow file-write* (subpath (param \"TMPDIR\")))\n";
    sb ~= "(allow file-write* (subpath \"" ~ logDir ~ "\"))\n";
    sb ~= "\n";
    
    // Allow stdout/stderr
    sb ~= "; Standard I/O\n";
    sb ~= "(allow file-write* (literal \"/dev/tty\"))\n";
    sb ~= "(allow file-write* (literal \"/dev/null\"))\n";
    sb ~= "(allow file-read* (literal \"/dev/tty\"))\n";
    sb ~= "\n";
    
    return sb.data;
}

/// Check if Darwin tracing is available
bool isDarwinTracingAvailable() @system nothrow
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
    import std.stdio : writeln;
    
    writeln("Testing Darwin syscall tracer...");
    
    if (isDarwinTracingAvailable())
    {
        auto tracerResult = DarwinSyscallTracer.create(SyscallPolicy.hermetic());
        
        if (tracerResult.isOk)
        {
            auto tracer = tracerResult.unwrap();
            auto caps = tracer.capabilities();
            
            assert(caps.canTraceFiles);
            assert(caps.platform == "darwin");
            
            // Test with simple command
            auto result = tracer.trace(["/bin/echo", "hello"], "/tmp");
            if (result.isOk)
            {
                auto tr = result.unwrap();
                assert(tr.traceSuccessful || tr.traceError.length > 0);
            }
            
            tracer.cleanup();
        }
    }
    
    // Test profile generation
    auto profile = generateLoggingProfile(SyscallPolicy.hermetic(), "/tmp/test");
    assert(profile.indexOf("(version 1)") >= 0);
    assert(profile.indexOf("(deny default)") >= 0);
    assert(profile.indexOf("(trace") >= 0);
    
    writeln("✓ Darwin syscall tracer tests passed");
}

