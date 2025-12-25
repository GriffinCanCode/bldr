module engine.runtime.hermetic.core.executor;

import std.process : execute, Config;
import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath, absolutePath;
import std.datetime : Duration;
import std.conv : to;
import std.range : empty;
import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.security.audit;
import infrastructure.errors;

// Platform-specific imports
version(linux)
{
    import engine.runtime.hermetic.platforms.linux;
}
version(OSX)
{
    import engine.runtime.hermetic.platforms.macos;
}
version(Windows)
{
    import engine.runtime.hermetic.platforms.windows;
}

/// Unified hermetic execution interface
/// Provides platform-agnostic API for sandboxed execution
/// 
/// Design: Factory pattern with platform-specific backends
/// - Linux: namespace-based isolation
/// - macOS: sandbox-exec with SBPL
/// - Windows: (future) job objects
/// - Fallback: basic process execution with validation
struct HermeticExecutor
{
    private SandboxSpec spec;
    private string workDir;
    private bool initialized;
    private HermeticAuditLogger* auditLogger;
    
    /// Create hermetic executor from spec
    static BuildResult!HermeticExecutor create(SandboxSpec spec, string workDir = "", HermeticAuditLogger* logger = null) @system
    {
        // Validate spec
        auto validateResult = spec.validate();
        if (validateResult.isErr)
            return BuildResult!HermeticExecutor.err(
                Errors.system(validateResult.unwrapErr(), ErrorCode.InvalidConfiguration).build());
        
        HermeticExecutor executor;
        executor.spec = spec;
        executor.auditLogger = logger;
        
        // Setup work directory
        if (workDir.empty)
        {
            import std.random : uniform;
            import std.uuid : randomUUID;
            executor.workDir = buildPath(tempDir(), "builder-hermetic", randomUUID().toString());
        }
        else
        {
            executor.workDir = absolutePath(workDir);
        }
        
        // Ensure work directory exists
        try
        {
            if (!exists(executor.workDir))
                mkdirRecurse(executor.workDir);
        }
        catch (Exception e)
        {
            return BuildResult!HermeticExecutor.err(
                ioError(executor.workDir, "Failed to create work directory: " ~ e.msg));
        }
        
        executor.initialized = true;
        return BuildResult!HermeticExecutor.ok(executor);
    }
    
    /// Execute command hermetically
    BuildResult!Output execute(string[] command, string workingDir = "") @system
    {
        if (!initialized)
            return BuildResult!Output.err(
                Errors.system("Executor not initialized", ErrorCode.NotInitialized).build());
        
        if (command.length == 0)
            return BuildResult!Output.err(
                Errors.system("Empty command", ErrorCode.InvalidInput).build());
        
        // Use working dir or current dir
        immutable execDir = workingDir.empty ? workDir : workingDir;
        
        // Ensure working directory is in allowed paths
        if (!spec.canRead(execDir) && !spec.canWrite(execDir))
        {
            // Log security violation via audit logger
            if (auditLogger !is null)
            {
                auditLogger.logFilesystemAccess(
                    execDir,
                    "access",
                    command[0],
                    false  // Not allowed
                );
            }
            
            return BuildResult!Output.err(
                Errors.system("Working directory not in allowed paths: " ~ execDir, ErrorCode.PermissionDenied).build());
        }
        
        // Log execution start
        if (auditLogger !is null)
        {
            auditLogger.logProcessCreation(
                command[0],
                command[1..$],
                command[0],
                true  // Allowed (passed security check)
            );
        }
        
        // Select platform-specific backend
        version(linux)
        {
            return executeLinux(command, execDir);
        }
        else version(OSX)
        {
            return executeMacOS(command, execDir);
        }
        else version(Windows)
        {
            return executeWindows(command, execDir);
        }
        else
        {
            return executeFallback(command, execDir);
        }
    }
    
    /// Execute with timeout
    BuildResult!Output executeWithTimeout(string[] command, Duration timeout, string workingDir = "") @system
    {
        import engine.runtime.hermetic.security.timeout : createTimeoutEnforcer;
        
        if (!initialized)
            return BuildResult!Output.err(
                Errors.system("Executor not initialized", ErrorCode.NotInitialized).build());
        
        if (command.length == 0)
            return BuildResult!Output.err(
                Errors.system("Empty command", ErrorCode.InvalidInput).build());
        
        // Create timeout enforcer
        auto timeoutEnforcer = createTimeoutEnforcer();
        if (timeout > Duration.zero)
        {
            timeoutEnforcer.start(timeout);
        }
        scope(exit)
        {
            if (timeout > Duration.zero)
                timeoutEnforcer.stop();
        }
        
        // Execute command
        auto result = execute(command, workingDir);
        
        // Check if timed out
        if (timeoutEnforcer.isTimedOut())
        {
            return BuildResult!Output.err(
                Errors.system("Execution timed out after " ~ timeout.toString(), ErrorCode.ProcessTimeout).build());
        }
        
        return result;
    }
    
    /// Get sandbox specification
    const(SandboxSpec) getSpec() @safe const pure nothrow
    {
        return spec;
    }
    
    /// Check if platform supports hermetic builds
    static bool isSupported() @safe pure nothrow
    {
        version(linux)
            return true;
        else version(OSX)
            return true;
        else
            return false;
    }
    
    /// Get platform name
    static string platform() @safe pure nothrow
    {
        version(linux)
            return "linux-namespaces";
        else version(OSX)
            return "macos-sandbox";
        else version(Windows)
            return "windows-job";
        else
            return "fallback";
    }
    
    version(linux)
    {
        /// Execute using Linux namespaces
        private BuildResult!Output executeLinux(string[] command, string workingDir) @system
        {
            auto sandboxResult = LinuxSandbox.create(spec, workDir);
            if (sandboxResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(sandboxResult.unwrapErr(), ErrorCode.SandboxError).build());
            
            auto sandbox = sandboxResult.unwrap();
            auto execResult = sandbox.execute(command, workingDir);
            
            if (execResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(execResult.unwrapErr(), ErrorCode.ProcessSpawnFailed).build());
            
            auto linuxOutput = execResult.unwrap();
            Output output;
            output.stdout = linuxOutput.stdout;
            output.stderr = linuxOutput.stderr;
            output.exitCode = linuxOutput.exitCode;
            output.hermetic = true;
            
            return BuildResult!Output.ok(output);
        }
    }
    
    version(OSX)
    {
        /// Execute using macOS sandbox-exec
        private BuildResult!Output executeMacOS(string[] command, string workingDir) @system
        {
            auto sandboxResult = MacOSSandbox.create(spec);
            if (sandboxResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(sandboxResult.unwrapErr(), ErrorCode.SandboxError).build());
            
            auto sandbox = sandboxResult.unwrap();
            auto execResult = sandbox.execute(command, workingDir);
            
            if (execResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(execResult.unwrapErr(), ErrorCode.ProcessSpawnFailed).build());
            
            auto macOutput = execResult.unwrap();
            Output output;
            output.stdout = macOutput.stdout;
            output.stderr = macOutput.stderr;
            output.exitCode = macOutput.exitCode;
            output.hermetic = true;
            
            return BuildResult!Output.ok(output);
        }
    }
    
    version(Windows)
    {
        /// Execute using Windows job objects
        /// 
        /// Provides process-level isolation with:
        /// - JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (guaranteed cleanup)
        /// - BREAKAWAY_OK disabled (no process escape)
        /// - Memory/CPU/process limits
        /// - UI restrictions (clipboard, desktop isolation)
        /// - CPU rate limiting (Windows 8+)
        /// 
        /// Note: Does not provide filesystem/network isolation like Linux namespaces
        private BuildResult!Output executeWindows(string[] command, string workingDir) @system
        {
            auto sandboxResult = WindowsSandbox.create(spec, workDir);
            if (sandboxResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(sandboxResult.unwrapErr(), ErrorCode.SandboxError).build());
            
            auto sandbox = sandboxResult.unwrap();
            scope(exit) sandbox.cleanup();
            
            auto execResult = sandbox.execute(command, workingDir);
            
            if (execResult.isErr)
                return BuildResult!Output.err(
                    Errors.system(execResult.unwrapErr(), ErrorCode.ProcessSpawnFailed).build());
            
            auto winOutput = execResult.unwrap();
            Output output;
            output.stdout = winOutput.stdout;
            output.stderr = winOutput.stderr;
            output.exitCode = winOutput.exitCode;
            // Windows provides process isolation but not filesystem/network isolation
            output.hermetic = false;
            
            return BuildResult!Output.ok(output);
        }
    }
    
    /// Fallback execution (no sandboxing, validation only)
    private BuildResult!Output executeFallback(string[] command, string workingDir) @system
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate command
        foreach (arg; command)
        {
            if (!SecurityValidator.isArgumentSafe(arg))
                return BuildResult!Output.err(
                    Errors.system("Unsafe command argument: " ~ arg, ErrorCode.InvalidInput).build());
        }
        
        // Build environment
        auto env = spec.environment.toMap();
        
        // Execute without sandboxing
        try
        {
            auto result = .execute(command, env, Config.none, size_t.max, workingDir);
            
            Output output;
            output.stdout = result.output;
            output.stderr = "";
            output.exitCode = result.status;
            output.hermetic = false;  // Not truly hermetic
            
            return BuildResult!Output.ok(output);
        }
        catch (Exception e)
        {
            return BuildResult!Output.err(
                processExecutionError(command[0], 1, "Execution failed: " ~ e.msg));
        }
    }
}

/// Execution output
struct Output
{
    string stdout;
    string stderr;
    int exitCode;
    bool hermetic;  // Was execution truly hermetic?
    string[] outputFiles;  // Paths to output files produced
    
    /// Check if execution succeeded
    bool success() @safe const pure nothrow
    {
        return exitCode == 0;
    }
}

/// Builder for common sandbox specifications
struct HermeticSpecBuilder
{
    /// Create spec for typical build (read sources, write outputs)
    static BuildResult!SandboxSpec forBuild(
        string workspaceRoot,
        string[] sources,
        string outputDir,
        string tempDir
    ) @system
    {
        auto builder = SandboxSpecBuilder.create();
        
        // Add workspace as input (read source files)
        builder.input(workspaceRoot);
        
        // Add output directory
        builder.output(outputDir);
        
        // Add temp directory
        builder.temp(tempDir);
        
        // Add standard library paths (read-only)
        version(linux)
        {
            builder.input("/usr/lib");
            builder.input("/usr/include");
            builder.input("/lib");
            builder.input("/lib64");
        }
        version(OSX)
        {
            builder.input("/usr/lib");
            builder.input("/usr/include");
            builder.input("/System/Library");
            builder.input("/Library");
        }
        
        // Hermetic network (no access)
        builder.withNetwork(NetworkPolicy.hermetic());
        
        // Add minimal environment
        builder.env("PATH", "/usr/bin:/bin");
        builder.env("LANG", "C.UTF-8");
        
        auto result = builder.build();
        if (result.isErr)
            return BuildResult!SandboxSpec.err(
                Errors.system(result.unwrapErr(), ErrorCode.InvalidConfiguration).build());
        return BuildResult!SandboxSpec.ok(result.unwrap());
    }
    
    /// Create spec for test execution
    static BuildResult!SandboxSpec forTest(
        string workspaceRoot,
        string testDir,
        string tempDir
    ) @system
    {
        auto builder = SandboxSpecBuilder.create();
        
        // Tests can read workspace
        builder.input(workspaceRoot);
        
        // Tests can write to temp
        builder.temp(tempDir);
        
        // Add standard library paths
        version(linux)
        {
            builder.input("/usr/lib");
            builder.input("/lib");
        }
        version(OSX)
        {
            builder.input("/usr/lib");
            builder.input("/System/Library");
        }
        
        // Tests might need network (less strict)
        auto networkPolicy = NetworkPolicy.hermetic();
        builder.withNetwork(networkPolicy);
        
        // Standard environment
        builder.env("PATH", "/usr/bin:/bin");
        builder.env("LANG", "C.UTF-8");
        
        auto result = builder.build();
        if (result.isErr)
            return BuildResult!SandboxSpec.err(
                Errors.system(result.unwrapErr(), ErrorCode.InvalidConfiguration).build());
        return BuildResult!SandboxSpec.ok(result.unwrap());
    }
}

// Result type imported from errors module

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing hermetic executor...");
    
    // Test spec creation
    auto specResult = HermeticSpecBuilder.forBuild(
        "/tmp/workspace",
        ["/tmp/workspace/main.d"],
        "/tmp/output",
        "/tmp/temp"
    );
    
    assert(specResult.isOk, "Failed to create spec: " ~ specResult.unwrapErr().toString());
    
    // Test executor creation
    auto executorResult = HermeticExecutor.create(specResult.unwrap());
    assert(executorResult.isOk, "Failed to create executor");
    
    writeln("Hermetic executor platform: ", HermeticExecutor.platform());
    writeln("Hermetic builds supported: ", HermeticExecutor.isSupported());
}

