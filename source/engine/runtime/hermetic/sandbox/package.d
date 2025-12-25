module engine.runtime.hermetic.sandbox;

/// Enhanced sandbox system with complete OS-level isolation
/// 
/// Architecture:
/// - `contract`: Interface definition and common types
/// - `namespaces`: Linux namespace sandbox (CLONE_NEW* + pivot_root)
/// - `cgroups`: Linux cgroup v2 resource control
/// - `darwin`: macOS sandbox-exec with SBPL profiles
/// - `profiles`: SBPL profile generator
/// 
/// Uses existing modules:
/// - `security.seccomp`: Syscall filtering
/// - `core.spec`: Sandbox specification
/// - `core.executor.Output`: Unified output type
/// - `monitoring`: Resource monitoring

public import engine.runtime.hermetic.sandbox.contract;
public import engine.runtime.hermetic.core.spec : SandboxSpec, SandboxSpecBuilder;
public import engine.runtime.hermetic.platforms.capabilities : 
    getCapabilities, platformSupportsHermetic, SandboxCapabilities;
import infrastructure.errors : BuildResult;

version(linux)
{
    public import engine.runtime.hermetic.sandbox.namespaces;
    public import engine.runtime.hermetic.sandbox.cgroups;
}

version(OSX)
{
    public import engine.runtime.hermetic.sandbox.darwin;
    public import engine.runtime.hermetic.sandbox.profiles;
}

/// Create platform-appropriate enhanced sandbox
/// Returns null if platform doesn't support sandboxing
ISandbox createEnhancedSandbox(SandboxSpec spec, string workDir) @system
{
    version(linux)
    {
        auto caps = getCapabilities();
        if (!caps.namespacesAvailable)
            return null;
        
        auto result = NamespaceSandbox.create(spec, workDir);
        return result.isOk ? result.unwrap() : null;
    }
    else version(OSX)
    {
        auto caps = getCapabilities();
        if (!caps.sandboxExecAvailable)
            return null;
        
        auto result = DarwinSandbox.create(spec);
        return result.isOk ? result.unwrap() : null;
    }
    else
    {
        return null;
    }
}

/// Create sandbox with Result monad for error handling
BuildResult!ISandbox createSandbox(SandboxSpec spec, string workDir) @system
{
    version(linux)
    {
        auto caps = getCapabilities();
        if (!caps.namespacesAvailable)
            return BuildResult!ISandbox.err(sandboxError(
                SandboxErrorKind.Initialization, "Linux namespaces not available"));
        
        auto result = NamespaceSandbox.create(spec, workDir);
        if (result.isErr)
            return BuildResult!ISandbox.err(result.unwrapErr());
        return BuildResult!ISandbox.ok(cast(ISandbox) result.unwrap());
    }
    else version(OSX)
    {
        auto caps = getCapabilities();
        if (!caps.sandboxExecAvailable)
            return BuildResult!ISandbox.err(sandboxError(
                SandboxErrorKind.Initialization, "sandbox-exec not available"));
        
        auto result = DarwinSandbox.create(spec);
        if (result.isErr)
            return BuildResult!ISandbox.err(result.unwrapErr());
        return BuildResult!ISandbox.ok(cast(ISandbox) result.unwrap());
    }
    else
    {
        return BuildResult!ISandbox.err(sandboxError(
            SandboxErrorKind.Initialization, "Platform not supported"));
    }
}


