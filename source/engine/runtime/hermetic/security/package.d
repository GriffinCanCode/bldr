module engine.runtime.hermetic.security;

/// Security and compliance features for hermetic execution
/// 
/// This module provides:
/// - Audit logging for sandbox violations
/// - Timeout enforcement to prevent hanging builds
/// - Violation tracking and reporting
/// - Seccomp-BPF syscall filtering (Linux)

public import engine.runtime.hermetic.security.audit;
public import engine.runtime.hermetic.security.timeout;

version(linux)
{
    public import engine.runtime.hermetic.security.seccomp;
}

