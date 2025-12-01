module infrastructure.errors.formatting.suggestions;

import infrastructure.errors.types.types : BuildError, BaseBuildError, BuildFailureError, ParseError;
import infrastructure.errors.handling.codes : ErrorCode;
import infrastructure.errors.types.context : ErrorSuggestion;

/// Suggestion generator - single responsibility: generate contextual suggestions
/// 
/// Separation of concerns:
/// - ErrorFormatter: formats error structures
/// - ColorFormatter: applies terminal colors
/// - SuggestionGenerator: generates helpful suggestions based on error context
struct SuggestionGenerator
{
    /// Generate suggestions for an error
    /// 
    /// Responsibility: Analyze error and return relevant suggestions
    static const(ErrorSuggestion)[] generate(const BuildError error) @trusted
    {
        // Try to get typed suggestions from error first
        if (auto baseErr = cast(const BaseBuildError)error)
        {
            auto typedSuggestions = baseErr.suggestions();
            if (typedSuggestions.length > 0)
                return typedSuggestions;
        }
        
        // Fallback to code-based suggestions
        return generateFromCode(error.code());
    }
    
    /// Generate suggestions based on error code
    /// 
    /// Responsibility: Provide generic suggestions for common error codes
    private static const(ErrorSuggestion)[] generateFromCode(ErrorCode code) @trusted
    {
        ErrorSuggestion[] suggestions;
        
        switch (code)
        {
            // IO Errors (5000-5999)
            case ErrorCode.FileNotFound:
                suggestions ~= ErrorSuggestion.fileCheck("Verify the file path is correct and the file exists");
                suggestions ~= ErrorSuggestion.command("List directory contents", "ls -la");
                break;
                
            case ErrorCode.FileReadFailed:
                suggestions ~= ErrorSuggestion.fileCheck("Check file permissions and readability");
                suggestions ~= ErrorSuggestion.command("Verify file permissions", "ls -l <file>");
                suggestions ~= ErrorSuggestion("File may be in use by another process");
                break;
                
            case ErrorCode.FileWriteFailed:
                suggestions ~= ErrorSuggestion.fileCheck("Check file/directory write permissions");
                suggestions ~= ErrorSuggestion.command("Verify permissions", "ls -ld <directory>");
                suggestions ~= ErrorSuggestion("Check available disk space");
                break;
                
            case ErrorCode.DirectoryNotFound:
                suggestions ~= ErrorSuggestion.fileCheck("Verify the directory path exists");
                suggestions ~= ErrorSuggestion.command("Create directory if needed", "mkdir -p <directory>");
                break;
                
            case ErrorCode.PermissionDenied:
                suggestions ~= ErrorSuggestion.command("Check file permissions", "ls -l <file>");
                suggestions ~= ErrorSuggestion.command("Add execute permission if needed", "chmod +x <file>");
                suggestions ~= ErrorSuggestion("Try running with appropriate user/group ownership");
                break;
                
            // Parse Errors (2000-2999)
            case ErrorCode.ParseFailed:
                suggestions ~= ErrorSuggestion.docs("Review Builderfile syntax documentation", "docs/user-guides/examples.md");
                suggestions ~= ErrorSuggestion.command("Validate JSON/TOML syntax with external tool", "");
                suggestions ~= ErrorSuggestion("Check for missing commas, brackets, or quotes");
                suggestions ~= ErrorSuggestion("Check for typos in field names or keywords");
                break;
                
            case ErrorCode.InvalidJson:
                suggestions ~= ErrorSuggestion.command("Validate JSON syntax", "cat <file> | python3 -m json.tool");
                suggestions ~= ErrorSuggestion("Check for trailing commas (not allowed in JSON)");
                suggestions ~= ErrorSuggestion("Verify all strings are properly quoted");
                break;
                
            case ErrorCode.InvalidBuildFile:
                suggestions ~= ErrorSuggestion.command("Create a valid Builderfile", "bldr init");
                suggestions ~= ErrorSuggestion.docs("See Builderfile examples", "docs/user-guides/examples.md");
                suggestions ~= ErrorSuggestion("Check for required fields: name, type, language");
                break;
                
            case ErrorCode.MissingField:
                suggestions ~= ErrorSuggestion.config("Add the required field to your configuration");
                suggestions ~= ErrorSuggestion.docs("See configuration schema", "docs/architecture/dsl.md");
                break;
                
            case ErrorCode.InvalidFieldValue:
                suggestions ~= ErrorSuggestion.config("Check the field value against allowed types/enums");
                suggestions ~= ErrorSuggestion.docs("Review field requirements", "docs/architecture/dsl.md");
                suggestions ~= ErrorSuggestion("Check for typos in field names");
                break;
                
            case ErrorCode.InvalidGlob:
                suggestions ~= ErrorSuggestion("Check glob pattern syntax (e.g., src/**/*.d)");
                suggestions ~= ErrorSuggestion.command("Test glob pattern", "ls -d <pattern>");
                break;
                
            case ErrorCode.InvalidConfiguration:
                suggestions ~= ErrorSuggestion.command("Reinitialize configuration", "bldr init");
                suggestions ~= ErrorSuggestion.docs("Review configuration guide", "docs/user-guides/examples.md");
                break;
                
            // Analysis Errors (3000-3999)
            case ErrorCode.AnalysisFailed:
                suggestions ~= ErrorSuggestion.command("Run with verbose output", "bldr build --verbose");
                suggestions ~= ErrorSuggestion("Check for syntax errors in source files");
                break;
                
            case ErrorCode.ImportResolutionFailed:
                suggestions ~= ErrorSuggestion.fileCheck("Verify imported file exists");
                suggestions ~= ErrorSuggestion.config("Check import paths in configuration");
                suggestions ~= ErrorSuggestion("Ensure dependencies are properly declared");
                break;
                
            case ErrorCode.CircularDependency:
                suggestions ~= ErrorSuggestion.command("Visualize dependency graph to identify cycle", "bldr query --graph");
                suggestions ~= ErrorSuggestion("Break the cycle by removing or refactoring dependencies");
                break;
                
            case ErrorCode.MissingDependency:
                suggestions ~= ErrorSuggestion.config("Add missing dependency to target configuration");
                suggestions ~= ErrorSuggestion.command("Check available targets", "bldr query --targets");
                break;
                
            case ErrorCode.InvalidImport:
                suggestions ~= ErrorSuggestion.fileCheck("Verify import path syntax and file location");
                suggestions ~= ErrorSuggestion("Check for typos in import statements");
                break;
                
            // Build Errors (1000-1999)
            case ErrorCode.BuildFailed:
                suggestions ~= ErrorSuggestion.command("Run with verbose output for details", "bldr build --verbose");
                suggestions ~= ErrorSuggestion.command("Clean and rebuild", "bldr clean && bldr build");
                suggestions ~= ErrorSuggestion("Check compiler/tool output for specific errors");
                break;
                
            case ErrorCode.BuildTimeout:
                suggestions ~= ErrorSuggestion.config("Increase timeout in configuration", "timeout: 600");
                suggestions ~= ErrorSuggestion("Check for infinite loops or blocking operations");
                break;
                
            case ErrorCode.TargetNotFound:
                suggestions ~= ErrorSuggestion("Check if the target name is spelled correctly (typos detected automatically)");
                suggestions ~= ErrorSuggestion.command("List available targets", "bldr query --targets");
                suggestions ~= ErrorSuggestion.fileCheck("Check target name spelling in Builderfile");
                break;
                
            case ErrorCode.HandlerNotFound:
                suggestions ~= ErrorSuggestion("Verify language handler is installed for this file type");
                suggestions ~= ErrorSuggestion.command("List supported languages", "bldr query --languages");
                break;
                
            case ErrorCode.OutputMissing:
                suggestions ~= ErrorSuggestion("Check build command actually produces output files");
                suggestions ~= ErrorSuggestion.config("Verify output path in target configuration");
                break;
                
            // Cache Errors (4000-4999)
            case ErrorCode.CacheLoadFailed:
                suggestions ~= ErrorSuggestion.command("Clear cache and retry", "bldr clean --cache");
                suggestions ~= ErrorSuggestion.fileCheck("Check cache directory permissions");
                break;
                
            case ErrorCode.CacheSaveFailed:
                suggestions ~= ErrorSuggestion.fileCheck("Check cache directory write permissions");
                suggestions ~= ErrorSuggestion("Verify sufficient disk space");
                break;
                
            case ErrorCode.CacheCorrupted:
                suggestions ~= ErrorSuggestion.command("Clear the corrupted cache", "bldr clean --cache");
                suggestions ~= ErrorSuggestion("Rebuild from clean state");
                break;
                
            case ErrorCode.CacheNotFound:
                suggestions ~= ErrorSuggestion("Build without cache on first run");
                suggestions ~= ErrorSuggestion.config("Verify cache path configuration");
                break;
                
            case ErrorCode.CacheTooLarge:
                suggestions ~= ErrorSuggestion.command("Clean old cache entries", "bldr clean --cache");
                suggestions ~= ErrorSuggestion.config("Configure cache size limits");
                break;
                
            case ErrorCode.NetworkError:
                suggestions ~= ErrorSuggestion("Check network connectivity");
                suggestions ~= ErrorSuggestion("Verify proxy settings if behind a firewall");
                suggestions ~= ErrorSuggestion.command("Test network access", "curl -v <url>");
                break;
                
            // System Errors (8000-8999)
            case ErrorCode.ProcessSpawnFailed:
                suggestions ~= ErrorSuggestion.fileCheck("Check if required tool is installed and in PATH");
                suggestions ~= ErrorSuggestion.command("Verify tool availability", "which <command>");
                suggestions ~= ErrorSuggestion("Check PATH environment variable");
                break;
                
            case ErrorCode.ProcessTimeout:
                suggestions ~= ErrorSuggestion.config("Increase timeout value in configuration");
                suggestions ~= ErrorSuggestion("Check if process is hanging or waiting for input");
                break;
                
            case ErrorCode.ProcessCrashed:
                suggestions ~= ErrorSuggestion.command("Run process directly to see crash details", "");
                suggestions ~= ErrorSuggestion("Check system logs for crash information");
                break;
                
            case ErrorCode.OutOfMemory:
                suggestions ~= ErrorSuggestion("Reduce parallelism to use less memory");
                suggestions ~= ErrorSuggestion.config("Configure memory limits", "max_memory: \"4GB\"");
                suggestions ~= ErrorSuggestion("Close other applications to free memory");
                break;
                
            // Language Errors (7000-7999)
            case ErrorCode.CompilationFailed:
                suggestions ~= ErrorSuggestion.command("Run compiler directly to see full output", "");
                suggestions ~= ErrorSuggestion("Check for syntax errors in source files");
                suggestions ~= ErrorSuggestion("Verify compiler version compatibility");
                break;
                
            case ErrorCode.UnsupportedLanguage:
                suggestions ~= ErrorSuggestion.command("List supported languages", "bldr query --languages");
                suggestions ~= ErrorSuggestion.docs("See language support docs", "docs/features/languages.md");
                suggestions ~= ErrorSuggestion("Consider adding a custom language handler");
                break;
                
            case ErrorCode.MissingCompiler:
                suggestions ~= ErrorSuggestion.command("Install required compiler/tool", "");
                suggestions ~= ErrorSuggestion.fileCheck("Verify compiler is in PATH");
                suggestions ~= ErrorSuggestion.docs("See toolchain setup guide", "docs/user-guides/examples.md");
                break;
                
            // Plugin Errors (13000-13999)
            case ErrorCode.PluginNotFound:
                suggestions ~= ErrorSuggestion.command("List available plugins", "bldr plugin list");
                suggestions ~= ErrorSuggestion.command("Install plugin if needed", "bldr plugin install <name>");
                suggestions ~= ErrorSuggestion.fileCheck("Check plugin path configuration");
                break;
                
            case ErrorCode.PluginLoadFailed:
                suggestions ~= ErrorSuggestion("Check plugin file permissions and format");
                suggestions ~= ErrorSuggestion.command("Verify plugin with", "bldr plugin validate <plugin>");
                break;
                
            case ErrorCode.PluginVersionMismatch:
                suggestions ~= ErrorSuggestion.command("Update plugin to compatible version", "bldr plugin update <name>");
                suggestions ~= ErrorSuggestion.docs("Check plugin compatibility docs");
                break;
                
            // LSP Errors (14000-14999)
            case ErrorCode.LSPInitializationFailed:
                suggestions ~= ErrorSuggestion.command("Restart LSP server", "");
                suggestions ~= ErrorSuggestion.fileCheck("Check workspace root is valid");
                suggestions ~= ErrorSuggestion.docs("See LSP setup guide", "docs/user-guides/lsp.md");
                break;
                
            case ErrorCode.LSPDocumentNotFound:
                suggestions ~= ErrorSuggestion("Ensure file is saved before LSP operations");
                suggestions ~= ErrorSuggestion("Refresh workspace in editor");
                break;
                
            // Watch Errors (15000-15999)
            case ErrorCode.WatcherInitFailed:
                suggestions ~= ErrorSuggestion("Check if file system supports file watching");
                suggestions ~= ErrorSuggestion.fileCheck("Verify watch directory exists and is accessible");
                break;
                
            case ErrorCode.TooManyWatchTargets:
                suggestions ~= ErrorSuggestion.config("Reduce watch patterns or use more specific globs");
                suggestions ~= ErrorSuggestion.command("Increase system watch limit on Linux", "echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf");
                break;
                
            // Config Errors (16000-16999)
            case ErrorCode.InvalidWorkspace:
                suggestions ~= ErrorSuggestion.command("Initialize workspace", "bldr init --workspace");
                suggestions ~= ErrorSuggestion.fileCheck("Check Builderspace file syntax");
                break;
                
            case ErrorCode.InvalidTarget:
                suggestions ~= ErrorSuggestion.config("Review target configuration fields");
                suggestions ~= ErrorSuggestion.docs("See target schema", "docs/architecture/dsl.md");
                break;
                
            case ErrorCode.SchemaValidationFailed:
                suggestions ~= ErrorSuggestion.docs("Review configuration schema requirements");
                suggestions ~= ErrorSuggestion("Check for required fields and valid types");
                break;
                
            case ErrorCode.DuplicateTarget:
                suggestions ~= ErrorSuggestion.config("Rename one of the duplicate targets");
                suggestions ~= ErrorSuggestion("Check for targets with same name in different files");
                break;
                
            // Migration Errors (17000-17999)
            case ErrorCode.MigrationFailed:
                suggestions ~= ErrorSuggestion.command("Try migration wizard", "bldr migrate");
                suggestions ~= ErrorSuggestion.docs("See migration guide", "docs/user-guides/migration.md");
                suggestions ~= ErrorSuggestion("Report complex migrations on issue tracker");
                break;
                
            // Repository Errors (4500-4599)
            case ErrorCode.RepositoryNotFound:
                suggestions ~= ErrorSuggestion.config("Check repository URL/path in configuration");
                suggestions ~= ErrorSuggestion("Verify repository exists and is accessible");
                break;
                
            case ErrorCode.RepositoryFetchFailed:
                suggestions ~= ErrorSuggestion("Check network connectivity");
                suggestions ~= ErrorSuggestion("Verify repository URL and credentials");
                suggestions ~= ErrorSuggestion.command("Test repository access", "git ls-remote <url>");
                break;
                
            case ErrorCode.RepositoryVerificationFailed:
                suggestions ~= ErrorSuggestion("Check repository signature/checksum");
                suggestions ~= ErrorSuggestion.config("Verify repository verification settings");
                break;
                
            // Internal Errors (9000-9999)
            case ErrorCode.InternalError:
                suggestions ~= ErrorSuggestion("This is likely a bug in Builder");
                suggestions ~= ErrorSuggestion.docs("Please report this issue", "https://github.com/griffinstormer/Builder/issues");
                suggestions ~= ErrorSuggestion.command("Run with verbose output for more details", "bldr build --verbose");
                break;
                
            case ErrorCode.NotImplemented:
                suggestions ~= ErrorSuggestion("This feature is not yet implemented");
                suggestions ~= ErrorSuggestion.docs("Check roadmap or request feature");
                break;
                
            default:
                // No specific suggestions for this error code
                // Return empty array rather than generic suggestions
                break;
        }
        
        return cast(const(ErrorSuggestion)[])suggestions;
    }
}

