module infrastructure.errors.codes.system;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// System-level error codes (8000-8999)
/// Covers process management, memory, threads, and OS interactions
enum System : int
{
    /// Failed to spawn process
    ProcessSpawnFailed = 8000,
    /// Process timed out
    ProcessTimeout = 8001,
    /// Process crashed
    ProcessCrashed = 8002,
    /// Out of memory
    OutOfMemory = 8003,
    /// Thread pool error
    ThreadPoolError = 8004,
    /// Signal received (SIGINT, SIGTERM)
    SignalReceived = 8005,
    /// Fork failed
    ForkFailed = 8006,
    /// Exec failed
    ExecFailed = 8007,
    /// Environment variable error
    EnvironmentError = 8008,
    /// Working directory error
    WorkingDirectoryError = 8009,
    /// Pipe creation failed
    PipeError = 8010,
    /// Standard I/O redirection failed
    RedirectionFailed = 8011,
    /// Process limit exceeded
    ProcessLimitExceeded = 8012,
    /// Thread creation failed
    ThreadCreationFailed = 8013,
    /// Mutex/lock error
    LockError = 8014,
    /// Deadlock detected
    DeadlockDetected = 8015,
    /// Stack overflow
    StackOverflow = 8016,
    /// Resource leak detected
    ResourceLeak = 8017,
    /// Platform not supported
    PlatformNotSupported = 8018,
    /// Library load failed (dlopen)
    LibraryLoadFailed = 8019,
    /// Symbol lookup failed (dlsym)
    SymbolLookupFailed = 8020,
    /// IPC error
    IPCError = 8021,
    /// Shared memory error
    SharedMemoryError = 8022,
    /// Timer error
    TimerError = 8023,
    /// Process not found
    ProcessNotFound = 8024,
    /// Cannot kill process
    KillFailed = 8025,
}

/// Namespace for system error utilities
struct SystemErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.System; }
    
    static Recoverability recoverabilityOf(System code) pure nothrow @nogc
    {
        switch (code)
        {
            case System.ProcessTimeout:
            case System.ThreadPoolError:
            case System.LockError:
            case System.ProcessLimitExceeded:
            case System.IPCError:
                return Recoverability.Transient;
            case System.EnvironmentError:
            case System.WorkingDirectoryError:
            case System.PlatformNotSupported:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(System code) pure nothrow @safe
    {
        final switch (code)
        {
            case System.ProcessSpawnFailed:    return "Failed to spawn process";
            case System.ProcessTimeout:        return "Process timed out";
            case System.ProcessCrashed:        return "Process crashed";
            case System.OutOfMemory:           return "Out of memory";
            case System.ThreadPoolError:       return "Thread pool error";
            case System.SignalReceived:        return "Signal received";
            case System.ForkFailed:            return "Fork failed";
            case System.ExecFailed:            return "Exec failed";
            case System.EnvironmentError:      return "Environment variable error";
            case System.WorkingDirectoryError: return "Working directory error";
            case System.PipeError:             return "Pipe creation failed";
            case System.RedirectionFailed:     return "I/O redirection failed";
            case System.ProcessLimitExceeded:  return "Process limit exceeded";
            case System.ThreadCreationFailed:  return "Thread creation failed";
            case System.LockError:             return "Lock error";
            case System.DeadlockDetected:      return "Deadlock detected";
            case System.StackOverflow:         return "Stack overflow";
            case System.ResourceLeak:          return "Resource leak detected";
            case System.PlatformNotSupported:  return "Platform not supported";
            case System.LibraryLoadFailed:     return "Failed to load library";
            case System.SymbolLookupFailed:    return "Symbol lookup failed";
            case System.IPCError:              return "IPC error";
            case System.SharedMemoryError:     return "Shared memory error";
            case System.TimerError:            return "Timer error";
            case System.ProcessNotFound:       return "Process not found";
            case System.KillFailed:            return "Failed to kill process";
        }
    }
}

