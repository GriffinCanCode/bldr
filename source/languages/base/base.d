module languages.base.base;

import std.conv : to;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.telemetry.distributed.tracing;
import engine.caching.actions.action;
import infrastructure.utils.logging.structured;
import infrastructure.utils.simd.capabilities;
import infrastructure.errors;

/// Action recording callback for fine-grained caching
/// Allows language handlers to report individual actions to the executor
alias ActionRecorder = void delegate(ActionId actionId, string[] inputs, string[] outputs, string[string] metadata, bool success);

/// Dependency recording callback for incremental compilation
/// Allows language handlers to report file-level dependencies
alias DependencyRecorder = void delegate(string sourceFile, string[] dependencies);

/// Build context with action-level caching and incremental compilation support
/// Extended to include SIMD capabilities and observability (tracer, logger)
struct BuildContext
{
    Target target;
    WorkspaceConfig config;
    ActionRecorder recorder;         // Optional action recorder
    DependencyRecorder depRecorder;  // Optional dependency recorder
    SIMDCapabilities simd;           // SIMD capabilities (null if not available)
    bool incrementalEnabled;         // Whether incremental compilation is enabled
    Tracer tracer;                   // Distributed tracer (null if not available)
    StructuredLogger logger;         // Structured logger (null if not available)
    
    /// Record an action for fine-grained caching
    void recordAction(ActionId actionId, string[] inputs, string[] outputs, string[string] metadata, bool success)
    {
        if (recorder !is null)
            recorder(actionId, inputs, outputs, metadata, success);
    }
    
    /// Record dependencies for incremental compilation
    void recordDependencies(string sourceFile, string[] dependencies)
    {
        if (depRecorder !is null && incrementalEnabled)
            depRecorder(sourceFile, dependencies);
    }
    
    /// Check if SIMD acceleration is available
    bool hasSIMD() const pure nothrow
    {
        return simd !is null && simd.active;
    }
    
    /// Check if incremental compilation is enabled
    bool hasIncremental() const pure nothrow
    {
        return incrementalEnabled && depRecorder !is null;
    }
}

/// Base interface for language-specific build handlers
interface LanguageHandler
{
    /// Build with full context including action-level caching, incremental compilation, and SIMD
    /// 
    /// This is the PRIMARY method to implement in language handlers.
    /// Provides access to:
    /// - ActionRecorder for fine-grained caching
    /// - DependencyRecorder for incremental compilation
    /// - SIMDCapabilities for hardware-accelerated operations
    /// 
    /// Handlers should implement buildImplWithContext() instead of overriding this directly.
    Result!(string, BuildError) buildWithContext(BuildContext context);
    
    /// Check if target needs rebuild
    bool needsRebuild(in Target target, in WorkspaceConfig config);
    
    /// Clean build artifacts
    void clean(in Target target, in WorkspaceConfig config);
    
    /// Get output files for a target
    string[] getOutputs(in Target target, in WorkspaceConfig config);
    
    /// Analyze imports in source files (optional for advanced dependency analysis)
    Import[] analyzeImports(in string[] sources);
}

/// Base implementation with common functionality
abstract class BaseLanguageHandler : LanguageHandler
{
    
    /// Build with full context including action-level caching, incremental compilation, and SIMD
    /// 
    /// Safety: Calls buildImplWithContext() and getOutputs() through @system wrappers because
    /// language handlers may perform file I/O, process execution, and other
    /// operations that are inherently @system but have been validated for safety.
    /// 
    /// The @system lambda wrapper pattern:
    /// - Delegates responsibility to concrete language handlers
    /// - Each handler marks buildImplWithContext() as @system with justification
    /// - This function remains @system by wrapping the call
    /// - Exceptions are caught and converted to Result types
    /// 
    /// Invariants:
    /// - buildImplWithContext() is overridden in each language handler
    /// - All file I/O and process execution is validated by handlers
    /// - Result type ensures type-safe error propagation
    /// - No unsafe operations leak to caller
    /// - BuildContext provides access to action recorder, dependency recorder, and SIMD
    /// 
    /// What could go wrong:
    /// - Handler buildImplWithContext() has memory safety bug: contained within handler
    /// - Exception thrown: caught and converted to BuildError Result
    /// - Invalid target: handler validates and returns error Result
    Result!(string, BuildError) buildWithContext(BuildContext context) @system
    {
        // Use tracer and logger from context (dependency injection)
        auto tracer = context.tracer;
        auto logger = context.logger;
        
        // Create span for language handler execution (if tracer available)
        Span handlerSpan = tracer !is null ? tracer.startSpan("language-handler", SpanKind.Internal) : null;
        
        // Ensure span is finished
        if (handlerSpan !is null)
            scope(exit) tracer.finishSpan(handlerSpan);
        
        if (handlerSpan !is null) {
            handlerSpan.setAttribute("handler.language", context.target.language.to!string);
            handlerSpan.setAttribute("handler.target", context.target.name);
            handlerSpan.setAttribute("handler.type", context.target.type.to!string);
            handlerSpan.setAttribute("handler.incremental", context.incrementalEnabled.to!string);
            handlerSpan.setAttribute("handler.simd", context.hasSIMD().to!string);
        }
        
        try
        {
            // Safety: buildImplWithContext() performs I/O and process execution
            // Marked @system in each language handler with specific justification
            // This lambda wrapper keeps buildWithContext() @system while allowing @system ops
            auto result = buildImplWithContext(context);
            
            if (result.success)
            {
                if (handlerSpan !is null) {
                    handlerSpan.setStatus(SpanStatus.Ok);
                    handlerSpan.setAttribute("build.success", "true");
                }
                
                return Ok!(string, BuildError)(result.outputHash);
            }
            else
            {
                auto error = new BuildFailureError(
                    context.target.name,
                    "Build command failed: " ~ result.error,
                    ErrorCode.BuildFailed
                );
                error.addContext(ErrorContext(
                    "building target",
                    "language: " ~ context.target.language.to!string
                ));
                error.addSuggestion("Review the error output above for specific compilation errors");
                error.addSuggestion("Check that all dependencies and build tools are installed");
                error.addSuggestion("Verify source files have no syntax errors");
                error.addSuggestion("Try building manually to reproduce the issue");
                
                if (handlerSpan !is null) {
                    handlerSpan.recordException(new Exception(result.error));
                    handlerSpan.setStatus(SpanStatus.Error, result.error);
                }
                
                return Err!(string, BuildError)(error);
            }
        }
        catch (Exception e)
        {
            auto error = new BuildFailureError(
                context.target.name,
                "Build failed with exception: " ~ e.msg,
                ErrorCode.BuildFailed
            );
            error.addContext(ErrorContext(
                "caught exception during build",
                e.classinfo.name
            ));
            error.addSuggestion("Check the error message above for details");
            error.addSuggestion("Verify the build command is correct");
            error.addSuggestion("Ensure all required tools and dependencies are available");
            error.addSuggestion("Run with --verbose for more detailed output");
            
            if (handlerSpan !is null) {
                handlerSpan.recordException(e);
                handlerSpan.setStatus(SpanStatus.Error, e.msg);
            }
            
            return Err!(string, BuildError)(error);
        }
    }
    
    /// Check if target needs rebuild based on output file existence
    /// 
    /// Safety: This function is @system and calls getOutputs() through @system wrapper
    /// because handlers may perform path operations (inherently @system).
    /// 
    /// The @system lambda wrapper pattern:
    /// - getOutputs() is marked @system in each language handler
    /// - Path operations are validated by handlers
    /// - exists() check is read-only file system query
    /// 
    /// Invariants:
    /// - getOutputs() returns validated output paths
    /// - exists() is safe read-only operation
    /// - Returns true if any output missing (conservative rebuild)
    /// 
    /// What could go wrong:
    /// - Handler returns invalid paths: contained within handler
    /// - exists() throws: would propagate (safe failure)
    bool needsRebuild(in Target target, in WorkspaceConfig config) @system
    {
        import std.file : exists;
        
        // Safety: getOutputs() performs path operations
        // Marked @system in each handler with specific justification
        auto outputs = getOutputs(target, config);
        
        // Rebuild if any output is missing
        foreach (output; outputs)
        {
            if (!exists(output))
                return true;
        }
        
        return false;
    }
    
    /// Clean build artifacts by removing output files
    /// 
    /// Safety: This function is @system and calls getOutputs() through @system wrapper.
    /// File deletion operations (remove) are inherently @system but safe here because:
    /// - Only deletes files returned by handler's getOutputs()
    /// - Checks existence before attempting removal
    /// - Handler validates output paths
    /// 
    /// The @system lambda wrapper pattern:
    /// - getOutputs() provides validated file list
    /// - Deletion is confined to handler-specified outputs
    /// - No arbitrary file deletion possible
    /// 
    /// Invariants:
    /// - Only removes files listed by getOutputs()
    /// - Checks exists() before remove()
    /// - Handler ensures output paths are within project
    /// 
    /// What could go wrong:
    /// - Permission denied: remove() throws (safe failure)
    /// - File in use: remove() throws (safe failure)
    /// - Handler returns invalid paths: contained within handler
    void clean(in Target target, in WorkspaceConfig config) @system
    {
        import std.file : remove, exists;
        
        // Safety: getOutputs() returns validated output file paths
        // Marked @system in each handler with specific justification
        auto outputs = getOutputs(target, config);
        
        foreach (output; outputs)
        {
            if (exists(output))
                remove(output);
        }
    }
    
    Import[] analyzeImports(string[] sources) @system
    {
        // Default implementation: delegate to language spec
        // Subclasses can override for custom analysis
        import infrastructure.analysis.targets.spec;
        import std.file : readText, exists, isFile;
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                // Subclasses should override to provide language-specific logic
                // This is a fallback
            }
            catch (Exception e)
            {
                // Silently skip unreadable files
            }
        }
        
        return allImports;
    }
    
    /// Subclasses implement the actual build logic with full context
    /// 
    /// This method receives BuildContext with access to:
    /// - target and config (context.target, context.config)
    /// - ActionRecorder for fine-grained caching (context.recordAction)
    /// - DependencyRecorder for incremental compilation (context.recordDependencies)
    /// - SIMDCapabilities for hardware acceleration (context.simd)
    /// 
    /// Example usage:
    ///   if (context.hasSIMD()) {
    ///       // Use SIMD-accelerated operations
    ///   }
    ///   context.recordAction(actionId, inputs, outputs, metadata, success);
    ///   context.recordDependencies(sourceFile, deps);
    protected abstract LanguageBuildResult buildImplWithContext(in BuildContext context);
}
