module infrastructure.errors.codes.build;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Build execution error codes (1000-1999)
/// Covers compilation, linking, output generation, and build orchestration
enum Build : int
{
    /// Generic build failure
    Failed = 1000,
    /// Build exceeded time limit
    Timeout = 1001,
    /// Build was cancelled by user or system
    Cancelled = 1002,
    /// Requested target does not exist
    TargetNotFound = 1003,
    /// No language handler for file type
    HandlerNotFound = 1004,
    /// Expected output file not produced
    OutputMissing = 1005,
    /// Build action execution failed
    ActionFailed = 1006,
    /// Target dependency failed
    DependencyFailed = 1007,
    /// Resource limit exceeded (CPU, memory, etc.)
    ResourceExhausted = 1008,
    /// Build step skipped (already up-to-date)
    Skipped = 1009,
    /// Parallel build coordination failure
    ParallelizationFailed = 1010,
    /// Action digest mismatch (cache invalidation)
    DigestMismatch = 1011,
    /// Input file changed during build
    InputModified = 1012,
    /// Command not found in PATH
    CommandNotFound = 1013,
    /// Exit code indicates failure
    NonZeroExit = 1014,
    /// Build rule not found
    RuleNotFound = 1015,
}

/// Namespace for build error utilities
struct BuildErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Build; }
    
    static Recoverability recoverabilityOf(Build code) pure nothrow @nogc
    {
        switch (code)
        {
            case Build.Timeout:
            case Build.ResourceExhausted:
            case Build.InputModified:
                return Recoverability.Transient;
            case Build.TargetNotFound:
            case Build.HandlerNotFound:
            case Build.RuleNotFound:
            case Build.CommandNotFound:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Build code) pure nothrow @safe
    {
        final switch (code)
        {
            case Build.Failed:               return "Build failed";
            case Build.Timeout:              return "Build timed out";
            case Build.Cancelled:            return "Build was cancelled";
            case Build.TargetNotFound:       return "Target not found";
            case Build.HandlerNotFound:      return "Language handler not found";
            case Build.OutputMissing:        return "Expected output not found";
            case Build.ActionFailed:         return "Build action failed";
            case Build.DependencyFailed:     return "Dependency build failed";
            case Build.ResourceExhausted:    return "Resource limit exceeded";
            case Build.Skipped:              return "Build step skipped";
            case Build.ParallelizationFailed: return "Parallel build failed";
            case Build.DigestMismatch:       return "Action digest mismatch";
            case Build.InputModified:        return "Input modified during build";
            case Build.CommandNotFound:      return "Command not found";
            case Build.NonZeroExit:          return "Command returned non-zero exit code";
            case Build.RuleNotFound:         return "Build rule not found";
        }
    }
}

