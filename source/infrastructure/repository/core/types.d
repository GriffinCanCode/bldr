module infrastructure.repository.core.types;

import std.datetime : SysTime;
import infrastructure.errors;

/// Repository source type
enum RepositoryKind
{
    Http,      // HTTP/HTTPS archive (tar.gz, zip, etc.)
    Git,       // Git repository with specific commit
    Local      // Local filesystem path (for development)
}

/// Archive format for HTTP repositories
enum ArchiveFormat
{
    Auto,      // Auto-detect from URL/content
    TarGz,     // .tar.gz
    Tar,       // .tar
    Zip,       // .zip
    TarXz,     // .tar.xz
    TarBz2     // .tar.bz2
}

/// Repository rule definition
struct RepositoryRule
{
    string name;                    // Repository name (used in @name// references)
    RepositoryKind kind;           // Source type
    string url;                     // URL or path
    string integrity;               // SHA256 hash for verification (hex or base64)
    ArchiveFormat format;          // Archive format (for HTTP)
    string stripPrefix;            // Strip this prefix from extracted paths
    string gitCommit;              // Git commit SHA (for Git repositories)
    string gitTag;                 // Git tag (alternative to commit)
    string[string] patches;        // Patches to apply after fetch (name -> content)
    
    /// Validate repository rule
    Result!RepositoryError validate() const @system
    {
        if (name.length == 0)
            return Result!RepositoryError.err(
                new RepositoryError("Repository name cannot be empty", Config.InvalidConfiguration));
        
        if (url.length == 0 && kind != RepositoryKind.Local)
            return Result!RepositoryError.err(
                new RepositoryError("Repository URL is required for " ~ kind.to!string, Config.InvalidConfiguration));
        
        if (kind == RepositoryKind.Http && integrity.length == 0)
            return Result!RepositoryError.err(
                new RepositoryError("Integrity hash is required for HTTP repositories", Config.InvalidConfiguration));
        
        if (kind == RepositoryKind.Git && gitCommit.length == 0 && gitTag.length == 0)
            return Result!RepositoryError.err(
                new RepositoryError("Git commit or tag is required for Git repositories", Config.InvalidConfiguration));
        
        return Ok!RepositoryError();
    }
    
    /// Get cache key for this repository
    string cacheKey() const pure @safe
    {
        import std.digest.sha : sha256Of, toHexString;
        import std.string : representation;
        
        // Cache key based on URL and integrity
        auto data = (url ~ integrity ~ gitCommit ~ gitTag).representation;
        return sha256Of(data).toHexString().idup;
    }
}

/// Cached repository metadata
struct CachedRepository
{
    string name;                    // Repository name
    string cacheKey;               // Cache key
    string localPath;              // Path in cache directory
    SysTime fetchedAt;             // When it was fetched
    size_t size;                   // Size in bytes
    string[] files;                // List of files (for dependency tracking)
    
    /// Check if cache entry is valid
    bool isValid() const @safe
    {
        import std.file : exists, isDir;
        return exists(localPath) && isDir(localPath);
    }
}

/// Repository resolution result
struct ResolvedRepository
{
    string name;                   // Repository name
    string path;                   // Absolute path to repository root
    RepositoryRule rule;          // Original rule
    
    /// Build full target path
    string buildTargetPath(string relativePath, string targetName) const pure @safe
    {
        import std.path : buildPath;
        if (relativePath.length == 0)
            return "@" ~ name ~ "//:" ~ targetName;
        return "@" ~ name ~ "//" ~ relativePath ~ ":" ~ targetName;
    }
}

/// Import errors module for RepositoryError
private import std.conv : to;
private import infrastructure.errors.types.types : BaseBuildError;
private import infrastructure.errors.codes : ErrorCode, ErrorCategory, Config, Repository;

/// Repository-specific error
final class RepositoryError : BaseBuildError
{
    this(string message, ErrorCode code = ErrorCode.RepositoryError,
         string file = __FILE__, size_t line = __LINE__) @trusted
    {
        super(code, message);
    }
}

