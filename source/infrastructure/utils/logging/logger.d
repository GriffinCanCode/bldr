module infrastructure.utils.logging.logger;

import std.stdio;
import std.datetime : SysTime, Clock;
import std.conv : to;
import std.format : format;
import std.array : appender;
import std.json : JSONValue;
import core.sync.mutex : Mutex;

/// Output format for log messages
enum LogFormat
{
    Console,  /// Colored human-readable output (default)
    Json,     /// JSON lines format for log aggregation (one JSON object per line)
    Logfmt    /// key=value format (popular with Prometheus/Grafana/Loki)
}

/// Structured log entry with key-value fields
struct LogFields
{
    private string[string] data;
    
    /// Build fields from key-value pairs
    static LogFields of(T...)(T args) pure nothrow @safe
    {
        static assert(args.length % 2 == 0, "Fields must be key-value pairs");
        
        LogFields fields;
        static foreach (i; 0 .. args.length / 2)
        {
            static if (__traits(compiles, args[i * 2].to!string))
                fields.data[args[i * 2].to!string] = args[i * 2 + 1].to!string;
        }
        return fields;
    }
    
    /// Add a field
    ref LogFields add(string key, string value) return pure nothrow @safe
    {
        data[key] = value;
        return this;
    }
    
    /// Add a field with auto-conversion
    ref LogFields add(T)(string key, T value) return nothrow @safe
    {
        try { data[key] = value.to!string; } catch (Exception) { data[key] = "<error>"; }
        return this;
    }
    
    /// Get underlying data
    @property const(string[string]) pairs() const pure nothrow @safe => data;
    
    /// Check if empty
    @property bool empty() const pure nothrow @safe => data.length == 0;
}

/// Simple logging utility with structured fields support
/// 
/// Supports three output formats:
/// - Console: Colored human-readable output (default)
/// - Json: JSON lines format for log aggregation
/// - Logfmt: key=value format for Prometheus/Grafana/Loki
class Logger
{
    private static __gshared
    {
        bool verbose = false;
        LogFormat outputFormat = LogFormat.Console;
        Mutex mutex;
        string serviceName = "builder";
    }
    
    shared static this()
    {
        mutex = new Mutex();
    }
    
    static void initialize() { }
    
    static void setVerbose(bool v) nothrow @nogc { verbose = v; }
    
    /// Set output format for all log messages
    @system static void setFormat(LogFormat fmt)
    {
        synchronized (mutex) { outputFormat = fmt; }
    }
    
    /// Set service name (included in structured output)
    @system static void setServiceName(string name)
    {
        synchronized (mutex) { serviceName = name; }
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // Core logging methods with structured fields
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Log info message with optional structured fields
    @system static void info(string msg, LogFields fields = LogFields.init)
    {
        writeLog("INFO", "\x1b[36m", msg, fields, stdout);
    }
    
    /// Log success message with optional structured fields
    @system static void success(string msg, LogFields fields = LogFields.init)
    {
        writeLog("SUCCESS", "\x1b[32m", msg, fields, stdout);
    }
    
    /// Log warning message with optional structured fields
    @system static void warning(string msg, LogFields fields = LogFields.init)
    {
        writeLog("WARNING", "\x1b[33m", msg, fields, stdout);
    }
    
    /// Log error message with optional structured fields
    @system static void error(string msg, LogFields fields = LogFields.init)
    {
        writeLog("ERROR", "\x1b[31m", msg, fields, stderr);
    }
    
    /// Log debug message with optional structured fields (only if verbose)
    @system static void debugLog(string msg, LogFields fields = LogFields.init)
    {
        if (verbose) writeLog("DEBUG", "\x1b[90m", msg, fields, stdout);
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // Convenience methods for inline field building
    // ─────────────────────────────────────────────────────────────────────────
    
    /// Log info with key-value pairs: Logger.infoKV("msg", "key1", val1, "key2", val2)
    @system static void infoKV(T...)(string msg, T fieldPairs)
    {
        info(msg, buildFields(fieldPairs));
    }
    
    /// Log warning with key-value pairs
    @system static void warningKV(T...)(string msg, T fieldPairs)
    {
        warning(msg, buildFields(fieldPairs));
    }
    
    /// Log error with key-value pairs
    @system static void errorKV(T...)(string msg, T fieldPairs)
    {
        error(msg, buildFields(fieldPairs));
    }
    
    /// Log debug with key-value pairs
    @system static void debugKV(T...)(string msg, T fieldPairs)
    {
        debugLog(msg, buildFields(fieldPairs));
    }
    
    // ─────────────────────────────────────────────────────────────────────────
    // Internal formatting
    // ─────────────────────────────────────────────────────────────────────────
    
    private static LogFields buildFields(T...)(T args)
    {
        static assert(args.length % 2 == 0, "Fields must be key-value pairs");
        
        LogFields fields;
        static foreach (i; 0 .. args.length / 2)
        {{
            enum idx = i * 2;
            try
            {
                fields.data[args[idx].to!string] = args[idx + 1].to!string;
            }
            catch (Exception) { }
        }}
        return fields;
    }
    
    @system private static void writeLog(
        string level, 
        string color, 
        string msg, 
        LogFields fields, 
        File output
    ) {
        synchronized (mutex)
        {
            immutable timestamp = Clock.currTime();
            
            final switch (outputFormat)
            {
                case LogFormat.Console:
                    writeConsole(level, color, msg, fields, output);
                    break;
                case LogFormat.Json:
                    writeJson(level, timestamp, msg, fields, output);
                    break;
                case LogFormat.Logfmt:
                    writeLogfmt(level, timestamp, msg, fields, output);
                    break;
            }
            output.flush();
        }
    }
    
    /// Console format: colored human-readable
    @system private static void writeConsole(
        string level, 
        string color, 
        string msg, 
        LogFields fields, 
        File output
    ) {
        enum reset = "\x1b[0m";
        
        if (fields.empty)
        {
            output.writeln(color, "[", level, "]", reset, " ", msg);
        }
        else
        {
            auto buf = appender!string;
            buf ~= format("%s[%s]%s %s", color, level, reset, msg);
            buf ~= " \x1b[90m{";  // Gray for fields
            size_t i = 0;
            foreach (key, value; fields.pairs)
            {
                if (i++ > 0) buf ~= ", ";
                buf ~= format("%s=%s", key, value);
            }
            buf ~= "}\x1b[0m";
            output.writeln(buf.data);
        }
    }
    
    /// JSON format: one JSON object per line (JSON Lines / NDJSON)
    @system private static void writeJson(
        string level, 
        SysTime timestamp, 
        string msg, 
        LogFields fields, 
        File output
    ) {
        JSONValue json;
        json["ts"] = timestamp.toISOExtString();
        json["level"] = level;
        json["msg"] = msg;
        json["service"] = serviceName;
        
        if (!fields.empty)
        {
            JSONValue fieldsJson;
            foreach (key, value; fields.pairs)
                fieldsJson[key] = value;
            json["fields"] = fieldsJson;
        }
        
        output.writeln(json.toString());  // Single-line JSON
    }
    
    /// Logfmt format: key=value pairs (Grafana/Loki/Prometheus friendly)
    @system private static void writeLogfmt(
        string level, 
        SysTime timestamp, 
        string msg, 
        LogFields fields, 
        File output
    ) {
        auto buf = appender!string;
        buf ~= format("ts=%s level=%s service=%s msg=\"%s\"",
            timestamp.toISOExtString(),
            level,
            serviceName,
            escapeLogfmt(msg));
        
        foreach (key, value; fields.pairs)
        {
            buf ~= format(" %s=\"%s\"", key, escapeLogfmt(value));
        }
        
        output.writeln(buf.data);
    }
    
    /// Escape special characters for logfmt
    private static string escapeLogfmt(string s) pure @safe
    {
        import std.string : replace;
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }
}

/// Convenience alias for field building
alias F = LogFields.of;
