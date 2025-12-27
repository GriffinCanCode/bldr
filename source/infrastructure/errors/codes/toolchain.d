module infrastructure.errors.codes.toolchain;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Toolchain management error codes (20000-20999)
/// Covers toolchain discovery, versioning, and configuration
enum ToolchainCode : int
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
    
    static Recoverability recoverabilityOf(ToolchainCode code) pure nothrow @nogc
    {
        switch (code)
        {
            case ToolchainCode.DownloadFailed:
            case ToolchainCode.InstallFailed:
            case ToolchainCode.UpdateFailed:
            case ToolchainCode.RegistryError:
                return Recoverability.Transient;
            case ToolchainCode.NotFound:
            case ToolchainCode.VersionNotFound:
            case ToolchainCode.InvalidSpecification:
            case ToolchainCode.AlreadyInstalled:
            case ToolchainCode.CompilerNotFound:
            case ToolchainCode.LinkerNotFound:
            case ToolchainCode.RuntimeNotFound:
            case ToolchainCode.InvalidPath:
            case ToolchainCode.CrossCompilationNotSupported:
            case ToolchainCode.SysrootNotFound:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(ToolchainCode code) pure nothrow @safe
    {
        final switch (code)
        {
            case ToolchainCode.Error:                       return "Toolchain error";
            case ToolchainCode.NotFound:                    return "Toolchain not found";
            case ToolchainCode.InstallFailed:               return "Toolchain installation failed";
            case ToolchainCode.VersionNotFound:             return "Toolchain version not found";
            case ToolchainCode.VersionConflict:             return "Toolchain version conflict";
            case ToolchainCode.VerificationFailed:          return "Toolchain verification failed";
            case ToolchainCode.DownloadFailed:              return "Toolchain download failed";
            case ToolchainCode.InvalidSpecification:        return "Invalid toolchain specification";
            case ToolchainCode.AlreadyInstalled:            return "Toolchain already installed";
            case ToolchainCode.UpdateFailed:                return "Toolchain update failed";
            case ToolchainCode.RemovalFailed:               return "Toolchain removal failed";
            case ToolchainCode.SDKNotFound:                 return "SDK not found";
            case ToolchainCode.SDKVersionMismatch:          return "SDK version mismatch";
            case ToolchainCode.CompilerNotFound:            return "Compiler not found";
            case ToolchainCode.LinkerNotFound:              return "Linker not found";
            case ToolchainCode.BuildToolsNotFound:          return "Build tools not found";
            case ToolchainCode.DebuggerNotFound:            return "Debugger not found";
            case ToolchainCode.RuntimeNotFound:             return "Runtime not found";
            case ToolchainCode.PlatformToolsNotFound:       return "Platform tools not found";
            case ToolchainCode.Corrupted:                   return "Toolchain corrupted";
            case ToolchainCode.InvalidPath:                 return "Invalid toolchain path";
            case ToolchainCode.RegistryError:               return "Toolchain registry error";
            case ToolchainCode.CrossCompilationNotSupported: return "Cross-compilation not supported";
            case ToolchainCode.SysrootNotFound:             return "Sysroot not found";
        }
    }
}

