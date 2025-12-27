module infrastructure.errors.codes;

/// Hierarchical Error Code System
/// 
/// This package provides a comprehensive, domain-organized error code system with:
/// - Namespaced error codes (Build, Cache, IO, Network, etc.)
/// - Backward-compatible flat ErrorCode enum
/// - Category classification and recoverability metadata
/// 
/// Usage (hierarchical - recommended for new code):
///   import infrastructure.errors.codes;
///   
///   // Using namespaced codes
///   auto code = Build.Failed;
///   auto cacheCode = Cache.Timeout;
///   
///   // Get metadata
///   auto cat = BuildErrors.category();
///   auto rec = CacheErrors.recoverabilityOf(Cache.Timeout);
/// 
/// Usage (flat - backward compatibility):
///   import infrastructure.errors.codes;
///   
///   // Traditional flat enum
///   auto code = ErrorCode.BuildFailed;
///   auto cat = categoryOf(code);

// Core types
public import infrastructure.errors.codes.category;
public import infrastructure.errors.codes.recoverability;

// Domain-specific error codes (hierarchical namespaces)
public import infrastructure.errors.codes.build       : Build, BuildErrors;
public import infrastructure.errors.codes.parse       : Parse, ParseErrors;
public import infrastructure.errors.codes.analysis    : Analysis, AnalysisErrors;
public import infrastructure.errors.codes.cache       : Cache, CacheErrors;
public import infrastructure.errors.codes.repository  : Repository, RepositoryErrors;
public import infrastructure.errors.codes.io          : IO, IOErrors;
public import infrastructure.errors.codes.graph       : Graph, GraphErrors;
public import infrastructure.errors.codes.language    : Language, LanguageErrors;
public import infrastructure.errors.codes.system      : System, SystemErrors;
public import infrastructure.errors.codes.internal    : Internal, InternalErrors;
public import infrastructure.errors.codes.telemetry   : Telemetry, TelemetryErrors;
public import infrastructure.errors.codes.distributed : Distributed, DistributedErrors;
public import infrastructure.errors.codes.plugin      : Plugin, PluginErrors;
public import infrastructure.errors.codes.lsp         : LSP, LSPErrors;
public import infrastructure.errors.codes.watch       : Watch, WatchErrors;
public import infrastructure.errors.codes.config      : Config, ConfigErrors;
public import infrastructure.errors.codes.migration   : Migration, MigrationErrors;
public import infrastructure.errors.codes.network     : Network, NetworkErrors;
public import infrastructure.errors.codes.security    : Security, SecurityErrors;
public import infrastructure.errors.codes.toolchain   : Toolchain, ToolchainErrors;

/// Unified error code enum for backward compatibility
/// Maps to domain-specific enums while maintaining existing API
enum ErrorCode : int
{
    // General errors (0-999)
    UnknownError = 0,
    
    // Build errors (1000-1999)
    BuildFailed = Build.Failed,
    BuildTimeout = Build.Timeout,
    BuildCancelled = Build.Cancelled,
    TargetNotFound = Build.TargetNotFound,
    HandlerNotFound = Build.HandlerNotFound,
    OutputMissing = Build.OutputMissing,
    
    // Parse errors (2000-2999)
    ParseFailed = Parse.Failed,
    InvalidJson = Parse.InvalidJson,
    InvalidBuildFile = Parse.InvalidBuildFile,
    MissingField = Parse.MissingField,
    InvalidFieldValue = Parse.InvalidFieldValue,
    InvalidGlob = Parse.InvalidGlob,
    InvalidConfiguration = Parse.InvalidConfiguration,
    
    // Analysis errors (3000-3999)
    AnalysisFailed = Analysis.Failed,
    ImportResolutionFailed = Analysis.ImportResolutionFailed,
    CircularDependency = Analysis.CircularDependency,
    MissingDependency = Analysis.MissingDependency,
    InvalidImport = Analysis.InvalidImport,
    
    // Cache errors (4000-4999)
    CacheLoadFailed = Cache.LoadFailed,
    CacheSaveFailed = Cache.SaveFailed,
    CacheCorrupted = Cache.Corrupted,
    CacheEvictionFailed = Cache.EvictionFailed,
    CacheNotFound = Cache.NotFound,
    CacheDisabled = Cache.Disabled,
    CacheUnauthorized = Cache.Unauthorized,
    CacheTooLarge = Cache.TooLarge,
    CacheTimeout = Cache.Timeout,
    CacheWriteFailed = Cache.WriteFailed,
    CacheInUse = Cache.InUse,
    CacheDeleteFailed = Cache.DeleteFailed,
    CacheGCFailed = Cache.GCFailed,
    NetworkError = 4083, // Legacy position, use Network.Error for new code
    
    // Repository errors (4500-4599)
    RepositoryError = Repository.Error,
    RepositoryNotFound = Repository.NotFound,
    RepositoryFetchFailed = Repository.FetchFailed,
    RepositoryVerificationFailed = Repository.VerificationFailed,
    VerificationFailed = Repository.ContentVerificationFailed,
    RepositoryInvalid = Repository.Invalid,
    RepositoryTimeout = Repository.Timeout,
    RepositoryAlreadyAdded = Repository.AlreadyAdded,
    
    // IO errors (5000-5999)
    FileNotFound = IO.FileNotFound,
    FileReadFailed = IO.FileReadFailed,
    FileWriteFailed = IO.FileWriteFailed,
    FileDeleteFailed = IO.FileDeleteFailed,
    DirectoryNotFound = IO.DirectoryNotFound,
    PermissionDenied = IO.PermissionDenied,
    
    // Graph errors (6000-6999)
    GraphCycle = Graph.Cycle,
    GraphInvalid = Graph.Invalid,
    NodeNotFound = Graph.NodeNotFound,
    EdgeInvalid = Graph.EdgeInvalid,
    
    // Language errors (7000-7999)
    SyntaxError = Language.SyntaxError,
    CompilationFailed = Language.CompilationFailed,
    ValidationFailed = Language.ValidationFailed,
    UnsupportedLanguage = Language.UnsupportedLanguage,
    MissingCompiler = Language.MissingCompiler,
    MacroExpansionFailed = Language.MacroExpansionFailed,
    MacroLoadFailed = Language.MacroLoadFailed,
    
    // System errors (8000-8999)
    ProcessSpawnFailed = System.ProcessSpawnFailed,
    ProcessTimeout = System.ProcessTimeout,
    ProcessCrashed = System.ProcessCrashed,
    OutOfMemory = System.OutOfMemory,
    ThreadPoolError = System.ThreadPoolError,
    
    // Internal errors (9000-9999)
    InternalError = Internal.Error,
    NotImplemented = Internal.NotImplemented,
    AssertionFailed = Internal.AssertionFailed,
    UnreachableCode = Internal.UnreachableCode,
    InitializationFailed = Internal.InitializationFailed,
    NotInitialized = Internal.NotInitialized,
    NotSupported = Internal.NotSupported,
    
    // Telemetry errors (10000-10999)
    TelemetryNoSession = Telemetry.NoSession,
    TelemetryStorage = Telemetry.Storage,
    TelemetryInvalid = Telemetry.Invalid,
    
    // Tracing errors (11000-11999)
    TraceInvalidFormat = Telemetry.TraceInvalidFormat,
    TraceNoActiveSpan = Telemetry.TraceNoActiveSpan,
    TraceExportFailed = Telemetry.TraceExportFailed,
    
    // Distributed build errors (12000-12999)
    DistributedError = Distributed.Error,
    CoordinatorNotFound = Distributed.CoordinatorNotFound,
    CoordinatorTimeout = Distributed.CoordinatorTimeout,
    WorkerTimeout = Distributed.WorkerTimeout,
    WorkerFailed = Distributed.WorkerFailed,
    ActionSchedulingFailed = Distributed.ActionSchedulingFailed,
    SandboxError = Distributed.SandboxError,
    ArtifactTransferFailed = Distributed.ArtifactTransferFailed,
    
    // Plugin errors (13000-13999)
    PluginError = Plugin.Error,
    PluginNotFound = Plugin.NotFound,
    PluginLoadFailed = Plugin.LoadFailed,
    PluginCrashed = Plugin.Crashed,
    PluginTimeout = Plugin.Timeout,
    PluginInvalidResponse = Plugin.InvalidResponse,
    PluginProtocolError = Plugin.ProtocolError,
    PluginVersionMismatch = Plugin.VersionMismatch,
    PluginCapabilityMissing = Plugin.CapabilityMissing,
    PluginValidationFailed = Plugin.ValidationFailed,
    PluginExecutionFailed = Plugin.ExecutionFailed,
    InvalidMessage = Plugin.InvalidMessage,
    ToolNotFound = Plugin.ToolNotFound,
    IncompatibleVersion = Plugin.IncompatibleVersion,
    
    // LSP errors (14000-14999)
    LSPError = LSP.Error,
    LSPInitializationFailed = LSP.InitializationFailed,
    LSPInvalidRequest = LSP.InvalidRequest,
    LSPMethodNotFound = LSP.MethodNotFound,
    LSPInvalidParams = LSP.InvalidParams,
    LSPDocumentNotFound = LSP.DocumentNotFound,
    LSPParseError = LSP.ParseError,
    LSPServerCrashed = LSP.ServerCrashed,
    LSPTimeout = LSP.Timeout,
    LSPInvalidPosition = LSP.InvalidPosition,
    LSPWorkspaceNotInitialized = LSP.WorkspaceNotInitialized,
    
    // Watch mode errors (15000-15999)
    WatchError = Watch.Error,
    WatcherInitFailed = Watch.InitFailed,
    WatcherNotSupported = Watch.NotSupported,
    WatcherCrashed = Watch.Crashed,
    FileWatchFailed = Watch.FileFailed,
    DebounceError = Watch.DebounceError,
    TooManyWatchTargets = Watch.TooManyTargets,
    
    // Configuration/Validation errors (16000-16999)
    ConfigError = Config.Error,
    InvalidWorkspace = Config.InvalidWorkspace,
    InvalidTarget = Config.InvalidTarget,
    InvalidInput = Config.InvalidInput,
    SchemaValidationFailed = Config.SchemaValidationFailed,
    DeprecatedField = Config.DeprecatedField,
    RequiredFieldMissing = Config.RequiredFieldMissing,
    DuplicateTarget = Config.DuplicateTarget,
    ConfigConflict = Config.Conflict,
    
    // Migration errors (17000-17999)
    MigrationFailed = Migration.Failed,
}

/// Get error category from error code using optimized lookup
ErrorCategory categoryOf(ErrorCode code) pure nothrow @nogc
{
    static immutable ErrorCategory[21] categories = [
        ErrorCategory.Internal,     // 0
        ErrorCategory.Build,        // 1
        ErrorCategory.Parse,        // 2
        ErrorCategory.Analysis,     // 3
        ErrorCategory.Cache,        // 4
        ErrorCategory.IO,           // 5
        ErrorCategory.Graph,        // 6
        ErrorCategory.Language,     // 7
        ErrorCategory.System,       // 8
        ErrorCategory.Internal,     // 9
        ErrorCategory.Telemetry,    // 10
        ErrorCategory.Telemetry,    // 11 Tracing
        ErrorCategory.Distributed,  // 12
        ErrorCategory.Plugin,       // 13
        ErrorCategory.LSP,          // 14
        ErrorCategory.Watch,        // 15
        ErrorCategory.Config,       // 16
        ErrorCategory.Migration,    // 17
        ErrorCategory.Network,      // 18
        ErrorCategory.Security,     // 19
        ErrorCategory.Toolchain,    // 20
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
    ];
    
    auto result = code in recoverabilityMap;
    return result ? *result : Recoverability.Fatal;
}

/// Check if error is recoverable (transient, can be retried)
bool isRecoverable(ErrorCode code) pure nothrow @nogc
{
    return recoverabilityOf(code) == Recoverability.Transient;
}

/// Get human-readable error message template
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
        ErrorCode.MigrationFailed: "Migration from build system failed",
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
        ErrorCode.TargetNotFound: ErrorRegistryEntry(
            ErrorCode.TargetNotFound,
            ErrorCategory.Build,
            Recoverability.User,
            "Target not found",
            ["Check target name spelling", "List all targets: bldr list", "View available targets: bldr graph"],
            "docs/user-guides/examples.md"
        ),
        ErrorCode.ParseFailed: ErrorRegistryEntry(
            ErrorCode.ParseFailed,
            ErrorCategory.Parse,
            Recoverability.User,
            "Failed to parse configuration",
            ["Check file syntax", "Validate JSON/configuration format"],
            "docs/user-guides/examples.md"
        ),
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
            ErrorCategory.Network,
            Recoverability.Transient,
            "Network communication error",
            ["Check network connectivity", "Verify firewall settings", "Check remote service status"],
            "docs/features/remotecache.md"
        ),
        ErrorCode.PluginError: ErrorRegistryEntry(
            ErrorCode.PluginError,
            ErrorCategory.Plugin,
            Recoverability.Fatal,
            "Plugin error",
            ["List plugins: bldr plugin list", "Refresh registry: bldr plugin refresh"],
            "docs/architecture/plugins.md"
        ),
        ErrorCode.LSPError: ErrorRegistryEntry(
            ErrorCode.LSPError,
            ErrorCategory.LSP,
            Recoverability.Fatal,
            "LSP error",
            ["Restart LSP server", "Check editor LSP logs"],
            "docs/user-guides/lsp.md"
        ),
        ErrorCode.WatchError: ErrorRegistryEntry(
            ErrorCode.WatchError,
            ErrorCategory.Watch,
            Recoverability.Fatal,
            "Watch mode error",
            ["Try manual rebuild: bldr build", "Check watch configuration"],
            "docs/user-guides/watch.md"
        ),
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
    
    return ErrorRegistryEntry(
        code,
        categoryOf(code),
        recoverabilityOf(code),
        messageTemplate(code),
        [],
        ""
    );
}

/// Convert hierarchical code to flat ErrorCode
ErrorCode toErrorCode(int domainCode) pure nothrow @nogc
{
    return cast(ErrorCode)domainCode;
}

/// Type-safe conversion utilities
template toErrorCode(T)
{
    ErrorCode toErrorCode(T code) pure nothrow @nogc
    {
        return cast(ErrorCode)cast(int)code;
    }
}

