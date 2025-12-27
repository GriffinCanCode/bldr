module engine.caching.distributed.remote.tracing;

import std.conv : to;
import std.datetime : Duration;
import infrastructure.telemetry.distributed.tracing;

/// Remote cache tracing integration
/// Provides span instrumentation for cache operations
struct CacheTracing
{
    private Tracer tracer;
    
    this(Tracer tracer) @system { this.tracer = tracer; }
    
    /// Start span for cache GET operation
    Span startGet(string contentHash, Span parent = null) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("cache.get", SpanKind.Client, parent);
        if (span !is null)
        {
            span.setAttribute("cache.operation", "get");
            span.setAttribute("cache.key", contentHash);
            span.setAttribute("cache.type", "remote");
        }
        return span;
    }
    
    /// Start span for cache PUT operation
    Span startPut(string contentHash, size_t size, Span parent = null) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("cache.put", SpanKind.Client, parent);
        if (span !is null)
        {
            span.setAttribute("cache.operation", "put");
            span.setAttribute("cache.key", contentHash);
            span.setAttribute("cache.size_bytes", size.to!string);
            span.setAttribute("cache.type", "remote");
        }
        return span;
    }
    
    /// Start span for cache existence check
    Span startHas(string contentHash, Span parent = null) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("cache.has", SpanKind.Client, parent);
        if (span !is null)
        {
            span.setAttribute("cache.operation", "has");
            span.setAttribute("cache.key", contentHash);
            span.setAttribute("cache.type", "remote");
        }
        return span;
    }
    
    /// Record cache hit on span
    void recordHit(Span span, size_t bytesTransferred = 0) @system
    {
        if (span is null) return;
        span.setAttribute("cache.hit", "true");
        if (bytesTransferred > 0)
            span.setAttribute("cache.bytes_transferred", bytesTransferred.to!string);
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Record cache miss on span
    void recordMiss(Span span) @system
    {
        if (span is null) return;
        span.setAttribute("cache.hit", "false");
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Record error on span
    void recordError(Span span, string error) @system
    {
        if (span is null) return;
        span.setAttribute("cache.error", error);
        span.setStatus(SpanStatus.Error, error);
    }
    
    /// Finish span
    void finish(Span span) @system
    {
        if (tracer !is null && span !is null)
            tracer.finishSpan(span);
    }
}

/// Trace cache operation with automatic span management
auto traceCacheOp(T)(
    CacheTracing tracing,
    string opName,
    string key,
    Span parent,
    T delegate() @system operation
) @system
{
    Span span;
    if (opName == "get")
        span = tracing.startGet(key, parent);
    else if (opName == "put")
        span = tracing.startPut(key, 0, parent);
    else
        span = tracing.startHas(key, parent);
    
    scope(exit) tracing.finish(span);
    
    try
    {
        auto result = operation();
        static if (is(T == bool))
        {
            if (result)
                tracing.recordHit(span);
            else
                tracing.recordMiss(span);
        }
        return result;
    }
    catch (Exception e)
    {
        tracing.recordError(span, e.msg);
        throw e;
    }
}

