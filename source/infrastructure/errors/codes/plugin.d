module infrastructure.errors.codes.plugin;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Plugin system error codes (13000-13999)
/// Covers plugin loading, execution, and protocol
enum Plugin : int
{
    /// Generic plugin error
    Error = 13000,
    /// Plugin not found
    NotFound = 13001,
    /// Failed to load plugin
    LoadFailed = 13002,
    /// Plugin crashed
    Crashed = 13003,
    /// Plugin operation timed out
    Timeout = 13004,
    /// Plugin returned invalid response
    InvalidResponse = 13005,
    /// Plugin protocol error
    ProtocolError = 13006,
    /// Plugin version mismatch
    VersionMismatch = 13007,
    /// Plugin missing required capability
    CapabilityMissing = 13008,
    /// Plugin validation failed
    ValidationFailed = 13009,
    /// Plugin execution failed
    ExecutionFailed = 13010,
    /// Invalid message format
    InvalidMessage = 13011,
    /// Tool not found in plugin
    ToolNotFound = 13012,
    /// Incompatible version
    IncompatibleVersion = 13013,
    /// Plugin initialization failed
    InitFailed = 13014,
    /// Plugin shutdown failed
    ShutdownFailed = 13015,
    /// Plugin dependency not met
    DependencyNotMet = 13016,
    /// Plugin conflict
    Conflict = 13017,
    /// Plugin sandbox violation
    SandboxViolation = 13018,
    /// Plugin memory limit exceeded
    MemoryLimitExceeded = 13019,
    /// Plugin CPU limit exceeded
    CPULimitExceeded = 13020,
    /// Plugin registry error
    RegistryError = 13021,
    /// Plugin manifest invalid
    ManifestInvalid = 13022,
    /// Plugin signature invalid
    SignatureInvalid = 13023,
    /// Plugin download failed
    DownloadFailed = 13024,
    /// Plugin update failed
    UpdateFailed = 13025,
}

/// Namespace for plugin error utilities
struct PluginErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Plugin; }
    
    static Recoverability recoverabilityOf(Plugin code) pure nothrow @nogc
    {
        switch (code)
        {
            case Plugin.Timeout:
            case Plugin.Crashed:
            case Plugin.MemoryLimitExceeded:
            case Plugin.CPULimitExceeded:
            case Plugin.DownloadFailed:
                return Recoverability.Transient;
            case Plugin.NotFound:
            case Plugin.VersionMismatch:
            case Plugin.CapabilityMissing:
            case Plugin.IncompatibleVersion:
            case Plugin.DependencyNotMet:
            case Plugin.Conflict:
            case Plugin.ManifestInvalid:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Plugin code) pure nothrow @safe
    {
        final switch (code)
        {
            case Plugin.Error:               return "Plugin error";
            case Plugin.NotFound:            return "Plugin not found";
            case Plugin.LoadFailed:          return "Failed to load plugin";
            case Plugin.Crashed:             return "Plugin crashed";
            case Plugin.Timeout:             return "Plugin operation timed out";
            case Plugin.InvalidResponse:     return "Plugin returned invalid response";
            case Plugin.ProtocolError:       return "Plugin protocol error";
            case Plugin.VersionMismatch:     return "Plugin version mismatch";
            case Plugin.CapabilityMissing:   return "Plugin missing required capability";
            case Plugin.ValidationFailed:    return "Plugin validation failed";
            case Plugin.ExecutionFailed:     return "Plugin execution failed";
            case Plugin.InvalidMessage:      return "Invalid message format";
            case Plugin.ToolNotFound:        return "Tool not found";
            case Plugin.IncompatibleVersion: return "Incompatible version";
            case Plugin.InitFailed:          return "Plugin initialization failed";
            case Plugin.ShutdownFailed:      return "Plugin shutdown failed";
            case Plugin.DependencyNotMet:    return "Plugin dependency not met";
            case Plugin.Conflict:            return "Plugin conflict";
            case Plugin.SandboxViolation:    return "Plugin sandbox violation";
            case Plugin.MemoryLimitExceeded: return "Plugin memory limit exceeded";
            case Plugin.CPULimitExceeded:    return "Plugin CPU limit exceeded";
            case Plugin.RegistryError:       return "Plugin registry error";
            case Plugin.ManifestInvalid:     return "Plugin manifest invalid";
            case Plugin.SignatureInvalid:    return "Plugin signature invalid";
            case Plugin.DownloadFailed:      return "Plugin download failed";
            case Plugin.UpdateFailed:        return "Plugin update failed";
        }
    }
}

