module engine.runtime.hermetic.tracing;

/// Syscall Tracing for Hermetic Verification
/// 
/// Provides runtime verification of hermeticity by intercepting and analyzing
/// syscalls made during build execution. Goes beyond static analysis to
/// empirically prove that builds don't access prohibited resources.
/// 
/// Platform Support:
/// - Linux: seccomp-bpf with SECCOMP_RET_TRACE (ptrace-based)
/// - macOS: sandbox-exec with logging profile
/// 
/// Usage:
/// ```d
/// import engine.runtime.hermetic.tracing;
/// 
/// // Create tracer with policy
/// auto policy = SyscallPolicy.hermetic();
/// auto tracerResult = SyscallTracer.create(policy);
/// 
/// // Execute command with tracing
/// auto result = tracerResult.unwrap().traceExecution(
///     ["gcc", "main.c", "-o", "main"],
///     "/workspace"
/// );
/// 
/// // Analyze for hermeticity violations
/// auto violations = result.unwrap().analyzeHermeticity();
/// if (violations.length > 0) {
///     foreach (v; violations)
///         writeln("Violation: ", v.description);
/// }
/// ```
/// 
/// Architecture:
/// - `tracer.d`: Core SyscallTracer with platform dispatch
/// - `linux.d`: Linux seccomp-bpf TRACE implementation
/// - `darwin.d`: macOS sandbox-exec logging implementation
/// - `analyzer.d`: Syscall analysis for hermeticity violations

public import engine.runtime.hermetic.tracing.tracer;
public import engine.runtime.hermetic.tracing.analyzer;
public import engine.runtime.hermetic.tracing.verifier;

version(linux)
    public import engine.runtime.hermetic.tracing.linux;

version(OSX)
    public import engine.runtime.hermetic.tracing.darwin;

