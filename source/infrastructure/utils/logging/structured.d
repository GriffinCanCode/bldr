module infrastructure.utils.logging.structured;

import std.stdio;
import std.datetime : SysTime, Clock;
import std.conv : to;
import std.format : format;
import std.array : appender, Appender;
import std.json : JSONValue, JSONType;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import infrastructure.errors;

/// Structured logging system for parallel builds with thread context
/// 
/// Features:
/// - Thread-safe logging with mutex protection
/// - Per-target log buffering
/// - Structured fields (key-value pairs)
/// - Correlation IDs for request tracing
/// - JSON export for log aggregation
/// - Integration with telemetry system
/// 
/// Thread Safety:
/// - All log operations are thread-safe via mutex
/// - Per-thread context stored in thread-local storage
/// - Log buffers are protected by mutex

/// Log level enumeration
enum LogLevel
{
    Trace,
    Debug,
    Info,
    Warning,
    Error,
    Critical
}

/// Log entry with structured fields
/// Includes trace context for distributed tracing correlation
struct LogEntry
{
    SysTime timestamp;
    LogLevel level;
    string message;
    string targetId;
    size_t threadId;
    string correlationId;
    string traceId;      // OpenTelemetry trace ID for log correlation
    string spanId;       // Current span ID
    string[string] fields;
    string stackTrace;
    
    /// Convert to JSON (compatible with log aggregation systems)
    JSONValue toJson() const @system
    {
        JSONValue json;
        json["timestamp"] = timestamp.toISOExtString();
        json["level"] = level.to!string;
        json["message"] = message;
        json["target"] = targetId;
        json["thread"] = threadId;
        json["correlationId"] = correlationId;
        
        // Include trace context for distributed tracing correlation
        // These fields follow OpenTelemetry conventions for log correlation
        if (traceId.length > 0)
            json["trace_id"] = traceId;
        if (spanId.length > 0)
            json["span_id"] = spanId;
        
        if (fields.length > 0)
        {
            JSONValue fieldsJson;
            foreach (key, value; fields)
            {
                fieldsJson[key] = value;
            }
            json["fields"] = fieldsJson;
        }
        
        if (stackTrace.length > 0)
        {
            json["stackTrace"] = stackTrace;
        }
        
        return json;
    }
    
    /// Format as human-readable string
    string toString() const @system
    {
        auto buffer = appender!string;
        
        // Color codes
        string color;
        final switch (level)
        {
            case LogLevel.Trace:
                color = "\x1b[90m"; // Gray
                break;
            case LogLevel.Debug:
                color = "\x1b[36m"; // Cyan
                break;
            case LogLevel.Info:
                color = "\x1b[32m"; // Green
                break;
            case LogLevel.Warning:
                color = "\x1b[33m"; // Yellow
                break;
            case LogLevel.Error:
                color = "\x1b[31m"; // Red
                break;
            case LogLevel.Critical:
                color = "\x1b[35m"; // Magenta
                break;
        }
        
        immutable reset = "\x1b[0m";
        
        // Format: [TIMESTAMP] [LEVEL] [TARGET:THREAD] message {fields}
        buffer ~= format("[%s] %s[%s]%s ", 
            timestamp.toISOExtString()[11..19], // HH:MM:SS
            color,
            level.to!string,
            reset
        );
        
        if (targetId.length > 0)
        {
            buffer ~= format("[%s:%d] ", targetId, threadId);
        }
        else
        {
            buffer ~= format("[thread:%d] ", threadId);
        }
        
        buffer ~= message;
        
        if (fields.length > 0)
        {
            buffer ~= " {";
            size_t i = 0;
            foreach (key, value; fields)
            {
                if (i > 0) buffer ~= ", ";
                buffer ~= format("%s=%s", key, value);
                i++;
            }
            buffer ~= "}";
        }
        
        return buffer.data;
    }
}

/// Thread context for structured logging
/// Supports distributed tracing correlation via traceId/spanId
struct LogContext
{
    string targetId;
    string correlationId;
    string traceId;      // Distributed trace ID (for log correlation)
    string spanId;       // Current span ID
    string[string] fields;
    
    /// Clone context with additional fields
    LogContext withFields(string[string] additionalFields) const @system
    {
        LogContext ctx;
        ctx.targetId = this.targetId;
        ctx.correlationId = this.correlationId;
        ctx.traceId = this.traceId;
        ctx.spanId = this.spanId;
        
        // Duplicate fields manually
        foreach (key, value; this.fields)
        {
            ctx.fields[key] = value;
        }
        foreach (key, value; additionalFields)
        {
            ctx.fields[key] = value;
        }
        return ctx;
    }
    
    /// Clone context with trace context (for distributed tracing)
    LogContext withTraceContext(string traceId, string spanId) const @system
    {
        LogContext ctx = this.withFields(null);
        ctx.traceId = traceId;
        ctx.spanId = spanId;
        return ctx;
    }
}

/// Thread-local context storage
private LogContext threadContext;

/// Get current thread context
LogContext getLogContext() @system
{
    return threadContext;
}

/// Set current thread context
void setLogContext(LogContext context) @system
{
    threadContext = context;
}

/// Clear current thread context
void clearLogContext() @system
{
    threadContext = LogContext.init;
}

/// Fluent log builder for structured logging
/// Usage: logger.info("event_name").field("key", value).field("key2", value2).emit()
struct LogBuilder
{
    private StructuredLogger logger;
    private LogLevel level;
    private string message;
    private string[string] fields;
    
    /// Add a field with auto-conversion
    ref LogBuilder field(T)(string key, T value) return @system
    {
        try { fields[key] = value.to!string; }
        catch (Exception) { fields[key] = "<error>"; }
        return this;
    }
    
    /// Add multiple fields from associative array
    ref LogBuilder withFields(string[string] f) return @system
    {
        foreach (k, v; f) fields[k] = v;
        return this;
    }
    
    /// Emit the log entry
    void emit() @system
    {
        if (logger !is null)
            logger.log(level, message, fields);
    }
}

/// Structured logger with per-target buffering
final class StructuredLogger
{
    private LogEntry[] entries;
    private LogEntry[][string] targetBuffers;
    private Mutex logMutex;
    private LogLevel minLevel;
    private bool enableBuffering;
    private size_t maxBufferSize;
    
    this(LogLevel minLevel = LogLevel.Info, bool enableBuffering = true, size_t maxBufferSize = 10_000) @system
    {
        this.logMutex = new Mutex();
        this.minLevel = minLevel;
        this.enableBuffering = enableBuffering;
        this.maxBufferSize = maxBufferSize;
    }
    
    /// Log a message with structured fields
    void log(LogLevel level, string message, string[string] fields = null) @system
    {
        if (level < minLevel)
            return;
        
        synchronized (logMutex)
        {
            auto ctx = getLogContext();
            
            LogEntry entry;
            entry.timestamp = Clock.currTime();
            entry.level = level;
            entry.message = message;
            entry.targetId = ctx.targetId;
            entry.threadId = cast(size_t)Thread.getThis().id;
            entry.correlationId = ctx.correlationId;
            entry.traceId = ctx.traceId;
            entry.spanId = ctx.spanId;
            
            // Merge context fields with provided fields
            foreach (key, value; ctx.fields)
                entry.fields[key] = value;
            if (fields !is null)
            {
                foreach (key, value; fields)
                    entry.fields[key] = value;
            }
            
            // Add to global entries
            if (entries.length < maxBufferSize)
                entries ~= entry;
            
            // Add to target buffer if buffering enabled
            if (enableBuffering && ctx.targetId.length > 0)
            {
                if (ctx.targetId !in targetBuffers)
                    targetBuffers[ctx.targetId] = [];
                
                if (targetBuffers[ctx.targetId].length < maxBufferSize)
                    targetBuffers[ctx.targetId] ~= entry;
            }
            
            // Always write to console for errors
            if (level >= LogLevel.Error)
            {
                stderr.writeln(entry.toString());
                stderr.flush();
            }
        }
    }
    
    /// Create trace log builder
    LogBuilder trace(string message) @system => LogBuilder(this, LogLevel.Trace, message, null);
    
    /// Create debug log builder
    LogBuilder debug_(string message) @system => LogBuilder(this, LogLevel.Debug, message, null);
    
    /// Create info log builder
    LogBuilder info(string message) @system => LogBuilder(this, LogLevel.Info, message, null);
    
    /// Create warning log builder
    LogBuilder warning(string message) @system => LogBuilder(this, LogLevel.Warning, message, null);
    
    /// Create error log builder
    LogBuilder error(string message) @system => LogBuilder(this, LogLevel.Error, message, null);
    
    /// Create critical log builder
    LogBuilder critical(string message) @system => LogBuilder(this, LogLevel.Critical, message, null);
    
    /// Log exception with context
    void exception(Exception e, string message = "") @system
    {
        string[string] fields;
        fields["exception.type"] = typeid(e).toString();
        fields["exception.message"] = e.msg;
        
        string msg = message.length > 0 ? message : e.msg;
        
        LogEntry entry;
        entry.timestamp = Clock.currTime();
        entry.level = LogLevel.Error;
        entry.message = msg;
        entry.fields = fields;
        
        // Try to get stack trace
        static if (__traits(compiles, e.info))
        {
            if (e.info)
                entry.stackTrace = e.info.toString();
        }
        
        synchronized (logMutex)
        {
            auto ctx = getLogContext();
            entry.targetId = ctx.targetId;
            entry.threadId = cast(size_t)Thread.getThis().id;
            entry.correlationId = ctx.correlationId;
            entry.traceId = ctx.traceId;
            entry.spanId = ctx.spanId;
            
            // Merge context fields
            foreach (key, value; ctx.fields)
            {
                entry.fields[key] = value;
            }
            
            if (entries.length < maxBufferSize)
            {
                entries ~= entry;
            }
            
            stderr.writeln(entry.toString());
            if (entry.stackTrace.length > 0)
            {
                stderr.writeln("Stack trace:");
                stderr.writeln(entry.stackTrace);
            }
            stderr.flush();
        }
    }
    
    /// Get all log entries
    LogEntry[] getEntries() const @system
    {
        synchronized (cast(Mutex)logMutex)
        {
            // Manually copy to avoid const issues
            import std.array : appender;
            auto result = appender!(LogEntry[]);
            result.reserve(entries.length);
            foreach (entry; entries)
            {
                result ~= entry;
            }
            return result.data;
        }
    }
    
    /// Get log entries for specific target
    Result!(LogEntry[], LogError) getTargetEntries(string targetId) const @system
    {
        synchronized (cast(Mutex)logMutex)
        {
            if (targetId !in targetBuffers)
                return Result!(LogEntry[], LogError).err(
                    LogError.targetNotFound(targetId));
            
            // Manually copy to avoid const issues
            import std.array : appender;
            auto result = appender!(LogEntry[]);
            auto buffer = targetBuffers[targetId];
            result.reserve(buffer.length);
            foreach (entry; buffer)
            {
                result ~= entry;
            }
            return Result!(LogEntry[], LogError).ok(result.data);
        }
    }
    
    /// Export logs as JSON
    Result!(string, LogError) exportJson() const @system
    {
        synchronized (cast(Mutex)logMutex)
        {
            try
            {
                JSONValue json;
                JSONValue[] entriesJson;
                
                foreach (entry; entries)
                {
                    entriesJson ~= entry.toJson();
                }
                
                json["entries"] = entriesJson;
                json["count"] = entries.length;
                
                return Result!(string, LogError).ok(json.toPrettyString());
            }
            catch (Exception e)
            {
                return Result!(string, LogError).err(
                    LogError.exportFailed(e.msg));
            }
        }
    }
    
    /// Export logs for specific target as JSON
    Result!(string, LogError) exportTargetJson(string targetId) const @system
    {
        synchronized (cast(Mutex)logMutex)
        {
            if (targetId !in targetBuffers)
                return Result!(string, LogError).err(
                    LogError.targetNotFound(targetId));
            
            try
            {
                JSONValue json;
                JSONValue[] entriesJson;
                
                foreach (entry; targetBuffers[targetId])
                {
                    entriesJson ~= entry.toJson();
                }
                
                json["targetId"] = targetId;
                json["entries"] = entriesJson;
                json["count"] = targetBuffers[targetId].length;
                
                return Result!(string, LogError).ok(json.toPrettyString());
            }
            catch (Exception e)
            {
                return Result!(string, LogError).err(
                    LogError.exportFailed(e.msg));
            }
        }
    }
    
    /// Save logs to file
    Result!LogError saveLogs(string filepath) const @system
    {
        import std.file : write;
        
        auto jsonResult = exportJson();
        if (jsonResult.isErr)
            return Result!LogError.err(jsonResult.unwrapErr());
        
        try
        {
            write(filepath, jsonResult.unwrap());
            return Result!LogError.ok();
        }
        catch (Exception e)
        {
            return Result!LogError.err(LogError.exportFailed(e.msg));
        }
    }
    
    /// Save target logs to file
    Result!LogError saveTargetLogs(string targetId, string filepath) const @system
    {
        import std.file : write;
        
        auto jsonResult = exportTargetJson(targetId);
        if (jsonResult.isErr)
            return Result!LogError.err(jsonResult.unwrapErr());
        
        try
        {
            write(filepath, jsonResult.unwrap());
            return Result!LogError.ok();
        }
        catch (Exception e)
        {
            return Result!LogError.err(LogError.exportFailed(e.msg));
        }
    }
    
    /// Clear all log entries
    void clear() @system
    {
        synchronized (logMutex)
        {
            entries = [];
            targetBuffers.clear();
        }
    }
    
    /// Set minimum log level
    void setMinLevel(LogLevel level) @system
    {
        synchronized (logMutex)
        {
            this.minLevel = level;
        }
    }
    
    /// Get statistics
    struct Stats
    {
        size_t totalEntries;
        size_t traceCount;
        size_t debugCount;
        size_t infoCount;
        size_t warningCount;
        size_t errorCount;
        size_t criticalCount;
        size_t targetsLogged;
    }
    
    /// Get logging statistics
    Stats getStats() const @system
    {
        synchronized (cast(Mutex)logMutex)
        {
            Stats stats;
            stats.totalEntries = entries.length;
            stats.targetsLogged = targetBuffers.length;
            
            foreach (entry; entries)
            {
                final switch (entry.level)
                {
                    case LogLevel.Trace:
                        stats.traceCount++;
                        break;
                    case LogLevel.Debug:
                        stats.debugCount++;
                        break;
                    case LogLevel.Info:
                        stats.infoCount++;
                        break;
                    case LogLevel.Warning:
                        stats.warningCount++;
                        break;
                    case LogLevel.Error:
                        stats.errorCount++;
                        break;
                    case LogLevel.Critical:
                        stats.criticalCount++;
                        break;
                }
            }
            
            return stats;
        }
    }
}

/// Log-specific errors
struct LogError
{
    string message;
    ErrorCode code;
    
    static LogError targetNotFound(string targetId) pure @system
    {
        return LogError("Target not found: " ~ targetId, Build.TargetNotFound);
    }
    
    static LogError exportFailed(string details) pure @system
    {
        return LogError("Export failed: " ~ details, IO.FileWriteFailed);
    }
    
    string toString() const pure nothrow @system
    {
        return message;
    }
}


/// Convenience function for scoped logging context
struct ScopedLogContext
{
    private LogContext previousContext;
    
    this(string targetId, string[string] fields = null) @system
    {
        previousContext = getLogContext();
        
        LogContext ctx;
        ctx.targetId = targetId;
        ctx.correlationId = previousContext.correlationId;
        
        // Merge fields
        foreach (key, value; previousContext.fields)
        {
            ctx.fields[key] = value;
        }
        if (fields !is null)
        {
            foreach (key, value; fields)
            {
                ctx.fields[key] = value;
            }
        }
        
        setLogContext(ctx);
    }
    
    ~this() @system
    {
        setLogContext(previousContext);
    }
    
    @disable this(this);
}

