module engine.workers.protocol.types;

import std.json;
import std.conv;
import std.array;
import std.algorithm;
import std.datetime : Duration, msecs, seconds, MonoTime;

/// Persistent Worker Protocol - Bazel-compatible implementation
/// This reduces per-action overhead for warm compilers (JVM, TypeScript)
/// 
/// Protocol overview:
/// 1. Worker process starts and stays running between actions
/// 2. Build system sends WorkRequest via stdin (newline-delimited JSON)
/// 3. Worker processes request and sends WorkResponse via stdout
/// 4. Worker remains alive for subsequent requests

/// Worker request sent to persistent compiler process
struct WorkRequest
{
    /// Unique request identifier for correlation
    uint requestId;
    
    /// Arguments to pass to the compiler (file paths, flags, etc.)
    string[] arguments;
    
    /// Input files with their digests for change detection
    InputFile[] inputs;
    
    /// Sandbox directory for hermetic execution
    string sandboxDir;
    
    /// Verbosity level (0=quiet, 1=normal, 2=verbose)
    int verbosity;
    
    /// Whether to cancel this request
    bool cancel;
    
    /// Convert to JSON for protocol transmission
    string toJson() const @trusted
    {
        JSONValue j;
        j["request_id"] = requestId;
        j["arguments"] = arguments.map!(a => JSONValue(a)).array;
        j["inputs"] = inputs.map!(i => i.toJsonValue()).array;
        j["sandbox_dir"] = sandboxDir;
        j["verbosity"] = verbosity;
        j["cancel"] = cancel;
        return j.toString();
    }
    
    /// Parse from JSON response
    static WorkRequest fromJson(string json) @trusted
    {
        auto j = parseJSON(json);
        WorkRequest req;
        req.requestId = cast(uint)j["request_id"].integer;
        req.arguments = j["arguments"].array.map!(a => a.str).array;
        
        if ("inputs" in j && j["inputs"].type == JSONType.array)
            req.inputs = j["inputs"].array.map!(i => InputFile.fromJsonValue(i)).array;
        
        if ("sandbox_dir" in j) req.sandboxDir = j["sandbox_dir"].str;
        if ("verbosity" in j) req.verbosity = cast(int)j["verbosity"].integer;
        if ("cancel" in j) req.cancel = j["cancel"].boolean;
        
        return req;
    }
}

/// Input file with content digest for caching
struct InputFile
{
    string path;
    string digest;  // BLAKE3 hash
    
    JSONValue toJsonValue() const @trusted
    {
        JSONValue j;
        j["path"] = path;
        j["digest"] = digest;
        return j;
    }
    
    static InputFile fromJsonValue(JSONValue j) @trusted
    {
        InputFile f;
        f.path = j["path"].str;
        f.digest = ("digest" in j) ? j["digest"].str : "";
        return f;
    }
}

/// Worker response from persistent compiler process
struct WorkResponse
{
    /// Request ID this response correlates to
    uint requestId;
    
    /// Exit code (0 = success)
    int exitCode;
    
    /// Combined stdout/stderr output
    string output;
    
    /// Whether this was a cached response
    bool wasCached;
    
    /// Execution time in milliseconds
    long executionTimeMs;
    
    /// Output files produced
    OutputFile[] outputs;
    
    /// Convert to JSON for protocol transmission
    string toJson() const @trusted
    {
        JSONValue j;
        j["request_id"] = requestId;
        j["exit_code"] = exitCode;
        j["output"] = output;
        j["was_cached"] = wasCached;
        j["execution_time_ms"] = executionTimeMs;
        j["outputs"] = outputs.map!(o => o.toJsonValue()).array;
        return j.toString();
    }
    
    /// Parse from JSON response
    static WorkResponse fromJson(string json) @trusted
    {
        auto j = parseJSON(json);
        WorkResponse resp;
        resp.requestId = cast(uint)j["request_id"].integer;
        resp.exitCode = cast(int)j["exit_code"].integer;
        resp.output = ("output" in j) ? j["output"].str : "";
        resp.wasCached = ("was_cached" in j) ? j["was_cached"].boolean : false;
        resp.executionTimeMs = ("execution_time_ms" in j) ? j["execution_time_ms"].integer : 0;
        
        if ("outputs" in j && j["outputs"].type == JSONType.array)
            resp.outputs = j["outputs"].array.map!(o => OutputFile.fromJsonValue(o)).array;
        
        return resp;
    }
    
    /// Check if successful
    bool success() const pure nothrow @safe @nogc
    {
        return exitCode == 0;
    }
}

/// Output file produced by compilation
struct OutputFile
{
    string path;
    string digest;
    
    JSONValue toJsonValue() const @trusted
    {
        JSONValue j;
        j["path"] = path;
        j["digest"] = digest;
        return j;
    }
    
    static OutputFile fromJsonValue(JSONValue j) @trusted
    {
        OutputFile f;
        f.path = j["path"].str;
        f.digest = ("digest" in j) ? j["digest"].str : "";
        return f;
    }
}

/// Worker state
enum WorkerState
{
    Starting,     /// Process is starting up
    Ready,        /// Ready to accept work
    Busy,         /// Processing a request
    Idle,         /// Idle, may be evicted
    Terminating,  /// Shutting down
    Dead          /// Process has died
}

/// Worker statistics for monitoring
struct WorkerStats
{
    uint totalRequests;
    uint successfulRequests;
    uint failedRequests;
    long totalExecutionTimeMs;
    long avgExecutionTimeMs;
    MonoTime lastActivityTime;
    Duration idleTime;
    size_t memoryUsageBytes;
    
    /// Calculate cache hit rate
    float hitRate() const pure nothrow @safe @nogc
    {
        return totalRequests > 0 ? cast(float)successfulRequests / totalRequests : 0.0f;
    }
    
    /// Update with new execution
    void recordExecution(bool success, long execTimeMs) @safe
    {
        totalRequests++;
        if (success) successfulRequests++;
        else failedRequests++;
        totalExecutionTimeMs += execTimeMs;
        avgExecutionTimeMs = totalExecutionTimeMs / totalRequests;
        lastActivityTime = MonoTime.currTime;
    }
}

/// Worker capabilities/requirements
struct WorkerCapabilities
{
    string compilerType;     /// "javac", "kotlinc", "tsc", "swc", etc.
    string compilerVersion;  /// Version string
    string[] supportedFlags; /// Supported compiler flags
    bool supportsStreaming;  /// Can stream partial results
    bool supportsCancel;     /// Can cancel in-flight requests
    size_t maxConcurrent;    /// Max concurrent requests (usually 1)
}

/// Worker configuration
struct PersistentWorkerConfig
{
    string executable;           /// Path to compiler executable
    string[] baseArgs;           /// Base arguments (e.g., ["--persistent_worker"])
    Duration startupTimeout = seconds(30);
    Duration requestTimeout = seconds(300);
    Duration idleTimeout = seconds(60);
    size_t maxRequests = 1000;   /// Max requests before restart
    bool enableMultiplexing;     /// Allow multiple concurrent requests
    string workDir;              /// Working directory
    string[string] environment;  /// Environment variables
}

/// Worker identification
struct WorkerId
{
    string type;      /// "jvm", "typescript", etc.
    uint instanceId;  /// Instance number
    
    string toString() const pure @safe
    {
        return type ~ "-" ~ instanceId.to!string;
    }
}

