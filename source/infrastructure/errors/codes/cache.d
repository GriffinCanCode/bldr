module infrastructure.errors.codes.cache;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Cache operation error codes (4000-4499)
/// Covers local cache, remote cache, and cache management
enum Cache : int
{
    /// Failed to load from cache
    LoadFailed = 4000,
    /// Failed to save to cache
    SaveFailed = 4001,
    /// Cache data is corrupted
    Corrupted = 4002,
    /// Cache eviction failed
    EvictionFailed = 4003,
    /// Artifact not found in cache
    NotFound = 4004,
    /// Remote cache not configured
    Disabled = 4005,
    /// Cache authentication failed
    Unauthorized = 4006,
    /// Artifact exceeds size limit
    TooLarge = 4007,
    /// Cache operation timed out
    Timeout = 4008,
    /// Failed to write to cache
    WriteFailed = 4009,
    /// Cache locked by another process
    InUse = 4010,
    /// Failed to delete cache entry
    DeleteFailed = 4011,
    /// Cache garbage collection failed
    GCFailed = 4012,
    /// Hash verification failed
    HashMismatch = 4013,
    /// Cache directory not accessible
    DirectoryInaccessible = 4014,
    /// Cache index corrupted
    IndexCorrupted = 4015,
    /// Compression/decompression failed
    CompressionFailed = 4016,
    /// Cache quota exceeded
    QuotaExceeded = 4017,
    /// Remote cache unavailable
    RemoteUnavailable = 4018,
    /// Cache protocol error
    ProtocolError = 4019,
    /// Invalid cache key
    InvalidKey = 4020,
    /// Cache entry expired
    Expired = 4021,
    /// Concurrent modification detected
    ConcurrentModification = 4022,
    /// Blob not found in CAS
    BlobNotFound = 4023,
    /// Deduplication failed
    DedupFailed = 4024,
}

/// Namespace for cache error utilities
struct CacheErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Cache; }
    
    static Recoverability recoverabilityOf(Cache code) pure nothrow @nogc
    {
        switch (code)
        {
            case Cache.LoadFailed:
            case Cache.EvictionFailed:
            case Cache.Timeout:
            case Cache.WriteFailed:
            case Cache.DeleteFailed:
            case Cache.InUse:
            case Cache.RemoteUnavailable:
            case Cache.ConcurrentModification:
                return Recoverability.Transient;
            case Cache.Disabled:
            case Cache.Unauthorized:
            case Cache.TooLarge:
            case Cache.QuotaExceeded:
            case Cache.InvalidKey:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Cache code) pure nothrow @safe
    {
        final switch (code)
        {
            case Cache.LoadFailed:          return "Failed to load cache";
            case Cache.SaveFailed:          return "Failed to save cache";
            case Cache.Corrupted:           return "Cache data corrupted";
            case Cache.EvictionFailed:      return "Cache eviction failed";
            case Cache.NotFound:            return "Artifact not found in cache";
            case Cache.Disabled:            return "Remote cache not configured";
            case Cache.Unauthorized:        return "Cache authentication failed";
            case Cache.TooLarge:            return "Artifact exceeds maximum size";
            case Cache.Timeout:             return "Cache operation timed out";
            case Cache.WriteFailed:         return "Failed to write to cache";
            case Cache.InUse:               return "Cache in use by another process";
            case Cache.DeleteFailed:        return "Failed to delete cache entry";
            case Cache.GCFailed:            return "Cache garbage collection failed";
            case Cache.HashMismatch:        return "Cache hash verification failed";
            case Cache.DirectoryInaccessible: return "Cache directory not accessible";
            case Cache.IndexCorrupted:      return "Cache index corrupted";
            case Cache.CompressionFailed:   return "Cache compression failed";
            case Cache.QuotaExceeded:       return "Cache quota exceeded";
            case Cache.RemoteUnavailable:   return "Remote cache unavailable";
            case Cache.ProtocolError:       return "Cache protocol error";
            case Cache.InvalidKey:          return "Invalid cache key";
            case Cache.Expired:             return "Cache entry expired";
            case Cache.ConcurrentModification: return "Concurrent cache modification";
            case Cache.BlobNotFound:        return "Blob not found in CAS";
            case Cache.DedupFailed:         return "Deduplication failed";
        }
    }
}

