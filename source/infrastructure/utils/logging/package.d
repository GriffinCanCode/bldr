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
/// // Simple logging (backward compatible)
/// Logger.info("Build started");
/// Logger.error("Failed to compile");
/// 
/// // Structured logging with fields
/// Logger.info("Cache hit", LogFields.of("target", "myapp", "hash", "abc123"));
/// 
/// // Convenience KV methods
/// Logger.infoKV("Build complete", "target", "myapp", "duration_ms", 1234);
/// 
/// // Using the F alias for concise field building
/// Logger.warning("Slow build", F("target", "lib", "time", "5.2s"));
/// 
/// // Change output format for log aggregation
/// Logger.setFormat(LogFormat.Json);    // JSON lines output
/// Logger.setFormat(LogFormat.Logfmt);  // key=value format
/// ```

public import infrastructure.utils.logging.logger;
public import infrastructure.utils.logging.structured;
