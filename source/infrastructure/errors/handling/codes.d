module infrastructure.errors.handling.codes;

import std.conv;

/// Error category hierarchy for systematic classification
enum ErrorCategory
{
    Build,      // Build execution errors
    Parse,      // Configuration parsing errors
    Analysis,   // Dependency analysis errors
    Cache,      // Cache operation errors
    IO,         // File system errors
    Graph,      // Dependency graph errors
    Language,   // Language handler errors
    System,     // System-level errors
    Internal,   // Internal/unexpected errors
    Plugin,     // Plugin system errors
    LSP,        // LSP server errors
    Watch,      // Watch mode errors
    Config      // Configuration/Validation errors
}

/// Recoverability classification for error handling strategies
enum Recoverability
{
    /// Fatal errors - cannot be recovered, must fail the build
    Fatal,
    
    /// Transient errors - temporary failures that can be retried
    /// Examples: network timeouts, cache unavailable, process timeout
    Transient,
    
    /// User errors - incorrect configuration or usage
    /// Examples: invalid syntax, missing file, unknown target
    User
}

/// Specific error codes for programmatic handling
enum ErrorCode
{
    // General errors (0-999)
    UnknownError = 0,
    
    // Build errors (1000-1999)
    BuildFailed = 1000,
    BuildTimeout,
    BuildCancelled,
    TargetNotFound,
    HandlerNotFound,
    OutputMissing,
    
    // Parse errors (2000-2999)
    ParseFailed = 2000,
    InvalidJson,
    InvalidBuildFile,
    MissingField,
    InvalidFieldValue,
    InvalidGlob,
    InvalidConfiguration,
    
    // Analysis errors (3000-3999)
    AnalysisFailed = 3000,
    ImportResolutionFailed,
    CircularDependency,
    MissingDependency,
    InvalidImport,
    
    // Cache errors (4000-4999)
    CacheLoadFailed = 4000,
    CacheSaveFailed,
    CacheCorrupted,
    CacheEvictionFailed,
    CacheNotFound,
    CacheDisabled,
    CacheUnauthorized,
    CacheTooLarge,
    CacheTimeout,
    CacheWriteFailed,
    CacheInUse,
    CacheDeleteFailed,
    CacheGCFailed,
    NetworkError,
    
    // Repository errors (4500-4599)
    RepositoryError = 4500,
    RepositoryNotFound,
    RepositoryFetchFailed,
    RepositoryVerificationFailed,
    VerificationFailed,
    RepositoryInvalid,
    RepositoryTimeout,
    RepositoryAlreadyAdded,
    
    // IO errors (5000-5999)
    FileNotFound = 5000,
    FileReadFailed,
    FileWriteFailed,
    FileDeleteFailed,
    DirectoryNotFound,
    PermissionDenied,
    
    // Graph errors (6000-6999)
    GraphCycle = 6000,
    GraphInvalid,
    NodeNotFound,
    EdgeInvalid,
    
    // Language errors (7000-7999)
    SyntaxError = 7000,
    CompilationFailed,
    ValidationFailed,
    UnsupportedLanguage,
    MissingCompiler,
    MacroExpansionFailed,
    MacroLoadFailed,
    
    // System errors (8000-8999)
    ProcessSpawnFailed = 8000,
    ProcessTimeout,
    ProcessCrashed,
    OutOfMemory,
    ThreadPoolError,
    
    // Internal errors (9000-9999)
    InternalError = 9000,
    NotImplemented,
    AssertionFailed,
    UnreachableCode,
    InitializationFailed,
    NotInitialized,
    NotSupported,
    
    // Telemetry errors (10000-10999)
    TelemetryNoSession = 10000,
    TelemetryStorage,
    TelemetryInvalid,
    
    // Tracing errors (11000-11999)
    TraceInvalidFormat = 11000,
    TraceNoActiveSpan,
    TraceExportFailed,
    
    // Distributed build errors (12000-12999)
    DistributedError = 12000,
    CoordinatorNotFound,
    CoordinatorTimeout,
    WorkerTimeout,
    WorkerFailed,
    ActionSchedulingFailed,
    SandboxError,
    ArtifactTransferFailed,
    
    // Plugin errors (13000-13999)
    PluginError = 13000,
    PluginNotFound,
    PluginLoadFailed,
    PluginCrashed,
    PluginTimeout,
    PluginInvalidResponse,
    PluginProtocolError,
    PluginVersionMismatch,
    PluginCapabilityMissing,
    PluginValidationFailed,
    PluginExecutionFailed,
    InvalidMessage,
    ToolNotFound,
    IncompatibleVersion,
    
    // LSP errors (14000-14999)
    LSPError = 14000,
    LSPInitializationFailed,
    LSPInvalidRequest,
    LSPMethodNotFound,
    LSPInvalidParams,
    LSPDocumentNotFound,
    LSPParseError,
    LSPServerCrashed,
    LSPTimeout,
    LSPInvalidPosition,
    LSPWorkspaceNotInitialized,
    
    // Watch mode errors (15000-15999)
    WatchError = 15000,
    WatcherInitFailed,
    WatcherNotSupported,
    WatcherCrashed,
    FileWatchFailed,
    DebounceError,
    TooManyWatchTargets,
    
    // Configuration/Validation errors (16000-16999)
    ConfigError = 16000,
    InvalidWorkspace,
    InvalidTarget,
    InvalidInput,
    SchemaValidationFailed,
    DeprecatedField,
    RequiredFieldMissing,
    DuplicateTarget,
    ConfigConflict,
    
    // Migration errors (17000-17999)
    MigrationFailed = 17000
}

/// Get error category from error code using optimized lookup
ErrorCategory categoryOf(ErrorCode code) pure nothrow @nogc
{
    static immutable ErrorCategory[18] categories = [
        ErrorCategory.Internal, // 0
        ErrorCategory.Build,    // 1
        ErrorCategory.Parse,    // 2
        ErrorCategory.Analysis, // 3
        ErrorCategory.Cache,    // 4
        ErrorCategory.IO,       // 5
        ErrorCategory.Graph,    // 6
        ErrorCategory.Language, // 7
        ErrorCategory.System,   // 8
        ErrorCategory.Internal, // 9
        ErrorCategory.Internal, // 10 Telemetry
        ErrorCategory.Internal, // 11 Tracing
        ErrorCategory.System,   // 12 Distributed
        ErrorCategory.Plugin,   // 13 Plugin
        ErrorCategory.LSP,      // 14 LSP
        ErrorCategory.Watch,    // 15 Watch
        ErrorCategory.Config,   // 16 Config
        ErrorCategory.Parse     // 17 Migration
    ];
    immutable idx = code / 1000;
    return idx < categories.length ? categories[idx] : ErrorCategory.Internal;
}

/// Get recoverability classification for error code
Recoverability recoverabilityOf(ErrorCode code) pure nothrow @nogc
{
    static immutable Recoverability[ErrorCode] recoverabilityMap = [
        // Transient errors (can be retried)
        ErrorCode.BuildTimeout: Recoverability.Transient,
        ErrorCode.CacheLoadFailed: Recoverability.Transient,
        ErrorCode.CacheEvictionFailed: Recoverability.Transient,
        ErrorCode.CacheTimeout: Recoverability.Transient,
        ErrorCode.NetworkError: Recoverability.Transient,
        ErrorCode.ProcessTimeout: Recoverability.Transient,
        ErrorCode.CoordinatorTimeout: Recoverability.Transient,
        ErrorCode.WorkerTimeout: Recoverability.Transient,
        ErrorCode.ArtifactTransferFailed: Recoverability.Transient,
        ErrorCode.PluginTimeout: Recoverability.Transient,
        ErrorCode.LSPTimeout: Recoverability.Transient,
        ErrorCode.WatcherCrashed: Recoverability.Transient,
        ErrorCode.FileWatchFailed: Recoverability.Transient,
        ErrorCode.RepositoryFetchFailed: Recoverability.Transient,
        ErrorCode.CacheWriteFailed: Recoverability.Transient,
        ErrorCode.CacheDeleteFailed: Recoverability.Transient,
        ErrorCode.CacheInUse: Recoverability.Transient,
        ErrorCode.RepositoryTimeout: Recoverability.Transient,
        
        // User errors (invalid usage or configuration)
        ErrorCode.ParseFailed: Recoverability.User,
        ErrorCode.InvalidJson: Recoverability.User,
        ErrorCode.InvalidBuildFile: Recoverability.User,
        ErrorCode.MissingField: Recoverability.User,
        ErrorCode.InvalidFieldValue: Recoverability.User,
        ErrorCode.InvalidGlob: Recoverability.User,
        ErrorCode.InvalidConfiguration: Recoverability.User,
        ErrorCode.TargetNotFound: Recoverability.User,
        ErrorCode.HandlerNotFound: Recoverability.User,
        ErrorCode.FileNotFound: Recoverability.User,
        ErrorCode.DirectoryNotFound: Recoverability.User,
        ErrorCode.PermissionDenied: Recoverability.User,
        ErrorCode.CircularDependency: Recoverability.User,
        ErrorCode.MissingDependency: Recoverability.User,
        ErrorCode.InvalidImport: Recoverability.User,
        ErrorCode.SyntaxError: Recoverability.User,
        ErrorCode.UnsupportedLanguage: Recoverability.User,
        ErrorCode.MissingCompiler: Recoverability.User,
        ErrorCode.InvalidWorkspace: Recoverability.User,
        ErrorCode.InvalidTarget: Recoverability.User,
        ErrorCode.InvalidInput: Recoverability.User,
        ErrorCode.SchemaValidationFailed: Recoverability.User,
        ErrorCode.RequiredFieldMissing: Recoverability.User,
        ErrorCode.DuplicateTarget: Recoverability.User,
        ErrorCode.ConfigConflict: Recoverability.User,
        ErrorCode.CacheDisabled: Recoverability.User,
        ErrorCode.CacheUnauthorized: Recoverability.User,
        ErrorCode.CacheTooLarge: Recoverability.User,
        ErrorCode.PluginNotFound: Recoverability.User,
        ErrorCode.PluginVersionMismatch: Recoverability.User,
        ErrorCode.PluginCapabilityMissing: Recoverability.User,
        ErrorCode.ToolNotFound: Recoverability.User,
        ErrorCode.IncompatibleVersion: Recoverability.User,
        ErrorCode.LSPInvalidRequest: Recoverability.User,
        ErrorCode.LSPInvalidParams: Recoverability.User,
        ErrorCode.LSPDocumentNotFound: Recoverability.User,
        ErrorCode.LSPInvalidPosition: Recoverability.User,
        ErrorCode.LSPWorkspaceNotInitialized: Recoverability.User,
        ErrorCode.WatcherNotSupported: Recoverability.User,
        ErrorCode.TooManyWatchTargets: Recoverability.User,
        ErrorCode.DeprecatedField: Recoverability.User,
        ErrorCode.RepositoryNotFound: Recoverability.User,
        ErrorCode.RepositoryInvalid: Recoverability.User,
        ErrorCode.RepositoryAlreadyAdded: Recoverability.User,
        ErrorCode.CoordinatorNotFound: Recoverability.User,
        
        // All other errors are Fatal by default
    ];
    
    auto result = code in recoverabilityMap;
    return result ? *result : Recoverability.Fatal;
}

/// Check if error is recoverable (transient, can be retried)
bool isRecoverable(ErrorCode code) pure nothrow @nogc
{
    return recoverabilityOf(code) == Recoverability.Transient;
}

/// Get human-readable error message template using optimized lookup
string messageTemplate(ErrorCode code) pure nothrow
{
    static immutable string[ErrorCode] messages = [
        ErrorCode.UnknownError: "Unknown error",
        ErrorCode.BuildFailed: "Build failed",
        ErrorCode.BuildTimeout: "Build timed out",
        ErrorCode.BuildCancelled: "Build was cancelled",
        ErrorCode.TargetNotFound: "Target not found",
        ErrorCode.HandlerNotFound: "Language handler not found",
        ErrorCode.OutputMissing: "Expected output not found",
        ErrorCode.ParseFailed: "Failed to parse configuration",
        ErrorCode.InvalidJson: "Invalid JSON syntax",
        ErrorCode.InvalidBuildFile: "Invalid Builderfile",
        ErrorCode.MissingField: "Required field missing",
        ErrorCode.InvalidFieldValue: "Invalid field value",
        ErrorCode.InvalidGlob: "Invalid glob pattern",
        ErrorCode.AnalysisFailed: "Dependency analysis failed",
        ErrorCode.ImportResolutionFailed: "Failed to resolve import",
        ErrorCode.CircularDependency: "Circular dependency detected",
        ErrorCode.MissingDependency: "Dependency not found",
        ErrorCode.InvalidImport: "Invalid import statement",
        ErrorCode.CacheLoadFailed: "Failed to load cache",
        ErrorCode.CacheSaveFailed: "Failed to save cache",
        ErrorCode.CacheCorrupted: "Cache data corrupted",
        ErrorCode.CacheEvictionFailed: "Cache eviction failed",
        ErrorCode.CacheNotFound: "Artifact not found in cache",
        ErrorCode.CacheDisabled: "Remote cache not configured",
        ErrorCode.CacheUnauthorized: "Cache authentication failed",
        ErrorCode.CacheTooLarge: "Artifact exceeds maximum size",
        ErrorCode.CacheTimeout: "Cache operation timed out",
        ErrorCode.CacheWriteFailed: "Failed to write to cache",
        ErrorCode.CacheInUse: "Cache is in use by another process",
        ErrorCode.CacheDeleteFailed: "Failed to delete cache entry",
        ErrorCode.CacheGCFailed: "Cache garbage collection failed",
        ErrorCode.NetworkError: "Network communication error",
        ErrorCode.RepositoryError: "Repository operation failed",
        ErrorCode.RepositoryNotFound: "Repository not found",
        ErrorCode.RepositoryFetchFailed: "Failed to fetch repository",
        ErrorCode.RepositoryVerificationFailed: "Repository verification failed",
        ErrorCode.VerificationFailed: "Verification failed",
        ErrorCode.RepositoryInvalid: "Invalid repository",
        ErrorCode.RepositoryTimeout: "Repository operation timed out",
        ErrorCode.RepositoryAlreadyAdded: "Repository already added",
        ErrorCode.FileNotFound: "File not found",
        ErrorCode.FileReadFailed: "Failed to read file",
        ErrorCode.FileWriteFailed: "Failed to write file",
        ErrorCode.FileDeleteFailed: "Failed to delete file",
        ErrorCode.DirectoryNotFound: "Directory not found",
        ErrorCode.PermissionDenied: "Permission denied",
        ErrorCode.GraphCycle: "Dependency cycle detected",
        ErrorCode.GraphInvalid: "Invalid dependency graph",
        ErrorCode.NodeNotFound: "Graph node not found",
        ErrorCode.EdgeInvalid: "Invalid graph edge",
        ErrorCode.SyntaxError: "Syntax error",
        ErrorCode.CompilationFailed: "Compilation failed",
        ErrorCode.ValidationFailed: "Validation failed",
        ErrorCode.UnsupportedLanguage: "Unsupported language",
        ErrorCode.MissingCompiler: "Compiler not found",
        ErrorCode.MacroExpansionFailed: "Macro expansion failed",
        ErrorCode.MacroLoadFailed: "Failed to load macro",
        ErrorCode.ProcessSpawnFailed: "Failed to spawn process",
        ErrorCode.ProcessTimeout: "Process timed out",
        ErrorCode.ProcessCrashed: "Process crashed",
        ErrorCode.OutOfMemory: "Out of memory",
        ErrorCode.ThreadPoolError: "Thread pool error",
        ErrorCode.InternalError: "Internal error",
        ErrorCode.NotImplemented: "Not implemented",
        ErrorCode.AssertionFailed: "Assertion failed",
        ErrorCode.UnreachableCode: "Unreachable code reached",
        ErrorCode.InitializationFailed: "Initialization failed",
        ErrorCode.NotInitialized: "Component not initialized",
        ErrorCode.NotSupported: "Operation not supported",
        ErrorCode.TelemetryNoSession: "No active telemetry session",
        ErrorCode.TelemetryStorage: "Telemetry storage error",
        ErrorCode.TelemetryInvalid: "Invalid telemetry data",
        ErrorCode.TraceInvalidFormat: "Invalid trace format",
        ErrorCode.TraceNoActiveSpan: "No active span",
        ErrorCode.TraceExportFailed: "Trace export failed",
        ErrorCode.DistributedError: "Distributed build error",
        ErrorCode.CoordinatorNotFound: "Build coordinator not found",
        ErrorCode.CoordinatorTimeout: "Coordinator connection timeout",
        ErrorCode.WorkerTimeout: "Worker timeout",
        ErrorCode.WorkerFailed: "Worker failure",
        ErrorCode.ActionSchedulingFailed: "Failed to schedule action",
        ErrorCode.SandboxError: "Sandbox execution error",
        ErrorCode.ArtifactTransferFailed: "Artifact transfer failed",
        ErrorCode.PluginError: "Plugin error",
        ErrorCode.PluginNotFound: "Plugin not found",
        ErrorCode.PluginLoadFailed: "Failed to load plugin",
        ErrorCode.PluginCrashed: "Plugin crashed",
        ErrorCode.PluginTimeout: "Plugin operation timed out",
        ErrorCode.PluginInvalidResponse: "Plugin returned invalid response",
        ErrorCode.PluginProtocolError: "Plugin protocol error",
        ErrorCode.PluginVersionMismatch: "Plugin version mismatch",
        ErrorCode.PluginCapabilityMissing: "Plugin missing required capability",
        ErrorCode.PluginValidationFailed: "Plugin validation failed",
        ErrorCode.PluginExecutionFailed: "Plugin execution failed",
        ErrorCode.InvalidMessage: "Invalid message format",
        ErrorCode.ToolNotFound: "Tool not found",
        ErrorCode.IncompatibleVersion: "Incompatible version",
        ErrorCode.LSPError: "LSP error",
        ErrorCode.LSPInitializationFailed: "LSP initialization failed",
        ErrorCode.LSPInvalidRequest: "Invalid LSP request",
        ErrorCode.LSPMethodNotFound: "LSP method not found",
        ErrorCode.LSPInvalidParams: "Invalid LSP parameters",
        ErrorCode.LSPDocumentNotFound: "LSP document not found",
        ErrorCode.LSPParseError: "LSP parse error",
        ErrorCode.LSPServerCrashed: "LSP server crashed",
        ErrorCode.LSPTimeout: "LSP operation timed out",
        ErrorCode.LSPInvalidPosition: "Invalid LSP position",
        ErrorCode.LSPWorkspaceNotInitialized: "LSP workspace not initialized",
        ErrorCode.WatchError: "Watch mode error",
        ErrorCode.WatcherInitFailed: "Failed to initialize file watcher",
        ErrorCode.WatcherNotSupported: "File watcher not supported on this platform",
        ErrorCode.WatcherCrashed: "File watcher crashed",
        ErrorCode.FileWatchFailed: "Failed to watch file",
        ErrorCode.DebounceError: "Debounce error",
        ErrorCode.TooManyWatchTargets: "Too many watch targets",
        ErrorCode.InvalidConfiguration: "Invalid configuration",
        ErrorCode.ConfigError: "Configuration error",
        ErrorCode.InvalidWorkspace: "Invalid workspace configuration",
        ErrorCode.InvalidTarget: "Invalid target configuration",
        ErrorCode.InvalidInput: "Invalid input",
        ErrorCode.SchemaValidationFailed: "Schema validation failed",
        ErrorCode.DeprecatedField: "Deprecated field used",
        ErrorCode.RequiredFieldMissing: "Required field missing",
        ErrorCode.DuplicateTarget: "Duplicate target name",
        ErrorCode.ConfigConflict: "Configuration conflict",
        ErrorCode.MigrationFailed: "Migration from build system failed"
    ];
    auto msg = code in messages;
    return msg ? *msg : "Unknown error";
}

/// Error registry entry with comprehensive error information
struct ErrorRegistryEntry
{
    ErrorCode code;
    ErrorCategory category;
    Recoverability recoverability;
    string message;
    string[] defaultSuggestions;
    string docsUrl;
}

/// Central error registry - single source of truth for all error metadata
immutable ErrorRegistryEntry[ErrorCode] errorRegistry;

/// Initialize error registry at module initialization
shared static this()
{
    errorRegistry = [
        // Build errors (1000-1999) - Fatal
        ErrorCode.BuildFailed: ErrorRegistryEntry(
            ErrorCode.BuildFailed,
            ErrorCategory.Build,
            Recoverability.Fatal,
            "Build failed",
            ["Review build output above for specific errors", "Run with verbose output: bldr build --verbose"],
            "docs/user-guides/examples.md"
        ),
        ErrorCode.BuildTimeout: ErrorRegistryEntry(
            ErrorCode.BuildTimeout,
            ErrorCategory.Build,
            Recoverability.Transient,
            "Build timed out",
            ["Increase timeout in Builderfile", "Check for infinite loops or hanging processes"],
            "docs/architecture/overview.md"
        ),
        ErrorCode.BuildCancelled: ErrorRegistryEntry(
            ErrorCode.BuildCancelled,
            ErrorCategory.Build,
            Recoverability.Fatal,
            "Build was cancelled",
            ["Retry the build"],
            ""
        ),
        ErrorCode.TargetNotFound: ErrorRegistryEntry(
            ErrorCode.TargetNotFound,
            ErrorCategory.Build,
            Recoverability.User,
            "Target not found",
            ["Check target name spelling", "List all targets: bldr list", "View available targets: bldr graph"],
            "docs/user-guides/examples.md"
        ),
        ErrorCode.HandlerNotFound: ErrorRegistryEntry(
            ErrorCode.HandlerNotFound,
            ErrorCategory.Build,
            Recoverability.User,
            "Language handler not found",
            ["Check if language is supported", "Verify 'language' field spelling", "See supported languages in docs"],
            "docs/features/languages.md"
        ),
        ErrorCode.OutputMissing: ErrorRegistryEntry(
            ErrorCode.OutputMissing,
            ErrorCategory.Build,
            Recoverability.Fatal,
            "Expected output not found",
            ["Check build script produces required outputs", "Verify output paths in Builderfile"],
            "docs/user-guides/examples.md"
        ),
        
        // Parse errors (2000-2999) - User
        ErrorCode.ParseFailed: ErrorRegistryEntry(
            ErrorCode.ParseFailed,
            ErrorCategory.Parse,
            Recoverability.User,
            "Failed to parse configuration",
            ["Check file syntax", "Validate JSON/configuration format"],
            "docs/user-guides/examples.md"
        ),
        ErrorCode.InvalidJson: ErrorRegistryEntry(
            ErrorCode.InvalidJson,
            ErrorCategory.Parse,
            Recoverability.User,
            "Invalid JSON syntax",
            ["Check for missing commas or quotes", "Validate with jsonlint"],
            "docs/user-guides/examples.md"
        ),
        ErrorCode.InvalidBuildFile: ErrorRegistryEntry(
            ErrorCode.InvalidBuildFile,
            ErrorCategory.Parse,
            Recoverability.User,
            "Invalid Builderfile",
            ["Check Builderfile syntax", "Review examples in docs"],
            "docs/user-guides/examples.md"
        ),
        
        // Cache errors (4000-4999) - Mixed
        ErrorCode.CacheLoadFailed: ErrorRegistryEntry(
            ErrorCode.CacheLoadFailed,
            ErrorCategory.Cache,
            Recoverability.Transient,
            "Failed to load cache",
            ["Clear cache: bldr clean", "Check cache permissions", "Verify network connectivity for remote cache"],
            "docs/features/caching.md"
        ),
        ErrorCode.NetworkError: ErrorRegistryEntry(
            ErrorCode.NetworkError,
            ErrorCategory.System,
            Recoverability.Transient,
            "Network communication error",
            ["Check network connectivity", "Verify firewall settings", "Check remote service status"],
            "docs/features/remotecache.md"
        ),
        
        // Repository errors (4500-4599)
        ErrorCode.RepositoryError: ErrorRegistryEntry(
            ErrorCode.RepositoryError,
            ErrorCategory.Cache,
            Recoverability.Fatal,
            "Repository operation failed",
            ["Check repository configuration", "Verify repository URL"],
            "docs/features/repository-rules.md"
        ),
        
        // Plugin errors (13000-13999)
        ErrorCode.PluginError: ErrorRegistryEntry(
            ErrorCode.PluginError,
            ErrorCategory.Plugin,
            Recoverability.Fatal,
            "Plugin error",
            ["List plugins: bldr plugin list", "Refresh registry: bldr plugin refresh"],
            "docs/architecture/plugins.md"
        ),
        
        // LSP errors (14000-14999)
        ErrorCode.LSPError: ErrorRegistryEntry(
            ErrorCode.LSPError,
            ErrorCategory.LSP,
            Recoverability.Fatal,
            "LSP error",
            ["Restart LSP server", "Check editor LSP logs"],
            "docs/user-guides/lsp.md"
        ),
        
        // Watch errors (15000-15999)
        ErrorCode.WatchError: ErrorRegistryEntry(
            ErrorCode.WatchError,
            ErrorCategory.Watch,
            Recoverability.Fatal,
            "Watch mode error",
            ["Try manual rebuild: bldr build", "Check watch configuration"],
            "docs/user-guides/watch.md"
        ),
        
        // Config errors (16000-16999)
        ErrorCode.ConfigError: ErrorRegistryEntry(
            ErrorCode.ConfigError,
            ErrorCategory.Config,
            Recoverability.User,
            "Configuration error",
            ["Check configuration syntax", "Validate with: bldr check"],
            "docs/architecture/dsl.md"
        ),
    ];
}

/// Look up error metadata in registry
ErrorRegistryEntry lookupError(ErrorCode code) pure nothrow
{
    auto entry = code in errorRegistry;
    if (entry)
        return cast(ErrorRegistryEntry)*entry;
    
    // Fallback for errors not in registry
    return ErrorRegistryEntry(
        code,
        categoryOf(code),
        recoverabilityOf(code),
        messageTemplate(code),
        [],
        ""
    );
}

