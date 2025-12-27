module engine.distributed.worker.tracing;

import std.datetime : Duration;
import std.conv : to;
import core.time : MonoTime;
import engine.distributed.protocol.protocol;
import infrastructure.telemetry.distributed.tracing;

/// Distributed build tracing integration
/// Creates and manages spans for build actions executed on workers
/// 
/// Provides proper parent-child relationships:
/// - Coordinator span (build-execute) -> Action span (on worker)
/// - Action span -> Fetch, Execute, Upload child spans
struct DistributedTracing
{
    private Tracer tracer;
    
    /// Initialize with tracer
    this(Tracer tracer) @system
    {
        this.tracer = tracer;
    }
    
    /// Start span for action execution, using propagated trace context
    ActionSpan startActionSpan(ActionRequest request, string workerName = "") @system
    {
        if (tracer is null)
            return ActionSpan.init;
        
        // Create span from propagated context if available
        Span span;
        if (request.traceContext.isValid())
        {
            // Use propagated trace context - this action is a child of coordinator span
            auto traceId = TraceId(request.traceContext.traceIdHigh, request.traceContext.traceIdLow);
            auto parentSpanId = SpanId(request.traceContext.parentSpanId);
            
            span = tracer.startSpanFromContext(
                "action." ~ request.command[0 .. min(request.command.length, 64)],
                traceId,
                parentSpanId,
                request.traceContext.sampled,
                SpanKind.Server  // Worker receives work, so it's a server
            );
        }
        else
        {
            // No trace context, start new trace
            tracer.startTrace();
            span = tracer.startSpan("action.execute", SpanKind.Internal);
        }
        
        if (span !is null)
        {
            // Add semantic attributes per OpenTelemetry conventions
            span.setAttribute("builder.action.id", request.id.toString());
            span.setAttribute("builder.action.command", request.command);
            span.setAttribute("builder.action.priority", request.priority.to!string);
            span.setAttribute("builder.action.timeout_ms", request.timeout.total!"msecs".to!string);
            span.setAttribute("builder.action.inputs", request.inputs.length.to!string);
            span.setAttribute("builder.action.outputs", request.outputs.length.to!string);
            
            if (workerName.length > 0)
                span.setAttribute("builder.worker.name", workerName);
        }
        
        return ActionSpan(tracer, span);
    }
    
    /// Create trace context for outgoing action request
    DistributedTraceContext createContextForAction() @system
    {
        if (tracer is null)
            return DistributedTraceContext.init;
        
        auto ctx = tracer.getContextForPropagation();
        
        DistributedTraceContext distCtx;
        distCtx.traceIdHigh = ctx.traceId.high;
        distCtx.traceIdLow = ctx.traceId.low;
        distCtx.parentSpanId = ctx.spanId.value;
        distCtx.sampled = ctx.sampled;
        
        return distCtx;
    }
    
    private size_t min(size_t a, size_t b) pure nothrow @safe @nogc
    {
        return a < b ? a : b;
    }
}

/// Action span wrapper with automatic child span creation
struct ActionSpan
{
    private Tracer tracer;
    private Span span;
    
    /// Create fetch child span
    Span startFetchSpan(string artifactId) @system
    {
        if (tracer is null || span is null)
            return null;
        
        auto fetchSpan = tracer.startSpan("action.fetch", SpanKind.Client, span);
        if (fetchSpan !is null)
        {
            fetchSpan.setAttribute("builder.artifact.id", artifactId);
            fetchSpan.setAttribute("builder.phase", "input_fetch");
        }
        return fetchSpan;
    }
    
    /// Create sandbox preparation child span
    Span startSandboxSpan() @system
    {
        if (tracer is null || span is null)
            return null;
        
        auto sandboxSpan = tracer.startSpan("action.sandbox.prepare", SpanKind.Internal, span);
        if (sandboxSpan !is null)
            sandboxSpan.setAttribute("builder.phase", "sandbox_prepare");
        return sandboxSpan;
    }
    
    /// Create execution child span
    Span startExecuteSpan(string command) @system
    {
        if (tracer is null || span is null)
            return null;
        
        auto execSpan = tracer.startSpan("action.exec", SpanKind.Internal, span);
        if (execSpan !is null)
        {
            execSpan.setAttribute("builder.phase", "execute");
            execSpan.setAttribute("builder.command", command);
        }
        return execSpan;
    }
    
    /// Create upload child span
    Span startUploadSpan(string artifactId) @system
    {
        if (tracer is null || span is null)
            return null;
        
        auto uploadSpan = tracer.startSpan("action.upload", SpanKind.Client, span);
        if (uploadSpan !is null)
        {
            uploadSpan.setAttribute("builder.artifact.id", artifactId);
            uploadSpan.setAttribute("builder.phase", "output_upload");
        }
        return uploadSpan;
    }
    
    /// Record success
    void recordSuccess(Duration duration, int outputCount) @system
    {
        if (span is null)
            return;
        
        span.setStatus(SpanStatus.Ok);
        span.setAttribute("builder.action.duration_ms", duration.total!"msecs".to!string);
        span.setAttribute("builder.action.output_count", outputCount.to!string);
        span.addEvent("action.completed");
    }
    
    /// Record failure
    void recordFailure(string error, int exitCode = 0) @system
    {
        if (span is null)
            return;
        
        span.setStatus(SpanStatus.Error, error);
        span.setAttribute("builder.error", error);
        if (exitCode != 0)
            span.setAttribute("builder.exit_code", exitCode.to!string);
        span.addEvent("action.failed", ["error": error]);
    }
    
    /// Record exception
    void recordException(Exception e) @system
    {
        if (span is null)
            return;
        
        span.recordException(e);
    }
    
    /// Finish span
    void finish() @system
    {
        if (tracer !is null && span !is null)
            tracer.finishSpan(span);
    }
    
    /// Check if tracing is active
    bool isActive() const @system
    {
        return span !is null;
    }
    
    /// Finish child span
    void finishChild(Span childSpan) @system
    {
        if (tracer !is null && childSpan !is null)
            tracer.finishSpan(childSpan);
    }
}

/// Create trace context for coordinator to inject into action requests
DistributedTraceContext createTraceContextForAction(Tracer tracer) @system
{
    if (tracer is null)
        return DistributedTraceContext.init;
    
    auto ctx = tracer.getContextForPropagation();
    
    DistributedTraceContext distCtx;
    distCtx.traceIdHigh = ctx.traceId.high;
    distCtx.traceIdLow = ctx.traceId.low;
    distCtx.parentSpanId = ctx.spanId.value;
    distCtx.sampled = ctx.sampled;
    
    return distCtx;
}

