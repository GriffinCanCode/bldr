module languages.base.types;

/// Standard error codes for build failures
enum BuildErrorCode
{
    None = 0,
    
    // Configuration errors (100-199)
    ConfigParseFailed = 100,
    ConfigValidationFailed = 101,
    MissingRequiredConfig = 102,
    InvalidConfigValue = 103,
    
    // Tool/compiler errors (200-299)
    CompilerNotFound = 200,
    CompilerVersionMismatch = 201,
    ToolkitNotFound = 202,
    LinkerNotFound = 203,
    RuntimeNotFound = 204,
    
    // Source errors (300-399)
    NoSourceFiles = 300,
    SourceNotFound = 301,
    SourceReadFailed = 302,
    InvalidSourceType = 303,
    
    // Compilation errors (400-499)
    CompilationFailed = 400,
    SyntaxError = 401,
    TypeCheckFailed = 402,
    LinkFailed = 403,
    ArchitectureMismatch = 404,
    
    // Dependency errors (500-599)
    DependencyNotFound = 500,
    DependencyVersionConflict = 501,
    DependencyInstallFailed = 502,
    CircularDependency = 503,
    
    // Test errors (600-699)
    TestsFailed = 600,
    TestTimeout = 601,
    TestSetupFailed = 602,
    
    // Resource errors (700-799)
    OutOfMemory = 700,
    DiskFull = 701,
    PermissionDenied = 702,
    Timeout = 703,
    
    // Internal errors (900-999)
    InternalError = 900,
    NotImplemented = 901,
    Cancelled = 902
}

/// Build phase for progress reporting
enum BuildPhase
{
    Initializing,
    Configuring,
    DependencyResolution,
    Compiling,
    Linking,
    Testing,
    Packaging,
    Finalizing,
    Complete
}

/// Verbosity level for output
enum Verbosity
{
    Quiet = 0,    // Errors only
    Normal = 1,   // Errors + warnings + summary
    Verbose = 2,  // Above + info
    Debug = 3     // Everything
}

/// Optimization level (universal across compiled languages)
enum OptLevel
{
    O0,    // No optimization
    O1,    // Basic
    O2,    // Standard (default)
    O3,    // Aggressive
    Os,    // Size
    Oz,    // Size aggressive
    Ofast, // Fast (may break IEEE)
    Og     // Debug-friendly
}

/// LTO mode (universal)
enum LtoMode { Off, Thin, Full }

/// Warning level (universal)
enum WarningLevel { None, Default, Extra, All, Pedantic, Error }

/// Sanitizer types (shared across C++, Rust, Zig, etc.)
enum Sanitizer
{
    None,
    Address,
    Thread,
    Memory,
    UndefinedBehavior,
    Leak,
    HWAddress
}

/// Output type for compiled targets
enum OutputType
{
    Executable,
    StaticLib,
    SharedLib,
    Object,
    HeaderOnly
}

/// Cross-compilation configuration (universal)
struct CrossCompileConfig
{
    string targetTriple;  // e.g., x86_64-linux-gnu
    string arch;          // Target architecture
    string os;            // Target OS
    string sysroot;       // Sysroot path
    string prefix;        // Toolchain prefix
    
    bool isCross() const pure nothrow => !targetTriple.empty || !arch.empty || !os.empty;
    
    string[string] toEnv() const
    {
        string[string] env;
        if (!targetTriple.empty) env["TARGET"] = targetTriple;
        if (!arch.empty) env["GOARCH"] = arch; // Works for Go, others use different names
        if (!os.empty) env["GOOS"] = os;
        return env;
    }
}

/// Progress callback for build status updates
alias ProgressCallback = void delegate(BuildPhase phase, float progress, string message);

/// Build metrics collected during execution
struct BuildMetrics
{
    import core.time : Duration;
    
    Duration totalTime;
    Duration compileTime;
    Duration linkTime;
    Duration testTime;
    
    size_t filesCompiled;
    size_t filesFromCache;
    size_t totalFiles;
    
    size_t warningCount;
    size_t errorCount;
    
    size_t outputSizeBytes;
    
    /// Cache hit rate as percentage
    float cacheHitRate() const pure nothrow
    {
        if (totalFiles == 0) return 0.0f;
        return cast(float)filesFromCache / cast(float)totalFiles * 100.0f;
    }
}

/// Unified build result with error codes, metrics, and artifacts
struct UnifiedBuildResult
{
    bool success;
    string error;
    BuildErrorCode errorCode = BuildErrorCode.None;
    
    string[] outputs;      // Primary outputs
    string[] artifacts;    // Secondary artifacts (debug info, maps, etc.)
    string outputHash;     // Content hash for caching
    
    string[] warnings;
    string[] diagnostics;  // Compiler diagnostics
    
    BuildMetrics metrics;
    
    /// Create success result
    static UnifiedBuildResult ok(string[] outputs, string hash)
    {
        UnifiedBuildResult r;
        r.success = true;
        r.outputs = outputs;
        r.outputHash = hash;
        return r;
    }
    
    /// Create error result
    static UnifiedBuildResult err(string message, BuildErrorCode code = BuildErrorCode.InternalError)
    {
        UnifiedBuildResult r;
        r.success = false;
        r.error = message;
        r.errorCode = code;
        return r;
    }
    
    /// Add warning
    void addWarning(string warning) { warnings ~= warning; }
    
    /// Add diagnostic
    void addDiagnostic(string diag) { diagnostics ~= diag; }
}

/// Compile result for individual files
struct CompileFileResult
{
    bool success;
    string error;
    string sourceFile;
    string objectFile;
    string[] dependencies;
    bool fromCache;
    string[] warnings;
}

/// Link result
struct LinkResult
{
    bool success;
    string error;
    string output;
    string outputHash;
    string[] warnings;
}

