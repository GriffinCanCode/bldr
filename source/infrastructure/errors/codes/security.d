module infrastructure.errors.codes.security;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Security error codes (19000-19999)
/// Covers authentication, authorization, signatures, and sandboxing
enum Security : int
{
    /// Generic security error
    Error = 19000,
    /// Authentication failed
    AuthenticationFailed = 19001,
    /// Authorization denied
    AuthorizationDenied = 19002,
    /// Invalid token
    InvalidToken = 19003,
    /// Token expired
    TokenExpired = 19004,
    /// Signature verification failed
    SignatureInvalid = 19005,
    /// Certificate invalid
    CertificateInvalid = 19006,
    /// Certificate expired
    CertificateExpired = 19007,
    /// Key not found
    KeyNotFound = 19008,
    /// Key generation failed
    KeyGenerationFailed = 19009,
    /// Encryption failed
    EncryptionFailed = 19010,
    /// Decryption failed
    DecryptionFailed = 19011,
    /// Hash mismatch
    HashMismatch = 19012,
    /// Sandbox escape attempt
    SandboxEscape = 19013,
    /// Prohibited syscall
    ProhibitedSyscall = 19014,
    /// Network access denied
    NetworkAccessDenied = 19015,
    /// File system access denied
    FileSystemAccessDenied = 19016,
    /// Resource access denied
    ResourceAccessDenied = 19017,
    /// Integrity check failed
    IntegrityCheckFailed = 19018,
    /// Trust chain broken
    TrustChainBroken = 19019,
    /// Keyring error
    KeyringError = 19020,
    /// Secret not found
    SecretNotFound = 19021,
    /// Secret expired
    SecretExpired = 19022,
    /// API key invalid
    APIKeyInvalid = 19023,
    /// Rate limit security
    RateLimitSecurity = 19024,
    /// Suspicious activity
    SuspiciousActivity = 19025,
    /// Command injection attempt
    CommandInjection = 19026,
    /// Invalid/unsafe command
    InvalidCommand = 19027,
    /// Path traversal attempt
    PathTraversal = 19028,
    /// Access denied (generic)
    AccessDenied = 19029,
}

/// Namespace for security error utilities
struct SecurityErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Security; }
    
    static Recoverability recoverabilityOf(Security code) pure nothrow @nogc
    {
        switch (code)
        {
            case Security.TokenExpired:
            case Security.CertificateExpired:
            case Security.SecretExpired:
            case Security.RateLimitSecurity:
                return Recoverability.Transient;
            case Security.AuthenticationFailed:
            case Security.InvalidToken:
            case Security.KeyNotFound:
            case Security.SecretNotFound:
            case Security.APIKeyInvalid:
            case Security.NetworkAccessDenied:
            case Security.FileSystemAccessDenied:
            case Security.AccessDenied:
                return Recoverability.User;
            case Security.CommandInjection:
            case Security.InvalidCommand:
            case Security.PathTraversal:
                return Recoverability.Fatal;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Security code) pure nothrow @safe
    {
        final switch (code)
        {
            case Security.Error:                  return "Security error";
            case Security.AuthenticationFailed:   return "Authentication failed";
            case Security.AuthorizationDenied:    return "Authorization denied";
            case Security.InvalidToken:           return "Invalid token";
            case Security.TokenExpired:           return "Token expired";
            case Security.SignatureInvalid:       return "Signature verification failed";
            case Security.CertificateInvalid:     return "Invalid certificate";
            case Security.CertificateExpired:     return "Certificate expired";
            case Security.KeyNotFound:            return "Key not found";
            case Security.KeyGenerationFailed:    return "Key generation failed";
            case Security.EncryptionFailed:       return "Encryption failed";
            case Security.DecryptionFailed:       return "Decryption failed";
            case Security.HashMismatch:           return "Hash mismatch";
            case Security.SandboxEscape:          return "Sandbox escape attempt detected";
            case Security.ProhibitedSyscall:      return "Prohibited syscall";
            case Security.NetworkAccessDenied:    return "Network access denied";
            case Security.FileSystemAccessDenied: return "File system access denied";
            case Security.ResourceAccessDenied:   return "Resource access denied";
            case Security.IntegrityCheckFailed:   return "Integrity check failed";
            case Security.TrustChainBroken:       return "Trust chain broken";
            case Security.KeyringError:           return "Keyring error";
            case Security.SecretNotFound:         return "Secret not found";
            case Security.SecretExpired:          return "Secret expired";
            case Security.APIKeyInvalid:          return "Invalid API key";
            case Security.RateLimitSecurity:      return "Security rate limit exceeded";
            case Security.SuspiciousActivity:     return "Suspicious activity detected";
            case Security.CommandInjection:       return "Command injection attempt detected";
            case Security.InvalidCommand:         return "Invalid/unsafe command";
            case Security.PathTraversal:          return "Path traversal attempt detected";
            case Security.AccessDenied:           return "Access denied";
        }
    }
}

