module engine.workers.tracing;

import std.conv : to;
import std.datetime : Duration;
import infrastructure.telemetry.distributed.tracing;

/// Persistent worker tracing integration
/// Provides observability for JVM, TypeScript, Rust, Go, and Python workers
struct WorkerTracing
{
    private Tracer tracer;
    
    this(Tracer tracer) @system { this.tracer = tracer; }
    
    /// Start span for worker request
    Span startWorkerRequest(string workerType, string requestId, Span parent = null) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("worker.request", SpanKind.Client, parent);
        if (span !is null)
        {
            span.setAttribute("worker.type", workerType);
            span.setAttribute("worker.request_id", requestId);
            span.setAttribute("worker.protocol", "bazel_persistent");
        }
        return span;
    }
    
    /// Start span for worker spawn
    Span startWorkerSpawn(string workerType, string[] command) @system
    {
        if (tracer is null) return null;
        
        import std.algorithm : joiner;
        import std.array : array;
        
        auto span = tracer.startSpan("worker.spawn", SpanKind.Internal);
        if (span !is null)
        {
            span.setAttribute("worker.type", workerType);
            span.setAttribute("worker.command", command.joiner(" ").array.to!string);
            span.addEvent("spawning");
        }
        return span;
    }
    
    /// Start span for worker health check
    Span startHealthCheck(string workerType, string workerId) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("worker.health", SpanKind.Internal);
        if (span !is null)
        {
            span.setAttribute("worker.type", workerType);
            span.setAttribute("worker.id", workerId);
        }
        return span;
    }
    
    /// Record successful worker response
    void recordSuccess(Span span, Duration duration, int exitCode = 0) @system
    {
        if (span is null) return;
        span.setAttribute("worker.duration_ms", duration.total!"msecs".to!string);
        span.setAttribute("worker.exit_code", exitCode.to!string);
        span.setAttribute("worker.success", "true");
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Record worker failure
    void recordFailure(Span span, string error, int exitCode = -1) @system
    {
        if (span is null) return;
        span.setAttribute("worker.error", error);
        span.setAttribute("worker.exit_code", exitCode.to!string);
        span.setAttribute("worker.success", "false");
        span.setStatus(SpanStatus.Error, error);
    }
    
    /// Record worker restart
    void recordRestart(Span span, string reason) @system
    {
        if (span is null) return;
        span.addEvent("worker.restarted", ["reason": reason]);
    }
    
    /// Record worker pool stats
    void recordPoolStats(Span span, size_t active, size_t idle, size_t total) @system
    {
        if (span is null) return;
        span.setAttribute("worker.pool.active", active.to!string);
        span.setAttribute("worker.pool.idle", idle.to!string);
        span.setAttribute("worker.pool.total", total.to!string);
    }
    
    /// Finish span
    void finish(Span span) @system
    {
        if (tracer !is null && span !is null)
            tracer.finishSpan(span);
    }
}

/// Worker type constants for consistent attribute values
enum WorkerType : string
{
    JVM = "jvm",
    TypeScript = "typescript",
    Rust = "rust",
    Go = "go",
    Python = "python"
}

/// Calculate JIT warmup savings for logging
struct WarmupStats
{
    size_t coldStartMs;
    size_t warmStartMs;
    
    double speedup() const pure nothrow @safe @nogc =>
        coldStartMs > 0 ? cast(double)coldStartMs / cast(double)(warmStartMs > 0 ? warmStartMs : 1) : 1.0;
    
    string[string] toAttributes() const pure @safe
    {
        string[string] attrs;
        attrs["worker.cold_start_ms"] = coldStartMs.to!string;
        attrs["worker.warm_start_ms"] = warmStartMs.to!string;
        attrs["worker.speedup"] = speedup().to!string ~ "x";
        return attrs;
    }
}

