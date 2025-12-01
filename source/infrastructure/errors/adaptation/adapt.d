module infrastructure.errors.adaptation.adapt;

import std.conv;
import std.exception;
import infrastructure.errors.handling.result;
import infrastructure.errors.types.types;
import infrastructure.errors.handling.codes;
import infrastructure.config.schema.schema : LanguageBuildResult;

/// Adapters for integrating new error system with legacy code

/// Convert exception to BuildError with strongly-typed suggestions
BuildError fromException(Exception e, ErrorCode code = ErrorCode.InternalError)
{
    import infrastructure.errors.types.context : ErrorSuggestion;
    
    auto error = new InternalError("Internal error: " ~ e.msg, code);
    
    // Try to extract stack trace
    static if (__traits(compiles, e.info))
    {
        if (e.info)
            error.stackTrace = e.info.toString();
    }
    
    // Use structured suggestions for better user experience
    error.addSuggestion(ErrorSuggestion("This is likely a bug in Builder"));
    error.addSuggestion(ErrorSuggestion.docs(
        "Please report this issue",
        "https://github.com/griffinstormer/Builder/issues"
    ));
    error.addSuggestion(ErrorSuggestion.command(
        "Run with verbose output for more details",
        "bldr build --verbose"
    ));
    
    return error;
}

/// Convert LanguageBuildResult to Result type with typed suggestions
Result!(string, BuildError) toResult(LanguageBuildResult buildResult, string targetId = "")
{
    import infrastructure.errors.types.context : ErrorSuggestion;
    
    if (buildResult.success)
    {
        return Ok!(string, BuildError)(buildResult.outputHash);
    }
    else
    {
        // Use builder pattern for type-safe error with structured suggestions
        auto error = ErrorBuilder!BuildFailureError.create(targetId, "Build failed: " ~ buildResult.error)
            .withSuggestion("Review the build output above for specific errors")
            .withFileCheck("Check that all dependencies are installed")
            .withFileCheck("Verify the build configuration is correct")
            .withCommand("Run with verbose logging", "bldr build --verbose")
            .build();
        
        return Err!(string, BuildError)(error);
    }
}

/// Convert Result back to LanguageBuildResult (for gradual migration)
LanguageBuildResult fromResult(Result!(string, BuildError) result)
{
    LanguageBuildResult buildResult;
    
    if (result.isOk)
    {
        buildResult.success = true;
        buildResult.outputHash = result.unwrap();
    }
    else
    {
        buildResult.success = false;
        buildResult.error = result.unwrapErr().message();
    }
    
    return buildResult;
}

/// Wrap a function that may throw into a Result
Result!(T, BuildError) wrap(T)(lazy T expression, string operation = "")
{
    try
    {
        return Ok!(T, BuildError)(expression);
    }
    catch (Exception e)
    {
        auto error = fromException(e);
        if (!operation.empty)
            error.addContext(ErrorContext(operation));
        return Err!(T, BuildError)(error);
    }
}

/// Execute and convert to Result with specific error type
Result!(T, E) wrapAs(T, E : BaseBuildError)(lazy T expression, E delegate(Exception) errorMapper)
{
    try
    {
        return Ok!(T, E)(expression);
    }
    catch (Exception e)
    {
        return Err!(T, E)(errorMapper(e));
    }
}

/// Assert with error result
Result!BuildError ensure(bool condition, lazy BuildError error)
{
    if (!condition)
        return Result!BuildError.err(error);
    return Result!BuildError.ok();
}

/// Create error result from condition
Result!(T, BuildError) check(T)(bool condition, T value, lazy BuildError error)
{
    if (condition)
        return Ok!(T, BuildError)(value);
    return Err!(T, BuildError)(error);
}

/// Create void result from condition
Result!BuildError checkVoid(bool condition, lazy BuildError error)
{
    if (condition)
        return Result!BuildError.ok();
    return Result!BuildError.err(error);
}

