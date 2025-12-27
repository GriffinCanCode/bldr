module engine.runtime.hermetic.sandbox.contract;

import std.datetime : Duration;
import engine.runtime.hermetic.core.spec;
import infrastructure.errors;

// Re-export core output type from central location
public import engine.runtime.hermetic.core.executor : Output;

/// Extended metrics for sandbox execution (augments core Output)
struct SandboxMetrics
{
    Duration wallTime;      // Wall clock time
    Duration userTime;      // User CPU time
    Duration systemTime;    // System CPU time
    ulong peakMemory;       // Peak memory in bytes
    ulong diskRead;         // Disk bytes read
    ulong diskWrite;        // Disk bytes written
    uint forks;             // Number of forks
    bool memoryExceeded;    // OOM occurred
    bool timeExceeded;      // Timeout occurred
}

/// Sandbox isolation level (re-uses existing from capabilities)
public import engine.runtime.hermetic.platforms.capabilities : IsolationLevel;

/// Abstract sandbox contract using compile-time interface enforcement
/// Extends existing HermeticExecutor pattern with enhanced capabilities
interface ISandbox
{
    /// Execute command in sandbox, returns result monad
    BuildResult!Output execute(string[] command, string workDir) @system;
    
    /// Execute with explicit timeout
    BuildResult!Output executeWithTimeout(string[] command, Duration timeout, string workDir) @system;
    
    /// Get sandbox spec
    const(SandboxSpec) spec() @safe const pure nothrow;
    
    /// Get isolation level achieved
    IsolationLevel isolation() @safe const pure nothrow;
    
    /// Get execution metrics
    SandboxMetrics metrics() @safe const;
    
    /// Cleanup sandbox resources
    void cleanup() @system nothrow;
}

/// Sandbox error categories for precise error handling
enum SandboxErrorKind
{
    Initialization,    // Failed to setup sandbox
    Permission,        // Permission denied
    ResourceLimit,     // Resource limit hit
    Timeout,           // Execution timeout
    Syscall,           // Blocked syscall
    NetworkViolation,  // Network access denied
    FilesystemViolation, // Filesystem access denied
    ProcessViolation,  // Process limit exceeded
}

/// Create sandbox error with kind classification
BuildError sandboxError(SandboxErrorKind kind, string msg) @trusted
{
    import std.conv : to;
    return Errors.system(msg, Distributed.SandboxError)
        .withContext("kind", kind.to!string)
        .build();
}


