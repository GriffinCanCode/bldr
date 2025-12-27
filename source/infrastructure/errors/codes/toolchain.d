module infrastructure.errors.codes.toolchain;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Toolchain management error codes (20000-20999)
/// Covers toolchain discovery, versioning, and configuration
enum Toolchain : int
{
    /// Generic toolchain error
    Error = 20000,
    /// Toolchain not found
    NotFound = 20001,
    /// Toolchain installation failed
    InstallFailed = 20002,
    /// Toolchain version not found
    VersionNotFound = 20003,
    /// Toolchain version conflict
    VersionConflict = 20004,
    /// Toolchain verification failed
    VerificationFailed = 20005,
    /// Toolchain download failed
    DownloadFailed = 20006,
    /// Invalid toolchain specification
    InvalidSpecification = 20007,
    /// Toolchain already installed
    AlreadyInstalled = 20008,
    /// Toolchain update failed
    UpdateFailed = 20009,
    /// Toolchain removal failed
    RemovalFailed = 20010,
    /// SDK not found
    SDKNotFound = 20011,
    /// SDK version mismatch
    SDKVersionMismatch = 20012,
    /// Compiler not found
    CompilerNotFound = 20013,
    /// Linker not found
    LinkerNotFound = 20014,
    /// Build tools not found
    BuildToolsNotFound = 20015,
    /// Debugger not found
    DebuggerNotFound = 20016,
    /// Runtime not found
    RuntimeNotFound = 20017,
    /// Platform tools not found
    PlatformToolsNotFound = 20018,
    /// Toolchain corrupted
    Corrupted = 20019,
    /// Toolchain path invalid
    InvalidPath = 20020,
    /// Toolchain registry error
    RegistryError = 20021,
    /// Cross-compilation not supported
    CrossCompilationNotSupported = 20022,
    /// Sysroot not found
    SysrootNotFound = 20023,
}

/// Namespace for toolchain error utilities
struct ToolchainErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Toolchain; }
    
    static Recoverability recoverabilityOf(Toolchain code) pure nothrow @nogc
    {
        switch (code)
        {
            case Toolchain.DownloadFailed:
            case Toolchain.InstallFailed:
            case Toolchain.UpdateFailed:
            case Toolchain.RegistryError:
                return Recoverability.Transient;
            case Toolchain.NotFound:
            case Toolchain.VersionNotFound:
            case Toolchain.InvalidSpecification:
            case Toolchain.AlreadyInstalled:
            case Toolchain.CompilerNotFound:
            case Toolchain.LinkerNotFound:
            case Toolchain.RuntimeNotFound:
            case Toolchain.InvalidPath:
            case Toolchain.CrossCompilationNotSupported:
            case Toolchain.SysrootNotFound:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Toolchain code) pure nothrow @safe
    {
        final switch (code)
        {
            case Toolchain.Error:                       return "Toolchain error";
            case Toolchain.NotFound:                    return "Toolchain not found";
            case Toolchain.InstallFailed:               return "Toolchain installation failed";
            case Toolchain.VersionNotFound:             return "Toolchain version not found";
            case Toolchain.VersionConflict:             return "Toolchain version conflict";
            case Toolchain.VerificationFailed:          return "Toolchain verification failed";
            case Toolchain.DownloadFailed:              return "Toolchain download failed";
            case Toolchain.InvalidSpecification:        return "Invalid toolchain specification";
            case Toolchain.AlreadyInstalled:            return "Toolchain already installed";
            case Toolchain.UpdateFailed:                return "Toolchain update failed";
            case Toolchain.RemovalFailed:               return "Toolchain removal failed";
            case Toolchain.SDKNotFound:                 return "SDK not found";
            case Toolchain.SDKVersionMismatch:          return "SDK version mismatch";
            case Toolchain.CompilerNotFound:            return "Compiler not found";
            case Toolchain.LinkerNotFound:              return "Linker not found";
            case Toolchain.BuildToolsNotFound:          return "Build tools not found";
            case Toolchain.DebuggerNotFound:            return "Debugger not found";
            case Toolchain.RuntimeNotFound:             return "Runtime not found";
            case Toolchain.PlatformToolsNotFound:       return "Platform tools not found";
            case Toolchain.Corrupted:                   return "Toolchain corrupted";
            case Toolchain.InvalidPath:                 return "Invalid toolchain path";
            case Toolchain.RegistryError:               return "Toolchain registry error";
            case Toolchain.CrossCompilationNotSupported: return "Cross-compilation not supported";
            case Toolchain.SysrootNotFound:             return "Sysroot not found";
        }
    }
}

