module infrastructure.errors.types.types;

import std.conv;
import std.algorithm;
import std.array;
import infrastructure.errors.handling.codes;
import infrastructure.errors.types.context;

/// Base error interface - all errors implement this
interface BuildError
{
    /// Get error code for programmatic handling
    ErrorCode code() const pure nothrow;
    
    /// Get error category
    ErrorCategory category() const pure nothrow;
    
    /// Get primary error message
    string message() const;
    
    /// Get error context chain
    const(ErrorContext)[] contexts() const;
    
    /// Check if error is recoverable (transient)
    bool recoverable() const pure nothrow;
    
    /// Get recoverability classification
    Recoverability recoverability() const pure nothrow;
    
    /// Get full formatted error string
    string toString() const;
}

/// Base implementation with context chain
abstract class BaseBuildError : BuildError
{
    private ErrorCode _code;
    private string _message;
    private ErrorContext[] _contexts;
    private ErrorSuggestion[] _suggestions;
    
    this(ErrorCode code, string message) @trusted
    {
        _code = code;
        _message = message;
    }
    
    ErrorCode code() const pure nothrow
    {
        return _code;
    }
    
    ErrorCategory category() const pure nothrow
    {
        return categoryOf(_code);
    }
    
    string message() const
    {
        return _message;
    }
    
    const(ErrorContext)[] contexts() const
    {
        return _contexts;
    }
    
    bool recoverable() const pure nothrow
    {
        return isRecoverable(_code);
    }
    
    Recoverability recoverability() const pure nothrow
    {
        return recoverabilityOf(_code);
    }
    
    /// Get strongly-typed suggestions for this specific error instance
    const(ErrorSuggestion)[] suggestions() const { return _suggestions; }
    
    /// Add context to error chain
    void addContext(ErrorContext ctx) @system { _contexts ~= ctx; }
    
    /// Add a strongly-typed suggestion
    void addSuggestion(ErrorSuggestion suggestion) @system { _suggestions ~= suggestion; }
    
    /// Add a string suggestion (converted to General type for backward compatibility)
    void addSuggestion(string suggestion) @system { _suggestions ~= ErrorSuggestion(suggestion); }
    
    override string toString() const
    {
        import std.array : appender;
        auto result = appender!string;
        result.put("[");
        result.put(category.to!string);
        result.put(":");
        result.put(_code.to!string);
        result.put("] ");
        result.put(_message);
        foreach (ctx; _contexts)
        {
            result.put("\n  ");
            result.put(ctx.toString());
        }
        return result.data;
    }
}

/// Build execution error
class BuildFailureError : BaseBuildError
{
    string targetId;
    string[] failedDeps;
    
    this(string targetId, string message, ErrorCode code = ErrorCode.BuildFailed) @system
    {
        super(code, message);
        this.targetId = targetId;
    }
    
    override string toString() const
    {
        string result = super.toString();
        result ~= "\n  Target: " ~ targetId;
        
        if (!failedDeps.empty)
            result ~= "\n  Failed dependencies: " ~ failedDeps.join(", ");
        
        return result;
    }
}

/// Parse/configuration error
class ParseError : BaseBuildError
{
    string filePath;
    size_t line;
    size_t column;
    string snippet;
    
    this(string filePath, string message, ErrorCode code = ErrorCode.ParseFailed) @trusted
    {
        super(code, message);
        this.filePath = filePath;
    }
    
    /// Constructor with line/column info
    this(string filePath, string message, size_t line, size_t column, ErrorCode code = ErrorCode.ParseFailed) @trusted
    {
        super(code, message);
        this.filePath = filePath;
        this.line = line;
        this.column = column;
    }
    
    /// Auto-extract snippet from file
    void extractSnippet(size_t contextLines = 2) nothrow
    {
        import infrastructure.errors.utils.snippets : extractSnippet;
        if (!filePath.empty && line > 0)
            snippet = extractSnippet(filePath, line, contextLines);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!filePath.empty)
        {
            result ~= "\n  File: " ~ filePath;
            if (line > 0)
                result ~= ":" ~ line.to!string;
            if (column > 0)
                result ~= ":" ~ column.to!string;
        }
        
        if (!snippet.empty)
            result ~= "\n  " ~ snippet;
        
        return result;
    }
}

/// Analysis error
class AnalysisError : BaseBuildError
{
    string targetName;
    string[] unresolvedImports;
    string[] cyclePath;
    
    this(string targetName, string message, ErrorCode code = ErrorCode.AnalysisFailed) @system
    {
        super(code, message);
        this.targetName = targetName;
    }
    
    override string toString() const
    {
        string result = super.toString();
        result ~= "\n  Target: " ~ targetName;
        
        if (!unresolvedImports.empty)
            result ~= "\n  Unresolved: " ~ unresolvedImports.join(", ");
        
        if (!cyclePath.empty)
            result ~= "\n  Cycle: " ~ cyclePath.join(" -> ");
        
        return result;
    }
}

/// Cache operation error
class CacheError : BaseBuildError
{
    string cachePath;
    
    this(string message, ErrorCode code = ErrorCode.CacheLoadFailed) @system
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!cachePath.empty)
            result ~= "\n  Cache: " ~ cachePath;
        
        return result;
    }
}

/// IO operation error
class IOError : BaseBuildError
{
    string path;
    
    this(string path, string message, ErrorCode code = ErrorCode.FileNotFound) @system
    {
        super(code, message);
        this.path = path;
    }
    
    override string toString() const
    {
        string result = super.toString();
        result ~= "\n  Path: " ~ path;
        return result;
    }
}

/// Graph operation error
class GraphError : BaseBuildError
{
    string[] nodePath;
    
    this(string message, ErrorCode code = ErrorCode.GraphInvalid) @system
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!nodePath.empty)
            result ~= "\n  Path: " ~ nodePath.join(" -> ");
        
        return result;
    }
}

/// Language-specific error
class LanguageError : BaseBuildError
{
    string language;
    string filePath;
    size_t line;
    string compilerOutput;
    
    this(string language, string message, ErrorCode code = ErrorCode.CompilationFailed)
    {
        super(code, message);
        this.language = language;
    }
    
    override string toString() const
    {
        string result = super.toString();
        result ~= "\n  Language: " ~ language;
        
        if (!filePath.empty)
        {
            result ~= "\n  File: " ~ filePath;
            if (line > 0)
                result ~= ":" ~ line.to!string;
        }
        
        if (!compilerOutput.empty)
            result ~= "\n  Output:\n" ~ compilerOutput;
        
        return result;
    }
}

/// System-level error
class SystemError : BaseBuildError
{
    string command;
    int exitCode;
    
    this(string message, ErrorCode code = ErrorCode.ProcessSpawnFailed)
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!command.empty)
            result ~= "\n  Command: " ~ command;
        if (exitCode != 0)
            result ~= "\n  Exit code: " ~ exitCode.to!string;
        
        return result;
    }
}

/// Internal/unexpected error
class InternalError : BaseBuildError
{
    string stackTrace;
    
    this(string message, ErrorCode code = ErrorCode.InternalError)
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!stackTrace.empty)
            result ~= "\n  Stack trace:\n" ~ stackTrace;
        
        return result;
    }
}

/// Generic error for simple use cases and testing
class GenericError : BaseBuildError
{
    this(string message, ErrorCode code = ErrorCode.UnknownError)
    {
        super(code, message);
    }
}

/// Plugin system error
class PluginError : BaseBuildError
{
    string pluginName;
    string pluginVersion;
    
    this(string message, ErrorCode code = ErrorCode.PluginError)
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!pluginName.empty)
            result ~= "\n  Plugin: " ~ pluginName;
        if (!pluginVersion.empty)
            result ~= "\n  Version: " ~ pluginVersion;
        
        return result;
    }
}

/// LSP server error
class LSPError : BaseBuildError
{
    string method;
    string documentUri;
    int position;
    
    this(string message, ErrorCode code = ErrorCode.LSPError)
    {
        super(code, message);
        position = -1;
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!method.empty)
            result ~= "\n  LSP Method: " ~ method;
        if (!documentUri.empty)
            result ~= "\n  Document: " ~ documentUri;
        if (position >= 0)
            result ~= "\n  Position: " ~ position.to!string;
        
        return result;
    }
}

/// Watch mode error
class WatchError : BaseBuildError
{
    string watcherType;
    string[] watchPaths;
    
    this(string message, ErrorCode code = ErrorCode.WatchError)
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!watcherType.empty)
            result ~= "\n  Watcher: " ~ watcherType;
        if (watchPaths.length > 0)
        {
            result ~= "\n  Watch paths:";
            foreach (path; watchPaths)
                result ~= "\n    - " ~ path;
        }
        
        return result;
    }
}

/// Configuration/validation error
class ConfigError : BaseBuildError
{
    string configPath;
    string fieldName;
    string expectedType;
    string actualValue;
    
    this(string message, ErrorCode code = ErrorCode.ConfigError)
    {
        super(code, message);
    }
    
    override string toString() const
    {
        string result = super.toString();
        
        if (!configPath.empty)
            result ~= "\n  Config: " ~ configPath;
        if (!fieldName.empty)
            result ~= "\n  Field: " ~ fieldName;
        if (!expectedType.empty)
            result ~= "\n  Expected type: " ~ expectedType;
        if (!actualValue.empty)
            result ~= "\n  Actual value: " ~ actualValue;
        
        return result;
    }
}

/// Alias for backward compatibility and convenience
alias BuildError_Impl = GenericError;

/// Error builder for fluent API with strong type safety
struct ErrorBuilder(T : BaseBuildError)
{
    private T error;
    
    static ErrorBuilder create(Args...)(Args args)
    {
        ErrorBuilder builder;
        builder.error = new T(args);
        return builder;
    }
    
    /// Add context to the error
    ErrorBuilder withContext(string operation, string details = "")
    {
        error.addContext(ErrorContext(operation, details));
        return this;
    }
    
    /// Add a strongly-typed suggestion
    ErrorBuilder withSuggestion(ErrorSuggestion suggestion)
    {
        error.addSuggestion(suggestion);
        return this;
    }
    
    /// Add a string suggestion (convenience method)
    ErrorBuilder withSuggestion(string suggestion)
    {
        error.addSuggestion(suggestion);
        return this;
    }
    
    /// Add a command suggestion
    ErrorBuilder withCommand(string description, string cmd)
    {
        error.addSuggestion(ErrorSuggestion.command(description, cmd));
        return this;
    }
    
    /// Add a documentation suggestion
    ErrorBuilder withDocs(string description, string url = "")
    {
        error.addSuggestion(ErrorSuggestion.docs(description, url));
        return this;
    }
    
    /// Add a file check suggestion
    ErrorBuilder withFileCheck(string description, string path = "")
    {
        error.addSuggestion(ErrorSuggestion.fileCheck(description, path));
        return this;
    }
    
    /// Add a configuration suggestion
    ErrorBuilder withConfig(string description, string setting = "")
    {
        error.addSuggestion(ErrorSuggestion.config(description, setting));
        return this;
    }
    
    T build()
    {
        return error;
    }
}

/// Convenience constructors for common error types
BuildFailureError buildError(string targetId, string message) { return new BuildFailureError(targetId, message); }
ParseError parseError(string filePath, string message) { return new ParseError(filePath, message); }
AnalysisError analysisError(string targetName, string message) { return new AnalysisError(targetName, message); }
CacheError cacheError(string message) { return new CacheError(message); }
IOError ioError(string path, string message) { return new IOError(path, message); }
GraphError graphError(string message) { return new GraphError(message); }
LanguageError languageError(string language, string message) { return new LanguageError(language, message); }
SystemError systemError(string message) { return new SystemError(message); }
InternalError internalError(string message) { return new InternalError(message); }

/// Smart error constructors with built-in suggestions

/// Create a file not found error with helpful suggestions
IOError fileNotFoundError(string path, string context = "") @system
{
    auto error = new IOError(path, "File not found: " ~ path, ErrorCode.FileNotFound);
    
    import std.path : baseName;
    string fileName = baseName(path);
    
    if (fileName == "Builderfile")
    {
        error.addSuggestion(ErrorSuggestion.command("Create a Builderfile", "bldr init"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if you're in the correct directory"));
        error.addSuggestion(ErrorSuggestion.docs("See Builderfile documentation", "docs/user-guides/EXAMPLES.md"));
    }
    else if (fileName == "Builderspace")
    {
        error.addSuggestion(ErrorSuggestion.command("Create a workspace", "bldr init --workspace"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if you're in the workspace root"));
        error.addSuggestion(ErrorSuggestion.docs("See workspace documentation", "docs/architecture/DSL.md"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Verify the file path", path));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check for typos in file path"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Ensure file is not excluded by .builderignore"));
        error.addSuggestion(ErrorSuggestion.command("Check if file exists", "ls " ~ path));
    }
    
    if (!context.empty)
        error.addContext(ErrorContext(context));
    
    return error;
}

/// Create a file read error with helpful suggestions
IOError fileReadError(string path, string errorMsg, string context = "") @system
{
    auto error = new IOError(path, "Failed to read file: " ~ errorMsg, ErrorCode.FileReadFailed);
    
    error.addSuggestion(ErrorSuggestion.command("Check file permissions", "ls -la " ~ path));
    error.addSuggestion(ErrorSuggestion.fileCheck("Ensure file is readable"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify file is not locked by another process"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check if file is corrupted"));
    
    if (!context.empty)
        error.addContext(ErrorContext(context));
    
    return error;
}

/// Create a parse error with helpful suggestions
ParseError parseErrorWithContext(string filePath, string message, size_t line = 0, size_t column = 0, string context = "") @system
{
    auto error = new ParseError(filePath, message, line, column, ErrorCode.ParseFailed);
    
    // Auto-extract snippet if file and line are available
    if (line > 0)
        error.extractSnippet();
    
    import std.path : baseName;
    string fileName = baseName(filePath);
    
    if (fileName == "Builderfile")
    {
        error.addSuggestion(ErrorSuggestion.docs("Check Builderfile syntax", "docs/user-guides/examples.md"));
        error.addSuggestion(ErrorSuggestion.command("Validate JSON syntax", "jsonlint " ~ filePath));
        error.addSuggestion(ErrorSuggestion.fileCheck("Ensure all braces and brackets are matched"));
    }
    else if (fileName == "Builderspace")
    {
        error.addSuggestion(ErrorSuggestion.docs("Check Builderspace syntax", "docs/architecture/dsl.md"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Review examples in examples/ directory"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Ensure all declarations are properly formatted"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Check file syntax"));
        error.addSuggestion(ErrorSuggestion.docs("See documentation for file format"));
    }
    
    if (!context.empty)
        error.addContext(ErrorContext(context));
    
    return error;
}

/// Create a build failure error with helpful suggestions
BuildFailureError buildFailureError(string targetId, string message, string[] failedDeps = null) @system
{
    auto error = new BuildFailureError(targetId, message);
    
    if (failedDeps !is null)
        error.failedDeps = failedDeps;
    
    error.addSuggestion(ErrorSuggestion("Review build output above for specific errors"));
    error.addSuggestion(ErrorSuggestion.command("Run with verbose output", "bldr build --verbose"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check that all dependencies are installed"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify source files have no errors"));
    error.addSuggestion(ErrorSuggestion.command("View dependency graph", "bldr graph"));
    
    return error;
}

/// Create a target not found error with helpful suggestions
AnalysisError targetNotFoundError(string targetName) @system
{
    auto error = new AnalysisError(targetName, "Target not found: " ~ targetName, ErrorCode.TargetNotFound);
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Check that target name is spelled correctly"));
    error.addSuggestion(ErrorSuggestion.command("View available targets", "bldr graph"));
    error.addSuggestion(ErrorSuggestion.command("List all targets", "bldr list"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify target is defined in Builderfile"));
    error.addSuggestion(ErrorSuggestion.docs("See target documentation", "docs/user-guides/EXAMPLES.md"));
    
    return error;
}

/// Create a cache error with helpful suggestions
CacheError cacheLoadError(string cachePath, string message) @system
{
    auto error = new CacheError("Cache load failed: " ~ message, ErrorCode.CacheLoadFailed);
    error.cachePath = cachePath;
    
    error.addSuggestion(ErrorSuggestion.command("Clear cache and rebuild", "bldr clean"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Cache may be from incompatible version"));
    error.addSuggestion(ErrorSuggestion.command("Check cache permissions", "ls -la .builder-cache/"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check available disk space"));
    
    return error;
}

/// Create a circular dependency error with helpful suggestions
GraphError circularDependencyError(string[] cycle) @system
{
    auto cycleStr = cycle.join(" -> ");
    auto error = new GraphError("Circular dependency detected: " ~ cycleStr, ErrorCode.GraphCycle);
    error.nodePath = cycle;
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Break the circular dependency by removing one of the links"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Refactor code to eliminate the cycle"));
    error.addSuggestion(ErrorSuggestion.command("View full dependency graph", "bldr graph"));
    error.addSuggestion(ErrorSuggestion.docs("See dependency management guide", "docs/architecture/ARCHITECTURE.md"));
    
    return error;
}

/// Create a compilation error with helpful suggestions
LanguageError compilationError(string language, string filePath, string message, string compilerOutput = "") @system
{
    auto error = new LanguageError(language, "Compilation failed: " ~ message, ErrorCode.CompilationFailed);
    error.filePath = filePath;
    error.compilerOutput = compilerOutput;
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Review compiler output above for specific errors"));
    error.addSuggestion(ErrorSuggestion.command("Build with verbose output", "bldr build --verbose"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check syntax in " ~ filePath));
    error.addSuggestion(ErrorSuggestion.docs("See " ~ language ~ " documentation", "docs/user-guides/EXAMPLES.md"));
    
    return error;
}

/// Create a missing dependency error with helpful suggestions
AnalysisError missingDependencyError(string targetName, string missingDep) @system
{
    auto error = new AnalysisError(targetName, 
        "Missing dependency: " ~ missingDep, ErrorCode.MissingDependency);
    error.unresolvedImports ~= missingDep;
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Add '" ~ missingDep ~ "' to the deps list of target '" ~ targetName ~ "'"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check if '" ~ missingDep ~ "' target exists in Builderfile"));
    error.addSuggestion(ErrorSuggestion.command("List all available targets", "bldr list"));
    error.addSuggestion(ErrorSuggestion.command("View dependency graph", "bldr graph"));
    
    return error;
}

/// Create a process execution error with helpful suggestions
SystemError processExecutionError(string command, int exitCode, string message = "") @system
{
    auto fullMessage = message.empty ? 
        "Process execution failed with exit code " ~ exitCode.to!string : message;
    
    auto error = new SystemError(fullMessage, ErrorCode.ProcessSpawnFailed);
    error.command = command;
    error.exitCode = exitCode;
    
    error.addSuggestion(ErrorSuggestion.command("Check if command exists", "which " ~ command.split()[0]));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify command permissions and PATH"));
    error.addSuggestion(ErrorSuggestion.command("Run command manually to debug", command));
    
    if (exitCode == 127)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Command not found - install required tool"));
    }
    else if (exitCode == 126)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Permission denied - check file permissions"));
    }
    
    return error;
}

/// Create an invalid configuration error with helpful suggestions
ParseError invalidConfigError(string filePath, string fieldName, string message, size_t line = 0, size_t column = 0) @system
{
    auto fullMessage = "Invalid configuration in '" ~ fieldName ~ "': " ~ message;
    auto error = new ParseError(filePath, fullMessage, line, column, ErrorCode.InvalidFieldValue);
    
    if (line > 0)
        error.extractSnippet();
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Check the '" ~ fieldName ~ "' field in " ~ filePath));
    error.addSuggestion(ErrorSuggestion.docs("See configuration syntax", "docs/user-guides/examples.md"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify field type and format"));
    error.addSuggestion(ErrorSuggestion.command("Validate configuration", "bldr check"));
    
    return error;
}

/// Create a parse error with "did you mean?" suggestion for unknown field
ParseError unknownFieldError(string filePath, string fieldName, const(string)[] validFields, size_t line = 0, size_t column = 0) @system
{
    import infrastructure.errors.utils.fuzzy : didYouMean;
    
    auto message = "Unknown field '" ~ fieldName ~ "'";
    auto suggestion = didYouMean(fieldName, validFields);
    
    if (!suggestion.empty)
        message ~= ". " ~ suggestion;
    
    auto error = new ParseError(filePath, message, line, column, ErrorCode.InvalidFieldValue);
    
    if (line > 0)
        error.extractSnippet();
    
    error.addSuggestion(ErrorSuggestion.docs("See valid fields", "docs/user-guides/examples.md"));
    
    return error;
}

/// Create a parse error with "did you mean?" suggestion for unknown target
ParseError unknownTargetError(string targetName, const(string)[] availableTargets, string filePath = "") @system
{
    import infrastructure.errors.utils.fuzzy : didYouMean;
    
    auto message = "Target '" ~ targetName ~ "' not found";
    auto suggestion = didYouMean(targetName, availableTargets);
    
    if (!suggestion.empty)
        message ~= ". " ~ suggestion;
    
    auto error = new ParseError(filePath, message, ErrorCode.TargetNotFound);
    
    error.addSuggestion(ErrorSuggestion.command("List available targets", "bldr query --targets"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Check Builderfile for target definitions"));
    
    return error;
}

/// Create a language handler not found error with helpful suggestions
BuildFailureError handlerNotFoundError(string language) @system
{
    auto error = new BuildFailureError("", 
        "No handler found for language: " ~ language, ErrorCode.UnsupportedLanguage);
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Check if language '" ~ language ~ "' is supported"));
    error.addSuggestion(ErrorSuggestion.fileCheck("Verify 'language' field spelling in Builderfile"));
    error.addSuggestion(ErrorSuggestion.docs("See supported languages", "docs/user-guides/EXAMPLES.md"));
    error.addSuggestion(ErrorSuggestion.config("Use 'language: generic' for custom build scripts"));
    
    return error;
}

/// Create a plugin error with helpful suggestions
PluginError pluginError(string pluginName, string message, ErrorCode code = ErrorCode.PluginError) @system
{
    auto error = new PluginError(message, code);
    error.pluginName = pluginName;
    
    error.addSuggestion(ErrorSuggestion.command("List available plugins", "bldr plugin list"));
    error.addSuggestion(ErrorSuggestion.command("Refresh plugin registry", "bldr plugin refresh"));
    error.addSuggestion(ErrorSuggestion.docs("See plugin documentation", "docs/architecture/PLUGINS.md"));
    
    return error;
}

/// Create a plugin not found error
PluginError pluginNotFoundError(string pluginName) @system
{
    auto error = new PluginError("Plugin not found: " ~ pluginName, ErrorCode.PluginNotFound);
    error.pluginName = pluginName;
    
    error.addSuggestion(ErrorSuggestion.command("Install plugin", "brew install builder-plugin-" ~ pluginName));
    error.addSuggestion(ErrorSuggestion.command("List available plugins", "bldr plugin list"));
    error.addSuggestion(ErrorSuggestion.command("Refresh plugin registry", "bldr plugin refresh"));
    
    return error;
}

/// Create an LSP error with helpful suggestions
LSPError lspError(string message, ErrorCode code = ErrorCode.LSPError) @system
{
    auto error = new LSPError(message, code);
    
    error.addSuggestion(ErrorSuggestion.command("Restart LSP server", "Restart your editor"));
    error.addSuggestion(ErrorSuggestion.docs("See LSP documentation", "docs/user-guides/LSP.md"));
    error.addSuggestion(ErrorSuggestion.command("Check LSP logs", "Check editor's LSP logs"));
    
    return error;
}

/// Create a watch mode error with helpful suggestions
WatchError watchError(string message, ErrorCode code = ErrorCode.WatchError) @system
{
    auto error = new WatchError(message, code);
    
    error.addSuggestion(ErrorSuggestion.command("Try manual rebuild", "bldr build"));
    error.addSuggestion(ErrorSuggestion.docs("See watch mode documentation", "docs/user-guides/WATCH.md"));
    error.addSuggestion(ErrorSuggestion.config("Check watch mode configuration"));
    
    return error;
}

/// Create a configuration error with helpful suggestions
ConfigError configError(string configPath, string fieldName, string message, 
                        ErrorCode code = ErrorCode.ConfigError) @system
{
    auto error = new ConfigError(message, code);
    error.configPath = configPath;
    error.fieldName = fieldName;
    
    error.addSuggestion(ErrorSuggestion.fileCheck("Check '" ~ fieldName ~ "' in " ~ configPath));
    error.addSuggestion(ErrorSuggestion.docs("See configuration syntax", "docs/architecture/DSL.md"));
    error.addSuggestion(ErrorSuggestion.command("Validate configuration", "bldr check"));
    
    return error;
}

