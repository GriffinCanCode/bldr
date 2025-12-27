module infrastructure.errors.codes.watch;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Watch mode error codes (15000-15999)
/// Covers file system monitoring and incremental rebuild
enum Watch : int
{
    /// Generic watch error
    Error = 15000,
    /// Failed to initialize watcher
    InitFailed = 15001,
    /// File watcher not supported on platform
    NotSupported = 15002,
    /// File watcher crashed
    Crashed = 15003,
    /// Failed to watch file
    FileFailed = 15004,
    /// Debounce error
    DebounceError = 15005,
    /// Too many watch targets
    TooManyTargets = 15006,
    /// Watch directory not found
    DirectoryNotFound = 15007,
    /// Watch permission denied
    PermissionDenied = 15008,
    /// Inotify limit reached (Linux)
    InotifyLimitReached = 15009,
    /// FSEvents error (macOS)
    FSEventsError = 15010,
    /// File moved/deleted during watch
    FileMovedOrDeleted = 15011,
    /// Watch event overflow
    EventOverflow = 15012,
    /// Watch handle invalid
    HandleInvalid = 15013,
    /// Watch subscription failed
    SubscriptionFailed = 15014,
    /// Polling fallback required
    PollingRequired = 15015,
    /// Recursive watch not supported
    RecursiveNotSupported = 15016,
    /// Watch filter error
    FilterError = 15017,
    /// Watch queue full
    QueueFull = 15018,
}

/// Namespace for watch error utilities
struct WatchErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Watch; }
    
    static Recoverability recoverabilityOf(Watch code) pure nothrow @nogc
    {
        switch (code)
        {
            case Watch.Crashed:
            case Watch.FileFailed:
            case Watch.FileMovedOrDeleted:
            case Watch.EventOverflow:
            case Watch.QueueFull:
                return Recoverability.Transient;
            case Watch.NotSupported:
            case Watch.TooManyTargets:
            case Watch.DirectoryNotFound:
            case Watch.PermissionDenied:
            case Watch.InotifyLimitReached:
            case Watch.RecursiveNotSupported:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Watch code) pure nothrow @safe
    {
        final switch (code)
        {
            case Watch.Error:                 return "Watch mode error";
            case Watch.InitFailed:            return "Failed to initialize file watcher";
            case Watch.NotSupported:          return "File watcher not supported";
            case Watch.Crashed:               return "File watcher crashed";
            case Watch.FileFailed:            return "Failed to watch file";
            case Watch.DebounceError:         return "Debounce error";
            case Watch.TooManyTargets:        return "Too many watch targets";
            case Watch.DirectoryNotFound:     return "Watch directory not found";
            case Watch.PermissionDenied:      return "Watch permission denied";
            case Watch.InotifyLimitReached:   return "Inotify watch limit reached";
            case Watch.FSEventsError:         return "FSEvents error";
            case Watch.FileMovedOrDeleted:    return "File moved or deleted";
            case Watch.EventOverflow:         return "Watch event overflow";
            case Watch.HandleInvalid:         return "Watch handle invalid";
            case Watch.SubscriptionFailed:    return "Watch subscription failed";
            case Watch.PollingRequired:       return "Polling fallback required";
            case Watch.RecursiveNotSupported: return "Recursive watch not supported";
            case Watch.FilterError:           return "Watch filter error";
            case Watch.QueueFull:             return "Watch queue full";
        }
    }
}

