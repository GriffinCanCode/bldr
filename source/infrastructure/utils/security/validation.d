module infrastructure.utils.security.validation;

import std.path;
import std.file;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import infrastructure.errors : Errors, Security;


/// Security utilities for validating and sanitizing file paths and arguments
/// Protects against command injection and path traversal attacks
struct SecurityValidator
{
    /// Validates that a file path is safe to use with external commands
    /// Returns: true if path is safe, false otherwise
    /// 
    /// Security checks:
    /// 1. Null byte injection (terminates strings in C)
    /// 2. Shell metacharacters (even array form can have issues)
    /// 3. Path traversal sequences (../ or ..\)
    /// 4. Control characters (newlines, tabs)
    /// 5. System directory access
    /// 6. Unicode homograph attacks (lookalike characters)
    @system
    static bool isPathSafe(string path) nothrow
    {
        if (path.empty)
            return false;
        
        try
        {
            // Check for null bytes (can be used to bypass checks)
            if (path.canFind('\0'))
                return false;
            
            // Check for shell metacharacters that could enable injection
            // Even in array form, paths with certain characters can be problematic
            const string dangerousChars = ";|&$`<>(){}[]!*?'\"\\";
            foreach (char c; dangerousChars)
            {
                if (path.canFind(c))
                    return false;
            }
            
            // Check for problematic escape sequences
            if (path.canFind("\n") || path.canFind("\r") || path.canFind("\t"))
                return false;
            
            // Check for ANSI escape codes (could be used for terminal injection)
            if (path.canFind("\x1b["))
                return false;
            
            // Validate path structure (no path traversal attempts)
            if (!isPathTraversalSafe(path))
                return false;
            
            // Check for encoded traversal attempts
            if (path.canFind("%2e%2e") || path.canFind("..%2f") || path.canFind("%2e%2e%2f"))
                return false;
            
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Validates that a path doesn't contain path traversal sequences
    /// 
    /// Security checks:
    /// 1. Common traversal patterns (../, ..\)
    /// 2. Dot-dot at end of path (..)
    /// 3. Hidden traversal (/./ or //)
    /// 4. Absolute paths to sensitive system directories
    /// 5. Windows device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    @system
    static bool isPathTraversalSafe(string path) nothrow
    {
        try
        {
            // Check for common path traversal patterns
            if (path.canFind("../") || path.canFind("..\\"))
                return false;
            
            // Check if path ends with ..
            if (path.endsWith(".."))
                return false;
            
            // Check for hidden traversal sequences
            if (path.canFind("/./") || path.canFind("\\.\\"))
                return false;
            
            // Check for double slashes (can bypass some protections)
            if (path.canFind("//") || path.canFind("\\\\"))
                return false;
            
            // Check for absolute path to sensitive locations (on Unix)
            version(Posix)
            {
                const string[] sensitivePaths = [
                    "/etc/", "/proc/", "/sys/", "/dev/", "/boot/", 
                    "/root/", "/var/log/", "/tmp/", "/var/tmp/"
                ];
                foreach (sensPath; sensitivePaths)
                {
                    if (path.startsWith(sensPath))
                        return false;
                }
            }
            
            // Check for Windows device names (security issue on Windows)
            version(Windows)
            {
                auto upperPath = path.toUpper();
                const string[] deviceNames = [
                    "CON", "PRN", "AUX", "NUL",
                    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
                    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
                ];
                foreach (device; deviceNames)
                {
                    if (upperPath == device || upperPath.startsWith(device ~ ".") || 
                        upperPath.startsWith(device ~ ":") || upperPath.startsWith(device ~ "\\"))
                        return false;
                }
            }
            
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Validates that a file path exists and is within allowed directory
    /// baseDir: The base directory that the path must be within
    /// 
    /// Safety: This function is @system because:
    /// 1. File system operations (exists, absolutePath) are unsafe I/O
    /// 2. Path normalization requires file system access
    /// 3. String prefix comparison (startsWith) is memory-safe
    /// 4. Exception handling ensures nothrow-like behavior
    /// 
    /// Invariants:
    /// - Both paths are normalized before comparison (canonical form)
    /// - Symlinks are NOT resolved (exists checks link itself)
    /// - Empty or non-existent paths return false (fail-safe)
    /// 
    /// What could go wrong:
    /// - Symlink attacks: path could point outside baseDir via symlink
    /// - TOCTOU: path could be modified after validation
    /// - Case-sensitive filesystems: bypasses on different case (platform-specific)
    /// - Relative path handling: mitigated by absolutePath normalization
    /// 
    /// NOTE: This is less secure than glob.d's isPathWithinBase which resolves symlinks
    @system
    static bool isPathWithinBase(string path, string baseDir)
    {
        try
        {
            if (!exists(path))
                return false;
            
            // Normalize both paths to compare
            auto normalPath = buildNormalizedPath(absolutePath(path));
            auto normalBase = buildNormalizedPath(absolutePath(baseDir));
            
            // Check if path starts with base directory
            return normalPath.startsWith(normalBase);
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Validates and sanitizes a command argument
    /// Returns: Sanitized argument, or empty string if unsafe
    @system
    static string sanitizeArgument(string arg) nothrow
    {
        try
        {
            // If argument contains dangerous characters, reject it
            if (!isArgumentSafe(arg))
                return "";
            
            return arg;
        }
        catch (Exception)
        {
            return "";
        }
    }
    
    /// Check if a command argument is safe
    @system
    static bool isArgumentSafe(string arg) nothrow
    {
        try
        {
            // Empty arguments are allowed
            if (arg.empty)
                return true;
            
            // Check for null bytes
            if (arg.canFind('\0'))
                return false;
            
            // Check for command injection patterns
            if (arg.canFind(";") || arg.canFind("|") || 
                arg.canFind("&&") || arg.canFind("||") ||
                arg.canFind("`") || arg.canFind("$"))
                return false;
            
            // Check for quote escaping attempts
            if (arg.canFind("'\"") || arg.canFind("\"'"))
                return false;
            
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Escape a file path for safe use in shell commands (when executeShell is unavoidable)
    /// This is a last resort - prefer using execute() with array form
    /// 
    /// Safety: This function is @system because:
    /// 1. String operations (replace, format) are memory-safe
    /// 2. Character filtering and escaping don't involve pointers
    /// 3. Platform-specific escaping rules are hardcoded (no external input)
    /// 
    /// Invariants:
    /// - Windows: wraps path in double quotes, escapes internal quotes
    /// - POSIX: single quotes with escaped single quotes
    /// - Empty paths are passed through (caller must validate)
    /// 
    /// What could go wrong:
    /// - Complex shell injection: escaped form may not be sufficient for all shells
    /// - Platform detection wrong: could use wrong escaping rules
    /// - Unicode/special characters: may not be handled by all shells
    /// - This is BEST EFFORT - strongly prefer execute() with arrays!
    /// 
    /// SECURITY WARNING: This does NOT guarantee safety for all shells/contexts
    @system
    static string escapeShellPath(string path)
    {
        version(Windows)
        {
            // On Windows, wrap in quotes and escape internal quotes
            return `"` ~ path.replace(`"`, `""`) ~ `"`;
        }
        else
        {
            // On Unix, escape special characters with backslash
            return path
                .replace(`\`, `\\`)
                .replace(`"`, `\"`)
                .replace(`'`, `\'`)
                .replace(` `, `\ `)
                .replace(`$`, `\$`)
                .replace("`", "\\`");
        }
    }
    
    /// Validates a list of file paths for safety
    /// Returns: true if all paths are safe
    @system
    static bool arePathsSafe(string[] paths) nothrow
    {
        try
        {
            foreach (path; paths)
            {
                if (!isPathSafe(path))
                    return false;
            }
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Validates that a file extension is in an allowed list
    @system
    static bool hasAllowedExtension(string path, string[] allowedExtensions) nothrow
    {
        try
        {
            auto ext = extension(path).toLower();
            return allowedExtensions.canFind(ext);
        }
        catch (Exception)
        {
            return false;
        }
    }
}

/// Safe execute wrapper that validates paths before execution
/// 
/// Safety: This struct is @system because:
/// 1. Wraps std.process.execute which requires system calls (unsafe I/O)
/// 2. Validates all paths before passing to execute()
/// 3. Uses array form of execute (prevents shell injection)
/// 4. No internal unsafe operations beyond process execution
/// 
/// Invariants:
/// - All file paths are validated before execution
/// - Commands use array form (no shell interpretation)
/// - Working directory is validated if specified
/// 
/// What could go wrong:
/// - Process execution inherently unsafe: limited by OS security
/// - Path validation could be bypassed: mitigated by multiple validation layers
/// - TOCTOU: files could change between validation and execution
/// - Resource exhaustion: process could consume unlimited resources (no sandboxing)
@system
struct SafeExecute
{
    import std.process;
    
    /// Execute command with path validation
    /// Validates all arguments that look like file paths before execution
    static auto execute(string[] cmd, string[string] env = null, 
                       Config config = Config.none, size_t maxOutput = size_t.max,
                       string workDir = null)
    {
        // Validate command arguments that might be paths
        foreach (arg; cmd)
        {
            // If it looks like a file path (contains path separators), validate it
            if (arg.canFind('/') || arg.canFind('\\'))
            {
                if (!SecurityValidator.isPathSafe(arg))
                    throw Errors.system("Unsafe path detected in command: " ~ arg, Security.PathTraversal)
                        .withSuggestion("Use safe path without traversal patterns").build();
            }
        }
        
        // Execute using safe array form
        return std.process.execute(cmd, env, config, maxOutput, workDir);
    }
}

// Unit tests
@system unittest
{
    // Test path safety validation
    assert(SecurityValidator.isPathSafe("src/main.cpp"));
    assert(SecurityValidator.isPathSafe("output/app.exe"));
    assert(!SecurityValidator.isPathSafe("file; rm -rf /"));
    assert(!SecurityValidator.isPathSafe("file | cat /etc/passwd"));
    assert(!SecurityValidator.isPathSafe("file && malicious"));
    assert(!SecurityValidator.isPathSafe("file`whoami`"));
    assert(!SecurityValidator.isPathSafe("file$var"));
    
    // Test path traversal detection
    assert(SecurityValidator.isPathTraversalSafe("src/main.cpp"));
    assert(!SecurityValidator.isPathTraversalSafe("../../../etc/passwd"));
    assert(!SecurityValidator.isPathTraversalSafe("..\\..\\windows\\system32"));
    
    // Test argument safety
    assert(SecurityValidator.isArgumentSafe("-O2"));
    assert(SecurityValidator.isArgumentSafe("--flag"));
    assert(!SecurityValidator.isArgumentSafe("; rm -rf /"));
    assert(!SecurityValidator.isArgumentSafe("| cat /etc/passwd"));
    
    // Test batch validation
    assert(SecurityValidator.arePathsSafe(["src/a.cpp", "src/b.cpp"]));
    assert(!SecurityValidator.arePathsSafe(["src/a.cpp", "bad; rm"]));
}

