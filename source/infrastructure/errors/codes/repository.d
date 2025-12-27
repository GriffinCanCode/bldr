module infrastructure.errors.codes.repository;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Repository and external dependency error codes (4500-4599)
/// Covers repository fetching, verification, and management
enum Repository : int
{
    /// Generic repository error
    Error = 4500,
    /// Repository not found
    NotFound = 4501,
    /// Repository fetch failed
    FetchFailed = 4502,
    /// Repository verification failed
    VerificationFailed = 4503,
    /// Content verification failed
    ContentVerificationFailed = 4504,
    /// Invalid repository
    Invalid = 4505,
    /// Repository operation timed out
    Timeout = 4506,
    /// Repository already added
    AlreadyAdded = 4507,
    /// Repository lock conflict
    LockConflict = 4508,
    /// Archive extraction failed
    ExtractionFailed = 4509,
    /// Unsupported archive format
    UnsupportedFormat = 4510,
    /// Checksum mismatch
    ChecksumMismatch = 4511,
    /// Signature verification failed
    SignatureFailed = 4512,
    /// Repository URL invalid
    InvalidUrl = 4513,
    /// Git clone failed
    GitCloneFailed = 4514,
    /// Git checkout failed
    GitCheckoutFailed = 4515,
    /// Submodule error
    SubmoduleError = 4516,
    /// Repository depth limit
    DepthLimitExceeded = 4517,
    /// Repository too large
    TooLarge = 4518,
    /// Authentication required
    AuthenticationRequired = 4519,
    /// Invalid credentials
    InvalidCredentials = 4520,
    /// Patch application failed
    PatchFailed = 4521,
    /// Repository cache miss
    CacheMiss = 4522,
}

/// Namespace for repository error utilities
struct RepositoryErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Repository; }
    
    static Recoverability recoverabilityOf(Repository code) pure nothrow @nogc
    {
        switch (code)
        {
            case Repository.FetchFailed:
            case Repository.Timeout:
            case Repository.LockConflict:
            case Repository.CacheMiss:
                return Recoverability.Transient;
            case Repository.NotFound:
            case Repository.Invalid:
            case Repository.AlreadyAdded:
            case Repository.InvalidUrl:
            case Repository.AuthenticationRequired:
            case Repository.InvalidCredentials:
            case Repository.UnsupportedFormat:
            case Repository.TooLarge:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Repository code) pure nothrow @safe
    {
        final switch (code)
        {
            case Repository.Error:                    return "Repository operation failed";
            case Repository.NotFound:                 return "Repository not found";
            case Repository.FetchFailed:              return "Failed to fetch repository";
            case Repository.VerificationFailed:       return "Repository verification failed";
            case Repository.ContentVerificationFailed: return "Content verification failed";
            case Repository.Invalid:                  return "Invalid repository";
            case Repository.Timeout:                  return "Repository operation timed out";
            case Repository.AlreadyAdded:             return "Repository already added";
            case Repository.LockConflict:             return "Repository lock conflict";
            case Repository.ExtractionFailed:         return "Archive extraction failed";
            case Repository.UnsupportedFormat:        return "Unsupported archive format";
            case Repository.ChecksumMismatch:         return "Checksum mismatch";
            case Repository.SignatureFailed:          return "Signature verification failed";
            case Repository.InvalidUrl:               return "Invalid repository URL";
            case Repository.GitCloneFailed:           return "Git clone failed";
            case Repository.GitCheckoutFailed:        return "Git checkout failed";
            case Repository.SubmoduleError:           return "Submodule error";
            case Repository.DepthLimitExceeded:       return "Repository depth limit exceeded";
            case Repository.TooLarge:                 return "Repository too large";
            case Repository.AuthenticationRequired:   return "Authentication required";
            case Repository.InvalidCredentials:       return "Invalid credentials";
            case Repository.PatchFailed:              return "Patch application failed";
            case Repository.CacheMiss:                return "Repository cache miss";
        }
    }
}

