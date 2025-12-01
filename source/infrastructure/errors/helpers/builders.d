module infrastructure.errors.helpers.builders;

import std.path : baseName, dirName;
import std.string : format;
import std.array : empty;
import std.file : exists;
import infrastructure.errors.types.types;
import infrastructure.errors.types.context;
import infrastructure.errors.handling.codes;

/// Enhanced error builders with auto-context and smart suggestions
/// 
/// These helpers automatically add contextual information and suggestions
/// based on the error type and available information.

/// Create a ParseError with rich context and suggestions
auto createParseError(
    string filePath,
    string message,
    ErrorCode code = ErrorCode.ParseFailed,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new ParseError(filePath, message, code);
    
    // Add source context
    error.addContext(ErrorContext(
        "parsing configuration file",
        filePath,
        format("%s:%d", baseName(file), line)
    ));
    
    // Add file-type specific suggestions
    string fileName = baseName(filePath);
    
    if (fileName == "package.json")
    {
        error.addSuggestion(ErrorSuggestion.command("Validate JSON syntax", "cat package.json | python3 -m json.tool"));
        error.addSuggestion(ErrorSuggestion("Check for trailing commas (not allowed in JSON)"));
        error.addSuggestion(ErrorSuggestion.docs("See package.json examples", "docs/features/ecosystem-integration.md"));
    }
    else if (fileName == "Cargo.toml")
    {
        error.addSuggestion(ErrorSuggestion.command("Validate TOML syntax", "cargo check --manifest-path Cargo.toml"));
        error.addSuggestion(ErrorSuggestion("Check for proper [sections] and key = \"value\" syntax"));
        error.addSuggestion(ErrorSuggestion.docs("See Cargo.toml format", "https://doc.rust-lang.org/cargo/reference/manifest.html"));
    }
    else if (fileName == "go.mod")
    {
        error.addSuggestion(ErrorSuggestion.command("Tidy go.mod", "go mod tidy"));
        error.addSuggestion(ErrorSuggestion("Verify module path and Go version"));
    }
    else if (fileName == "pyproject.toml" || fileName == "setup.py")
    {
        error.addSuggestion(ErrorSuggestion.command("Validate Python project", "pip install --dry-run ."));
        error.addSuggestion(ErrorSuggestion("Check project.name, project.version, and dependencies syntax"));
    }
    else if (fileName == "composer.json")
    {
        error.addSuggestion(ErrorSuggestion.command("Validate composer.json", "composer validate"));
        error.addSuggestion(ErrorSuggestion("Check for proper JSON syntax and required fields"));
    }
    else if (fileName == "Builderfile")
    {
        error.addSuggestion(ErrorSuggestion.docs("Review Builderfile syntax", "docs/user-guides/examples.md"));
        error.addSuggestion(ErrorSuggestion.command("Reinitialize Builderfile", "bldr init"));
        error.addSuggestion(ErrorSuggestion("Check for required fields: name, type, language, inputs"));
    }
    else if (fileName == "Builderspace")
    {
        error.addSuggestion(ErrorSuggestion.docs("Review Builderspace syntax", "docs/architecture/dsl.md"));
        error.addSuggestion(ErrorSuggestion("Check workspace-level configuration"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.docs("Review configuration file format"));
        error.addSuggestion(ErrorSuggestion("Check for syntax errors like missing brackets or quotes"));
    }
    
    return error;
}

/// Create a file read error with rich context
auto createFileReadError(
    string filePath,
    string additionalContext = "",
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    string message = format("Failed to read file: %s", filePath);
    if (!additionalContext.empty)
        message ~= " (" ~ additionalContext ~ ")";
    
    auto error = new IOError(filePath, message, ErrorCode.FileReadFailed);
    
    error.addContext(ErrorContext(
        "reading file",
        filePath,
        format("%s:%d", baseName(file), line)
    ));
    
    // Check file state and add specific suggestions
    if (!exists(filePath))
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("File does not exist", filePath));
        error.addSuggestion(ErrorSuggestion.command("List directory contents", "ls -la " ~ dirName(filePath)));
        
        string fileName = baseName(filePath);
        if (fileName == "Builderfile")
            error.addSuggestion(ErrorSuggestion.command("Create Builderfile", "bldr init"));
        else if (fileName == "Builderspace")
            error.addSuggestion(ErrorSuggestion.command("Create workspace", "bldr init --workspace"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Check file permissions and readability", filePath));
        error.addSuggestion(ErrorSuggestion.command("Verify file permissions", "ls -l " ~ filePath));
        error.addSuggestion(ErrorSuggestion("File may be in use by another process"));
    }
    
    return error;
}

/// Create an analysis error with rich context
auto createAnalysisError(
    string targetName,
    string message,
    ErrorCode code = ErrorCode.AnalysisFailed,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new AnalysisError(targetName, message, code);
    
    error.addContext(ErrorContext(
        "analyzing target dependencies",
        targetName,
        format("%s:%d", baseName(file), line)
    ));
    
    // Add code-specific suggestions
    if (code == ErrorCode.CircularDependency)
    {
        error.addSuggestion(ErrorSuggestion.command("Visualize dependency graph", "bldr query --graph " ~ targetName));
        error.addSuggestion(ErrorSuggestion("Break the cycle by removing or refactoring dependencies"));
    }
    else if (code == ErrorCode.MissingDependency)
    {
        error.addSuggestion(ErrorSuggestion.config("Add missing dependency to target's deps field"));
        error.addSuggestion(ErrorSuggestion.command("List available targets", "bldr query --targets"));
    }
    else if (code == ErrorCode.ImportResolutionFailed)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Verify imported file exists"));
        error.addSuggestion(ErrorSuggestion.config("Check import paths in target configuration"));
        error.addSuggestion(ErrorSuggestion("Ensure dependencies are properly declared in 'deps' field"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.command("Run with verbose output", "bldr build --verbose " ~ targetName));
        error.addSuggestion(ErrorSuggestion("Check for syntax errors in source files"));
    }
    
    return error;
}

/// Create a build error with rich context
auto createBuildError(
    string targetId,
    string message,
    ErrorCode code = ErrorCode.BuildFailed,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new BuildFailureError(targetId, message, code);
    
    error.addContext(ErrorContext(
        "building target",
        targetId,
        format("%s:%d", baseName(file), line)
    ));
    
    if (code == ErrorCode.BuildTimeout)
    {
        error.addSuggestion(ErrorSuggestion.config("Increase timeout in target configuration", "timeout: 600"));
        error.addSuggestion(ErrorSuggestion("Check for infinite loops or blocking operations"));
    }
    else if (code == ErrorCode.OutputMissing)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Verify build command produces expected output files"));
        error.addSuggestion(ErrorSuggestion.config("Check outputs field in target configuration"));
    }
    else if (code == ErrorCode.HandlerNotFound)
    {
        error.addSuggestion(ErrorSuggestion.command("List supported languages", "bldr query --languages"));
        error.addSuggestion(ErrorSuggestion.config("Specify correct language in target configuration"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.command("Run with verbose output for details", "bldr build --verbose " ~ targetId));
        error.addSuggestion(ErrorSuggestion.command("Clean and rebuild", "bldr clean && bldr build " ~ targetId));
        error.addSuggestion(ErrorSuggestion("Check compiler/tool output for specific errors"));
    }
    
    return error;
}

/// Create a language error with rich context
auto createLanguageError(
    string language,
    string message,
    ErrorCode code = ErrorCode.CompilationFailed,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new LanguageError(language, message, code);
    
    error.addContext(ErrorContext(
        "processing language-specific files",
        language,
        format("%s:%d", baseName(file), line)
    ));
    
    if (code == ErrorCode.MissingCompiler)
    {
        error.addSuggestion(ErrorSuggestion.command("Check if compiler is installed", "which " ~ getCompilerName(language)));
        error.addSuggestion(ErrorSuggestion("Install compiler/toolchain for " ~ language));
        error.addSuggestion(ErrorSuggestion.docs("See toolchain setup guide", "docs/user-guides/examples.md"));
    }
    else if (code == ErrorCode.UnsupportedLanguage)
    {
        error.addSuggestion(ErrorSuggestion.command("List supported languages", "bldr query --languages"));
        error.addSuggestion(ErrorSuggestion.docs("See language support", "docs/features/languages.md"));
        error.addSuggestion(ErrorSuggestion("Consider implementing a custom language handler"));
    }
    else if (code == ErrorCode.CompilationFailed)
    {
        error.addSuggestion(ErrorSuggestion("Run compiler directly to see full error output"));
        error.addSuggestion(ErrorSuggestion("Check for syntax errors in source files"));
        error.addSuggestion(ErrorSuggestion("Verify compiler version compatibility"));
    }
    
    return error;
}

/// Create a cache error with rich context
auto createCacheError(
    string message,
    ErrorCode code = ErrorCode.CacheLoadFailed,
    string cachePath = "",
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new CacheError(message, code);
    
    if (!cachePath.empty)
        error.cachePath = cachePath;
    
    error.addContext(ErrorContext(
        "cache operation",
        cachePath,
        format("%s:%d", baseName(file), line)
    ));
    
    if (code == ErrorCode.CacheCorrupted)
    {
        error.addSuggestion(ErrorSuggestion.command("Clear corrupted cache", "bldr clean --cache"));
        error.addSuggestion(ErrorSuggestion("Rebuild from clean state"));
    }
    else if (code == ErrorCode.CacheTooLarge)
    {
        error.addSuggestion(ErrorSuggestion.command("Clean old cache entries", "bldr clean --cache"));
        error.addSuggestion(ErrorSuggestion.config("Configure cache size limits", "cache.max_size: \"10GB\""));
    }
    else if (code == ErrorCode.CacheWriteFailed || code == ErrorCode.CacheSaveFailed)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Check cache directory write permissions", cachePath));
        error.addSuggestion(ErrorSuggestion("Verify sufficient disk space"));
    }
    else
    {
        error.addSuggestion(ErrorSuggestion.command("Clear cache and retry", "bldr clean --cache"));
        error.addSuggestion(ErrorSuggestion.fileCheck("Check cache directory permissions"));
    }
    
    return error;
}

/// Create a system error with rich context
auto createSystemError(
    string message,
    ErrorCode code = ErrorCode.ProcessSpawnFailed,
    string file = __FILE__,
    size_t line = __LINE__
) @system
{
    auto error = new SystemError(message, code);
    
    error.addContext(ErrorContext(
        "system operation",
        "",
        format("%s:%d", baseName(file), line)
    ));
    
    if (code == ErrorCode.ProcessSpawnFailed)
    {
        error.addSuggestion(ErrorSuggestion.fileCheck("Check if required tool is installed and in PATH"));
        error.addSuggestion(ErrorSuggestion.command("Verify tool availability", "which <command>"));
    }
    else if (code == ErrorCode.ProcessTimeout)
    {
        error.addSuggestion(ErrorSuggestion.config("Increase timeout value in configuration"));
        error.addSuggestion(ErrorSuggestion("Check if process is hanging or waiting for input"));
    }
    else if (code == ErrorCode.OutOfMemory)
    {
        error.addSuggestion(ErrorSuggestion.config("Reduce parallelism to use less memory", "parallelism: 2"));
        error.addSuggestion(ErrorSuggestion("Close other applications to free memory"));
    }
    
    return error;
}

/// Helper: Get compiler name for language
private string getCompilerName(string language) pure @safe
{
    import std.uni : toLower;
    import std.string : strip;
    
    string lang = language.toLower.strip;
    
    switch (lang)
    {
        case "c": return "gcc";
        case "c++": case "cpp": return "g++";
        case "rust": return "rustc";
        case "go": return "go";
        case "java": return "javac";
        case "d": return "dmd";
        case "typescript": return "tsc";
        case "python": return "python3";
        case "ruby": return "ruby";
        case "haskell": return "ghc";
        case "ocaml": return "ocamlc";
        default: return language.toLower;
    }
}

