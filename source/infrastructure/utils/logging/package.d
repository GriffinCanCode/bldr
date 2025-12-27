module infrastructure.utils.logging;

/// Logging utilities for Builder
/// 
/// This package provides logging capabilities:
/// - Simple colored logging with structured fields (Logger)
/// - Structured logging with thread context (StructuredLogger)
/// - Per-target log buffering
/// - Multiple output formats: Console, JSON, Logfmt
/// 
/// Example usage:
/// ```d
/// import infrastructure.utils.logging;
/// 
/// // Structured logging with fluent API (preferred)
/// structuredLog.info("build_started")
///     .field("targets", 42)
///     .field("parallelism", 8)
///     .emit();
/// 
/// structuredLog.warning("slow_build")
///     .field("target", "mylib")
///     .field("duration_ms", 5200)
///     .emit();
/// 
/// // Legacy Logger API (backward compatible)
/// structuredLog.info("build_started").emit();
/// structuredLog.error("failed_to_compile").emit();
/// ```

public import infrastructure.utils.logging.logger;
public import infrastructure.utils.logging.structured;

/// Global structured logger instance for convenient access
/// Use structuredLog.info("event").field("key", val).emit()
__gshared StructuredLogger structuredLog;

/// Initialize the global structured logger
shared static this() @trusted
{
    structuredLog = new StructuredLogger(LogLevel.Debug);
}

/// Convenience alias for shorter access
alias slog = structuredLog;

/// Get global structured logger (for use in templates/mixins)
StructuredLogger getStructuredLogger() @trusted => structuredLog;
