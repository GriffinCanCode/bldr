module infrastructure.errors.codes.io;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// I/O and file system error codes (5000-5999)
/// Covers file operations, directories, permissions, and paths
enum IO : int
{
    /// File not found
    FileNotFound = 5000,
    /// Failed to read file
    FileReadFailed = 5001,
    /// Failed to write file
    FileWriteFailed = 5002,
    /// Failed to delete file
    FileDeleteFailed = 5003,
    /// Directory not found
    DirectoryNotFound = 5004,
    /// Permission denied
    PermissionDenied = 5005,
    /// Failed to create directory
    DirectoryCreateFailed = 5006,
    /// Failed to delete directory
    DirectoryDeleteFailed = 5007,
    /// File already exists
    FileExists = 5008,
    /// Directory already exists
    DirectoryExists = 5009,
    /// Path is not a file
    NotAFile = 5010,
    /// Path is not a directory
    NotADirectory = 5011,
    /// Path too long
    PathTooLong = 5012,
    /// Invalid path characters
    InvalidPath = 5013,
    /// File is locked
    FileLocked = 5014,
    /// Disk full
    DiskFull = 5015,
    /// Symbolic link error
    SymlinkError = 5016,
    /// Failed to copy file
    CopyFailed = 5017,
    /// Failed to move/rename file
    MoveFailed = 5018,
    /// Failed to get file stats
    StatFailed = 5019,
    /// File modified unexpectedly
    FileModified = 5020,
    /// File truncated
    FileTruncated = 5021,
    /// Temporary file error
    TempFileError = 5022,
    /// Atomic write failed
    AtomicWriteFailed = 5023,
    /// Too many open files
    TooManyOpenFiles = 5024,
    /// File system read-only
    ReadOnlyFileSystem = 5025,
    /// Cross-device link
    CrossDeviceLink = 5026,
}

/// Namespace for I/O error utilities
struct IOErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.IO; }
    
    static Recoverability recoverabilityOf(IO code) pure nothrow @nogc
    {
        switch (code)
        {
            case IO.FileLocked:
            case IO.TooManyOpenFiles:
            case IO.FileModified:
                return Recoverability.Transient;
            case IO.FileNotFound:
            case IO.DirectoryNotFound:
            case IO.PermissionDenied:
            case IO.InvalidPath:
            case IO.PathTooLong:
            case IO.ReadOnlyFileSystem:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(IO code) pure nothrow @safe
    {
        final switch (code)
        {
            case IO.FileNotFound:         return "File not found";
            case IO.FileReadFailed:       return "Failed to read file";
            case IO.FileWriteFailed:      return "Failed to write file";
            case IO.FileDeleteFailed:     return "Failed to delete file";
            case IO.DirectoryNotFound:    return "Directory not found";
            case IO.PermissionDenied:     return "Permission denied";
            case IO.DirectoryCreateFailed: return "Failed to create directory";
            case IO.DirectoryDeleteFailed: return "Failed to delete directory";
            case IO.FileExists:           return "File already exists";
            case IO.DirectoryExists:      return "Directory already exists";
            case IO.NotAFile:             return "Path is not a file";
            case IO.NotADirectory:        return "Path is not a directory";
            case IO.PathTooLong:          return "Path too long";
            case IO.InvalidPath:          return "Invalid path";
            case IO.FileLocked:           return "File is locked";
            case IO.DiskFull:             return "Disk full";
            case IO.SymlinkError:         return "Symbolic link error";
            case IO.CopyFailed:           return "Failed to copy file";
            case IO.MoveFailed:           return "Failed to move file";
            case IO.StatFailed:           return "Failed to get file stats";
            case IO.FileModified:         return "File modified unexpectedly";
            case IO.FileTruncated:        return "File truncated";
            case IO.TempFileError:        return "Temporary file error";
            case IO.AtomicWriteFailed:    return "Atomic write failed";
            case IO.TooManyOpenFiles:     return "Too many open files";
            case IO.ReadOnlyFileSystem:   return "Read-only file system";
            case IO.CrossDeviceLink:      return "Cross-device link";
        }
    }
}

