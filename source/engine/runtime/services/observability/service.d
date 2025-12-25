module engine.runtime.services.observability.service;

import frontend.cli.events.events;
import infrastructure.telemetry.distributed.tracing : Tracer, Span, SpanKind, SpanStatus;
import infrastructure.utils.logging.structured : StructuredLogger, LogLevel;
import infrastructure.errors;

/// Observability service interface
/// Unifies events, tracing, and structured logging behind single interface
interface IObservabilityService
{
    /// Publish a build event
    void publishEvent(BuildEvent event);
    
    /// Start a new span for distributed tracing
    Span startSpan(string name, SpanKind kind, Span parent = null);
    
    /// Finish a span
    void finishSpan(Span span);
    
    /// Log info message with optional structured fields
    void logInfo(string message, string[string] fields = null);
    
    /// Log debug message
    void logDebug(string message, string[string] fields = null);
    
    /// Log error message
    void logError(string message, string[string] fields = null);
    
    /// Log exception
    void logException(Exception e, string message = "");
    
    /// Flush all observability outputs
    void flush();
    
    /// Start a new distributed trace
    void startTrace();
    
    /// Set span status
    void setSpanStatus(Span span, SpanStatus status, string description = "");
    
    /// Record exception on span
    void recordException(Span span, Exception e);
    
    /// Add event to span
    void addSpanEvent(Span span, string name, string[string] attributes = null);
    
    /// Set span attribute
    void setSpanAttribute(Span span, string key, string value);
    
    /// Get tracer for direct access (for passing to BuildContext)
    @property Tracer tracer();
    
    /// Get structured logger for direct access (for passing to BuildContext)
    @property StructuredLogger logger();
    
    /// Get current trace ID (for event correlation and display)
    string getCurrentTraceId();
}

/// Concrete observability service implementation
final class ObservabilityService : IObservabilityService
{
    private EventPublisher eventPublisher;
    private Tracer _tracer;
    private StructuredLogger _structuredLogger;
    
    this(EventPublisher eventPublisher = null, 
         Tracer tracer = null,
         StructuredLogger structuredLogger = null)
    {
        // Use provided dependencies (no global fallbacks)
        this.eventPublisher = eventPublisher;
        this._tracer = tracer;
        this._structuredLogger = structuredLogger;
    }
    
    void publishEvent(BuildEvent event) @trusted
    {
        if (eventPublisher !is null)
        {
            eventPublisher.publish(event);
        }
    }
    
    Span startSpan(string name, SpanKind kind, Span parent = null) @trusted
    {
        return _tracer.startSpan(name, kind, parent);
    }
    
    void finishSpan(Span span) @trusted
    {
        _tracer.finishSpan(span);
    }
    
    void logInfo(string message, string[string] fields = null) @trusted
    {
        string[string] f = fields is null ? (string[string]).init : fields;
        _structuredLogger.info(message, f);
    }
    
    void logDebug(string message, string[string] fields = null) @trusted
    {
        string[string] f = fields is null ? (string[string]).init : fields;
        _structuredLogger.debug_(message, f);
    }
    
    void logError(string message, string[string] fields = null) @trusted
    {
        string[string] f = fields is null ? (string[string]).init : fields;
        _structuredLogger.error(message, f);
    }
    
    void logException(Exception e, string message = "") @trusted
    {
        _structuredLogger.exception(e, message);
    }
    
    void flush() @trusted
    {
        _tracer.flush();
    }
    
    void startTrace() @trusted
    {
        _tracer.startTrace();
    }
    
    void setSpanStatus(Span span, SpanStatus status, string description = "") @trusted
    {
        span.setStatus(status, description);
    }
    
    void recordException(Span span, Exception e) @trusted
    {
        span.recordException(e);
    }
    
    void addSpanEvent(Span span, string name, string[string] attributes = null) @trusted
    {
        attributes is null ? span.addEvent(name) : span.addEvent(name, attributes);
    }
    
    void setSpanAttribute(Span span, string key, string value) @trusted
    {
        span.setAttribute(key, value);
    }
    
    @property Tracer tracer() @trusted
    {
        return this._tracer;
    }
    
    @property StructuredLogger logger() @trusted
    {
        return this._structuredLogger;
    }
    
    string getCurrentTraceId() @trusted
    {
        if (_tracer is null) return "";
        auto ctx = _tracer.getContextForPropagation();
        return ctx.traceId.toString();
    }
}

/// Null observability service for testing/disabled observability
final class NullObservabilityService : IObservabilityService
{
    private static Span nullSpan;
    
    shared static this()
    {
        import infrastructure.telemetry.distributed.tracing : TraceId, SpanId;
        nullSpan = new Span(TraceId(), SpanId(), SpanId(), "null", SpanKind.Internal);
    }
    
    @trusted {
        void publishEvent(BuildEvent event) { }
        Span startSpan(string name, SpanKind kind, Span parent = null) { return nullSpan; }
        void finishSpan(Span span) { }
        void logInfo(string message, string[string] fields = null) { }
        void logDebug(string message, string[string] fields = null) { }
        void logError(string message, string[string] fields = null) { }
        void logException(Exception e, string message = "") { }
        void flush() { }
        void startTrace() { }
        void setSpanStatus(Span span, SpanStatus status, string description = "") { }
        void recordException(Span span, Exception e) { }
        void addSpanEvent(Span span, string name, string[string] attributes = null) { }
        void setSpanAttribute(Span span, string key, string value) { }
        @property Tracer tracer() { return null; }
        @property StructuredLogger logger() { return null; }
        string getCurrentTraceId() { return ""; }
    }
}

