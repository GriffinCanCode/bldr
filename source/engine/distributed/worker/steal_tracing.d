module engine.distributed.worker.steal_tracing;

import std.conv : to;
import std.datetime : Duration;
import infrastructure.telemetry.distributed.tracing;
import engine.distributed.protocol.protocol : WorkerId;

/// Work stealing tracing integration
/// Provides observability for distributed work stealing operations
struct StealTracing
{
    private Tracer tracer;
    
    this(Tracer tracer) @system { this.tracer = tracer; }
    
    /// Start span for steal attempt
    Span startStealAttempt(WorkerId thief, WorkerId victim) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("steal.attempt", SpanKind.Client);
        if (span !is null)
        {
            span.setAttribute("steal.thief", thief.value.to!string);
            span.setAttribute("steal.victim", victim.value.to!string);
        }
        return span;
    }
    
    /// Record successful steal
    void recordStealSuccess(Span span, string actionId, Duration latency) @system
    {
        if (span is null) return;
        
        span.setAttribute("steal.success", "true");
        span.setAttribute("steal.action_id", actionId);
        span.setAttribute("steal.latency_ms", latency.total!"msecs".to!string);
        span.setStatus(SpanStatus.Ok);
        span.addEvent("steal_succeeded");
    }
    
    /// Record failed steal (victim had no work)
    void recordStealEmpty(Span span, Duration latency) @system
    {
        if (span is null) return;
        
        span.setAttribute("steal.success", "false");
        span.setAttribute("steal.reason", "empty_queue");
        span.setAttribute("steal.latency_ms", latency.total!"msecs".to!string);
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Record steal error
    void recordStealError(Span span, string error) @system
    {
        if (span is null) return;
        
        span.setAttribute("steal.success", "false");
        span.setAttribute("steal.error", error);
        span.setStatus(SpanStatus.Error, error);
    }
    
    /// Start span for peer discovery
    Span startPeerDiscovery(WorkerId worker) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("steal.peer_discovery", SpanKind.Client);
        if (span !is null)
            span.setAttribute("steal.worker", worker.value.to!string);
        return span;
    }
    
    /// Record peer discovery results
    void recordPeersDiscovered(Span span, size_t peerCount) @system
    {
        if (span is null) return;
        span.setAttribute("steal.peers_found", peerCount.to!string);
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Start span for adaptive threshold tuning
    Span startAdaptiveUpdate() @system
    {
        if (tracer is null) return null;
        return tracer.startSpan("steal.adaptive_update", SpanKind.Internal);
    }
    
    /// Record adaptive threshold change
    void recordThresholdChange(Span span, double oldThreshold, double newThreshold, double successRate) @system
    {
        if (span is null) return;
        
        span.setAttribute("steal.old_threshold", oldThreshold.to!string);
        span.setAttribute("steal.new_threshold", newThreshold.to!string);
        span.setAttribute("steal.success_rate", successRate.to!string);
        span.addEvent("threshold_adjusted");
        span.setStatus(SpanStatus.Ok);
    }
    
    /// Finish span
    void finish(Span span) @system
    {
        if (tracer !is null && span !is null)
            tracer.finishSpan(span);
    }
}

/// Aggregate steal statistics for batch reporting
struct StealStatistics
{
    size_t attempts;
    size_t successes;
    size_t emptyQueue;
    size_t errors;
    Duration totalLatency;
    
    double successRate() const pure nothrow @safe @nogc =>
        attempts > 0 ? cast(double)successes / cast(double)attempts : 0.0;
    
    double avgLatencyMs() const pure nothrow @safe @nogc =>
        attempts > 0 ? cast(double)totalLatency.total!"msecs" / cast(double)attempts : 0.0;
    
    string[string] toAttributes() const pure @safe
    {
        string[string] attrs;
        attrs["steal.total_attempts"] = attempts.to!string;
        attrs["steal.total_successes"] = successes.to!string;
        attrs["steal.success_rate"] = successRate().to!string;
        attrs["steal.avg_latency_ms"] = avgLatencyMs().to!string;
        return attrs;
    }
}

