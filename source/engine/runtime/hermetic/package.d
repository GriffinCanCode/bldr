module engine.runtime.hermetic;

/// Hermetic build execution system with determinism enforcement
/// 
/// Provides platform-specific sandboxing for reproducible builds:
/// - Linux: namespace-based isolation (mount, PID, network, IPC, UTS, user) + cgroup v2
/// - macOS: sandbox-exec with SBPL profiles + rusage monitoring
/// - Windows: job objects with resource limits + I/O accounting
/// 
/// Determinism enforcement beyond hermeticity:
/// - Syscall interception (time, random, etc.)
/// - Automatic non-determinism detection
/// - Build output verification
/// - Repair suggestions with compiler flags
/// 
/// Usage:
/// ```d
/// // Basic hermetic execution
/// auto spec = HermeticSpecBuilder.forBuild(
///     workspaceRoot,
///     sources,
///     outputDir,
///     tempDir
/// );
/// 
/// auto executor = HermeticExecutor.create(spec.unwrap());
/// auto result = executor.unwrap().execute(["gcc", "main.c", "-o", "main"]);
/// 
/// // With determinism enforcement
/// import engine.runtime.hermetic.determinism;
/// auto config = DeterminismConfig.strict();
/// auto enforcer = DeterminismEnforcer.create(executor.unwrap(), config);
/// auto detResult = enforcer.unwrap().executeAndVerify(command, workDir, 3);
/// 
/// // With monitoring
/// auto monitor = createMonitor(spec.unwrap().resources);
/// monitor.start();
/// // ... execute ...
/// auto usage = monitor.snapshot();
/// monitor.stop();
/// ```

// Core abstractions
public import engine.runtime.hermetic.core;

// Security features
public import engine.runtime.hermetic.security;

// Resource monitoring
public import engine.runtime.hermetic.monitoring;

// Determinism enforcement
public import engine.runtime.hermetic.determinism;

// Enhanced sandbox (OS-level isolation)
public import engine.runtime.hermetic.sandbox;

// Platform-specific implementations
version(linux)
{
    public import engine.runtime.hermetic.platforms.linux;
    public import engine.runtime.hermetic.monitoring.linux;
}

version(OSX)
{
    public import engine.runtime.hermetic.platforms.macos;
    public import engine.runtime.hermetic.monitoring.macos;
}

version(Windows)
{
    public import engine.runtime.hermetic.platforms.windows;
    public import engine.runtime.hermetic.monitoring.windows;
}
