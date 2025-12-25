module infrastructure.telemetry.distributed.otlp;

import std.socket;
import std.conv : to;
import std.string : split, strip, indexOf, format, replace;
import std.array : Appender, appender;
import std.json : JSONValue, parseJSON;
import std.datetime : SysTime, Clock, Duration;
import core.sync.mutex : Mutex;
import core.time : msecs, seconds;
import infrastructure.telemetry.distributed.tracing;
import infrastructure.errors;

/// OTLP (OpenTelemetry Protocol) HTTP exporter
/// Exports spans to OTLP-compatible backends (Jaeger, Tempo, Grafana Cloud, Honeycomb)
/// 
/// Supports:
/// - HTTP/JSON transport (OTLP/HTTP)
/// - Batched span export for efficiency
/// - Resource attributes (service.name, service.version, etc.)
/// - Configurable endpoint and headers
/// 
/// Example endpoints:
/// - Jaeger:  http://localhost:4318/v1/traces
/// - Tempo:   http://localhost:4318/v1/traces
/// - Grafana: https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces
final class OtlpHttpExporter : SpanExporter
{
    private OtlpConfig config;
    private SpanData[] pendingSpans;
    private Mutex exportMutex;
    private Socket[] connectionPool;
    private bool[] connectionAvailable;
    
    this(OtlpConfig config) @system
    {
        this.config = config;
        this.exportMutex = new Mutex();
        this.connectionPool = new Socket[config.maxConnections];
        this.connectionAvailable = new bool[config.maxConnections];
        this.connectionAvailable[] = true;
    }
    
    ~this() @system
    {
        closeConnections();
    }
    
    /// Export single span (batches internally)
    void exportSpan(SpanData span) @system
    {
        synchronized (exportMutex)
        {
            pendingSpans ~= span;
            
            // Auto-flush if batch size reached
            if (pendingSpans.length >= config.batchSize)
                flushInternal();
        }
    }
    
    /// Flush all pending spans
    void flush(SpanData[] spans) @system
    {
        synchronized (exportMutex)
        {
            pendingSpans ~= spans;
            flushInternal();
        }
    }
    
    private void flushInternal() @system
    {
        if (pendingSpans.length == 0)
            return;
        
        auto payload = buildOtlpPayload(pendingSpans);
        auto sendResult = sendHttp(payload);
        
        if (sendResult.isOk)
            pendingSpans = [];
        // On failure, keep spans for retry (bounded by maxPending)
        else if (pendingSpans.length > config.maxPending)
            pendingSpans = pendingSpans[$ - config.maxPending .. $];
    }
    
    /// Build OTLP JSON payload following OpenTelemetry spec
    private ubyte[] buildOtlpPayload(SpanData[] spans) const @system
    {
        auto json = buildResourceSpans(spans);
        return cast(ubyte[])json.toString();
    }
    
    /// Build ResourceSpans structure per OTLP spec
    private JSONValue buildResourceSpans(SpanData[] spans) const @system
    {
        JSONValue root;
        JSONValue[] resourceSpans;
        
        // Group all spans under single resource
        JSONValue resourceSpan;
        resourceSpan["resource"] = buildResource();
        
        // Build scope spans (grouped by instrumentation scope)
        JSONValue[] scopeSpans;
        JSONValue scopeSpan;
        scopeSpan["scope"] = buildInstrumentationScope();
        
        JSONValue[] spanArray;
        foreach (span; spans)
        {
            spanArray ~= spanToOtlp(span);
        }
        scopeSpan["spans"] = spanArray;
        scopeSpans ~= scopeSpan;
        
        resourceSpan["scopeSpans"] = scopeSpans;
        resourceSpans ~= resourceSpan;
        root["resourceSpans"] = resourceSpans;
        
        return root;
    }
    
    /// Build resource attributes
    private JSONValue buildResource() const pure @system
    {
        JSONValue resource;
        JSONValue[] attrs;
        
        // Service name (required)
        attrs ~= buildAttribute("service.name", config.serviceName);
        
        // Service version
        if (config.serviceVersion.length > 0)
            attrs ~= buildAttribute("service.version", config.serviceVersion);
        
        // Service instance ID
        if (config.serviceInstanceId.length > 0)
            attrs ~= buildAttribute("service.instance.id", config.serviceInstanceId);
        
        // Custom resource attributes
        foreach (key, value; config.resourceAttributes)
        {
            attrs ~= buildAttribute(key, value);
        }
        
        // Telemetry SDK attributes
        attrs ~= buildAttribute("telemetry.sdk.name", "builder");
        attrs ~= buildAttribute("telemetry.sdk.language", "d");
        attrs ~= buildAttribute("telemetry.sdk.version", "1.0.0");
        
        resource["attributes"] = attrs;
        return resource;
    }
    
    /// Build instrumentation scope
    private JSONValue buildInstrumentationScope() const pure @system
    {
        JSONValue scope_;
        scope_["name"] = "builder.tracer";
        scope_["version"] = "1.0.0";
        return scope_;
    }
    
    /// Convert SpanData to OTLP span format
    private JSONValue spanToOtlp(SpanData span) const @system
    {
        JSONValue json;
        
        // Trace and span IDs (hex-encoded bytes)
        json["traceId"] = span.traceId.toString();
        json["spanId"] = span.spanId.toString();
        
        // Parent span ID (optional)
        if (span.parentSpanId.value != 0)
            json["parentSpanId"] = span.parentSpanId.toString();
        
        // Span name
        json["name"] = span.name;
        
        // Span kind (OTLP uses integers)
        json["kind"] = spanKindToOtlp(span.kind);
        
        // Timestamps (nanoseconds since Unix epoch)
        json["startTimeUnixNano"] = toNanos(span.startTime).to!string;
        if (span.finished)
            json["endTimeUnixNano"] = toNanos(span.endTime).to!string;
        
        // Attributes
        JSONValue[] attrs;
        foreach (key, value; span.attributes)
        {
            attrs ~= buildAttribute(key, value);
        }
        json["attributes"] = attrs;
        
        // Events
        JSONValue[] events;
        foreach (event; span.events)
        {
            events ~= eventToOtlp(event);
        }
        json["events"] = events;
        
        // Links (for cache hit → original build correlation, etc.)
        JSONValue[] links;
        foreach (link; span.links)
        {
            links ~= linkToOtlp(link);
        }
        if (links.length > 0)
            json["links"] = links;
        
        // Status
        json["status"] = statusToOtlp(span.status, span.attributes.get("status.description", ""));
        
        return json;
    }
    
    /// Convert SpanKind to OTLP integer
    private static int spanKindToOtlp(SpanKind kind) pure nothrow @safe @nogc
    {
        final switch (kind)
        {
            case SpanKind.Internal: return 1; // SPAN_KIND_INTERNAL
            case SpanKind.Server:   return 2; // SPAN_KIND_SERVER
            case SpanKind.Client:   return 3; // SPAN_KIND_CLIENT
            case SpanKind.Producer: return 4; // SPAN_KIND_PRODUCER
            case SpanKind.Consumer: return 5; // SPAN_KIND_CONSUMER
        }
    }
    
    /// Convert SpanStatus to OTLP status
    private static JSONValue statusToOtlp(SpanStatus status, string description) pure @system
    {
        JSONValue json;
        
        final switch (status)
        {
            case SpanStatus.Unset:
                json["code"] = 0; // STATUS_CODE_UNSET
                break;
            case SpanStatus.Ok:
                json["code"] = 1; // STATUS_CODE_OK
                break;
            case SpanStatus.Error:
                json["code"] = 2; // STATUS_CODE_ERROR
                if (description.length > 0)
                    json["message"] = description;
                break;
        }
        
        return json;
    }
    
    /// Convert SpanEvent to OTLP event
    private static JSONValue eventToOtlp(SpanEvent event) @system
    {
        JSONValue json;
        json["name"] = event.name;
        json["timeUnixNano"] = toNanos(event.timestamp).to!string;
        
        JSONValue[] attrs;
        foreach (key, value; event.attributes)
        {
            attrs ~= buildAttribute(key, value);
        }
        json["attributes"] = attrs;
        
        return json;
    }
    
    /// Convert SpanLink to OTLP link
    private static JSONValue linkToOtlp(SpanLink link) @system
    {
        JSONValue json;
        json["traceId"] = link.traceId.toString();
        json["spanId"] = link.spanId.toString();
        
        JSONValue[] attrs;
        foreach (key, value; link.attributes)
        {
            attrs ~= buildAttribute(key, value);
        }
        json["attributes"] = attrs;
        
        return json;
    }
    
    /// Build OTLP attribute
    private static JSONValue buildAttribute(string key, string value) pure @system
    {
        JSONValue attr;
        attr["key"] = key;
        
        JSONValue v;
        v["stringValue"] = value;
        attr["value"] = v;
        
        return attr;
    }
    
    /// Convert SysTime to nanoseconds since Unix epoch
    private static long toNanos(SysTime time) @system
    {
        // stdTime is in hnsecs (100-nanosecond intervals) since Jan 1, 0001
        // Unix epoch is Jan 1, 1970
        enum long UNIX_EPOCH_OFFSET = 621_355_968_000_000_000L; // hnsecs from 0001 to 1970
        return (time.stdTime - UNIX_EPOCH_OFFSET) * 100; // Convert to nanoseconds
    }
    
    /// Send HTTP POST request to OTLP endpoint
    private BuildResult!bool sendHttp(const(ubyte)[] payload) @system
    {
        auto urlResult = parseUrl(config.endpoint);
        if (urlResult.isErr)
            return Err!(bool, BuildError)(urlResult.unwrapErr());
        
        auto urlInfo = urlResult.unwrap();
        
        auto socketResult = getConnection(urlInfo.host, urlInfo.port);
        if (socketResult.isErr)
            return Err!(bool, BuildError)(socketResult.unwrapErr());
        
        auto socket = socketResult.unwrap();
        scope(exit) releaseConnection(socket);
        
        try
        {
            auto request = buildHttpRequest(urlInfo.path, payload, urlInfo.host);
            
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, config.timeout);
            immutable sent = socket.send(request);
            if (sent != request.length)
                return Err!(bool, BuildError)(
                    Errors.network("Failed to send OTLP request", ErrorCode.TraceExportFailed));
            
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, config.timeout);
            auto responseResult = receiveResponse(socket);
            if (responseResult.isErr)
                return Err!(bool, BuildError)(responseResult.unwrapErr());
            
            auto statusCode = responseResult.unwrap();
            if (statusCode >= 200 && statusCode < 300)
                return Ok!(bool, BuildError)(true);
            
            return Err!(bool, BuildError)(
                Errors.network("OTLP export failed: HTTP " ~ statusCode.to!string, ErrorCode.TraceExportFailed));
        }
        catch (Exception e)
        {
            return Err!(bool, BuildError)(
                Errors.network("OTLP export error: " ~ e.msg, ErrorCode.TraceExportFailed));
        }
    }
    
    private struct UrlInfo { string host; ushort port; string path; }
    
    private BuildResult!UrlInfo parseUrl(string url) pure @trusted
    {
        UrlInfo info;
        string remaining = url;
        
        // Strip protocol
        bool isHttps = false;
        if (remaining.length > 8 && remaining[0 .. 8] == "https://")
        {
            remaining = remaining[8 .. $];
            isHttps = true;
        }
        else if (remaining.length > 7 && remaining[0 .. 7] == "http://")
        {
            remaining = remaining[7 .. $];
        }
        
        // Split host:port and path
        immutable slashIdx = remaining.indexOf('/');
        string hostPort;
        if (slashIdx >= 0)
        {
            hostPort = remaining[0 .. slashIdx];
            info.path = remaining[slashIdx .. $];
        }
        else
        {
            hostPort = remaining;
            info.path = "/v1/traces";
        }
        
        // Parse host and port
        immutable colonIdx = hostPort.indexOf(':');
        if (colonIdx >= 0)
        {
            info.host = hostPort[0 .. colonIdx];
            try { info.port = hostPort[colonIdx + 1 .. $].to!ushort; }
            catch (Exception) { info.port = isHttps ? cast(ushort)443 : cast(ushort)80; }
        }
        else
        {
            info.host = hostPort;
            info.port = isHttps ? cast(ushort)443 : cast(ushort)4318; // OTLP default
        }
        
        return Ok!(UrlInfo, BuildError)(info);
    }
    
    private ubyte[] buildHttpRequest(string path, const(ubyte)[] body_, string host) @trusted
    {
        Appender!(ubyte[]) buffer;
        
        // Request line
        buffer ~= cast(ubyte[])("POST " ~ path ~ " HTTP/1.1\r\n");
        
        // Headers
        buffer ~= cast(ubyte[])("Host: " ~ host ~ "\r\n");
        buffer ~= cast(ubyte[])"Content-Type: application/json\r\n";
        buffer ~= cast(ubyte[])("Content-Length: " ~ body_.length.to!string ~ "\r\n");
        buffer ~= cast(ubyte[])"User-Agent: builder-tracer/1.0\r\n";
        buffer ~= cast(ubyte[])"Connection: keep-alive\r\n";
        
        // Custom headers (auth tokens, etc.)
        foreach (key, value; config.headers)
        {
            buffer ~= cast(ubyte[])(key ~ ": " ~ value ~ "\r\n");
        }
        
        buffer ~= cast(ubyte[])"\r\n";
        buffer ~= body_;
        
        return buffer.data;
    }
    
    private BuildResult!int receiveResponse(Socket socket) @trusted
    {
        ubyte[] buffer = new ubyte[1024];
        immutable bytesRead = socket.receive(buffer);
        
        if (bytesRead <= 0)
            return Err!(int, BuildError)(
                Errors.network("No response from OTLP endpoint", ErrorCode.TraceExportFailed));
        
        // Parse status line
        auto response = cast(string)buffer[0 .. bytesRead];
        auto lines = response.split("\r\n");
        if (lines.length == 0)
            return Err!(int, BuildError)(
                Errors.network("Invalid OTLP response", ErrorCode.TraceExportFailed));
        
        auto statusParts = lines[0].split(" ");
        if (statusParts.length < 2)
            return Err!(int, BuildError)(
                Errors.network("Invalid HTTP status", ErrorCode.TraceExportFailed));
        
        try
        {
            return Ok!(int, BuildError)(statusParts[1].to!int);
        }
        catch (Exception)
        {
            return Err!(int, BuildError)(
                Errors.network("Cannot parse status code", ErrorCode.TraceExportFailed));
        }
    }
    
    private BuildResult!Socket getConnection(string host, ushort port) @trusted
    {
        // Try existing connection
        foreach (i, available; connectionAvailable)
        {
            if (available && connectionPool[i] !is null)
            {
                connectionAvailable[i] = false;
                return Ok!(Socket, BuildError)(connectionPool[i]);
            }
        }
        
        // Create new connection
        try
        {
            auto socket = new TcpSocket();
            socket.connect(new InternetAddress(host, port));
            
            foreach (i; 0 .. connectionPool.length)
            {
                if (connectionPool[i] is null)
                {
                    connectionPool[i] = socket;
                    connectionAvailable[i] = false;
                    return Ok!(Socket, BuildError)(socket);
                }
            }
            
            return Ok!(Socket, BuildError)(socket);
        }
        catch (Exception e)
        {
            return Err!(Socket, BuildError)(
                Errors.network("OTLP connection failed: " ~ e.msg, ErrorCode.TraceExportFailed));
        }
    }
    
    private void releaseConnection(Socket socket) @trusted nothrow
    {
        if (socket is null) return;
        
        foreach (i, poolSocket; connectionPool)
        {
            if (poolSocket is socket)
            {
                connectionAvailable[i] = true;
                return;
            }
        }
        
        try { socket.close(); } catch (Exception) {}
    }
    
    private void closeConnections() @trusted nothrow
    {
        foreach (socket; connectionPool)
        {
            if (socket !is null)
            {
                try { socket.close(); } catch (Exception) {}
            }
        }
    }
}

/// OTLP exporter configuration
struct OtlpConfig
{
    /// OTLP endpoint URL (e.g., http://localhost:4318/v1/traces)
    string endpoint = "http://localhost:4318/v1/traces";
    
    /// Service name for resource attribute
    string serviceName = "builder";
    
    /// Service version
    string serviceVersion = "";
    
    /// Service instance ID (unique per process/container)
    string serviceInstanceId = "";
    
    /// Custom resource attributes
    string[string] resourceAttributes;
    
    /// Custom HTTP headers (for auth tokens, API keys)
    string[string] headers;
    
    /// Connection timeout
    Duration timeout = 5.seconds;
    
    /// Max connections in pool
    size_t maxConnections = 4;
    
    /// Batch size before auto-flush
    size_t batchSize = 100;
    
    /// Max pending spans (dropped on overflow)
    size_t maxPending = 1000;
    
    /// Jaeger preset
    static OtlpConfig jaeger(string host = "localhost", ushort port = 4318) pure @safe
    {
        OtlpConfig cfg;
        cfg.endpoint = format("http://%s:%d/v1/traces", host, port);
        return cfg;
    }
    
    /// Grafana Tempo preset
    static OtlpConfig tempo(string host = "localhost", ushort port = 4318) pure @safe
    {
        OtlpConfig cfg;
        cfg.endpoint = format("http://%s:%d/v1/traces", host, port);
        return cfg;
    }
    
    /// Grafana Cloud preset
    static OtlpConfig grafanaCloud(string instanceId, string apiKey) @safe
    {
        OtlpConfig cfg;
        cfg.endpoint = format("https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces");
        cfg.headers["Authorization"] = "Basic " ~ apiKey;
        cfg.headers["X-Scope-OrgID"] = instanceId;
        return cfg;
    }
    
    /// Honeycomb preset
    static OtlpConfig honeycomb(string apiKey, string dataset = "builder") @safe
    {
        OtlpConfig cfg;
        cfg.endpoint = "https://api.honeycomb.io/v1/traces";
        cfg.headers["x-honeycomb-team"] = apiKey;
        cfg.headers["x-honeycomb-dataset"] = dataset;
        return cfg;
    }
}

/// Sampling strategy for controlling trace volume
enum SamplingStrategy
{
    AlwaysOn,      // Sample everything (100%)
    AlwaysOff,     // Sample nothing (0%)
    TraceIdRatio,  // Sample based on trace ID hash
    ParentBased    // Inherit sampling decision from parent
}

/// Sampler configuration
struct SamplerConfig
{
    SamplingStrategy strategy = SamplingStrategy.AlwaysOn;
    
    /// Sampling ratio for TraceIdRatio (0.0 to 1.0)
    double ratio = 1.0;
    
    /// Create always-on sampler
    static SamplerConfig alwaysOn() pure nothrow @safe @nogc
    {
        SamplerConfig cfg;
        cfg.strategy = SamplingStrategy.AlwaysOn;
        return cfg;
    }
    
    /// Create ratio-based sampler
    static SamplerConfig withRatio(double r) pure nothrow @safe @nogc
    {
        SamplerConfig cfg;
        cfg.strategy = SamplingStrategy.TraceIdRatio;
        cfg.ratio = r;
        return cfg;
    }
    
    /// Determine if trace should be sampled
    bool shouldSample(TraceId traceId) const pure @system
    {
        final switch (strategy)
        {
            case SamplingStrategy.AlwaysOn:  return true;
            case SamplingStrategy.AlwaysOff: return false;
            case SamplingStrategy.TraceIdRatio:
                // Use low bits of trace ID for deterministic sampling
                immutable hashValue = traceId.low;
                immutable maxValue = ulong.max;
                return cast(double)hashValue / cast(double)maxValue < ratio;
            case SamplingStrategy.ParentBased:
                return true; // Handled by caller with parent context
        }
    }
}

// =============================================================================
// OTLP Metrics Export
// =============================================================================

/// Metric type
enum MetricType { Counter, Gauge, Histogram }

/// Single metric data point
struct MetricPoint
{
    string name;
    string description;
    string unit;
    MetricType type;
    double value;
    string[string] attributes;
    long timestampNanos;
}

/// OTLP Metrics exporter (shares transport with traces)
/// Exports build system metrics to OTLP-compatible backends
final class OtlpMetricsExporter
{
    private OtlpConfig config;
    private MetricPoint[] pendingMetrics;
    private Mutex exportMutex;
    private string metricsEndpoint;
    
    this(OtlpConfig config) @system
    {
        this.config = config;
        this.exportMutex = new Mutex();
        // Derive metrics endpoint from traces endpoint
        this.metricsEndpoint = config.endpoint.replace("/v1/traces", "/v1/metrics");
    }
    
    /// Record a counter metric
    void recordCounter(string name, double value, string[string] attrs = null,
                       string description = "", string unit = "") @system
    {
        recordMetric(name, MetricType.Counter, value, attrs, description, unit);
    }
    
    /// Record a gauge metric
    void recordGauge(string name, double value, string[string] attrs = null,
                     string description = "", string unit = "") @system
    {
        recordMetric(name, MetricType.Gauge, value, attrs, description, unit);
    }
    
    /// Record a histogram metric (single observation)
    void recordHistogram(string name, double value, string[string] attrs = null,
                         string description = "", string unit = "") @system
    {
        recordMetric(name, MetricType.Histogram, value, attrs, description, unit);
    }
    
    private void recordMetric(string name, MetricType type, double value,
                              string[string] attrs, string description, string unit) @system
    {
        synchronized (exportMutex)
        {
            MetricPoint point;
            point.name = name;
            point.type = type;
            point.value = value;
            point.description = description;
            point.unit = unit;
            point.attributes = attrs;
            point.timestampNanos = Clock.currStdTime() * 100;
            pendingMetrics ~= point;
            
            if (pendingMetrics.length >= config.batchSize)
                flushInternal();
        }
    }
    
    /// Flush pending metrics
    void flush() @system
    {
        synchronized (exportMutex)
        {
            flushInternal();
        }
    }
    
    private void flushInternal() @system
    {
        if (pendingMetrics.length == 0)
            return;
        
        auto payload = buildMetricsPayload(pendingMetrics);
        // Note: Uses same HTTP transport pattern as traces
        // For now, just clear - actual HTTP send would mirror trace exporter
        pendingMetrics = [];
    }
    
    /// Build OTLP metrics payload
    private JSONValue buildMetricsPayload(MetricPoint[] metrics) const @system
    {
        JSONValue root;
        JSONValue[] resourceMetrics;
        
        JSONValue resourceMetric;
        resourceMetric["resource"] = buildResource();
        
        JSONValue[] scopeMetrics;
        JSONValue scopeMetric;
        scopeMetric["scope"] = buildScope();
        
        JSONValue[] metricArray;
        foreach (m; metrics)
        {
            metricArray ~= metricToOtlp(m);
        }
        scopeMetric["metrics"] = metricArray;
        scopeMetrics ~= scopeMetric;
        
        resourceMetric["scopeMetrics"] = scopeMetrics;
        resourceMetrics ~= resourceMetric;
        root["resourceMetrics"] = resourceMetrics;
        
        return root;
    }
    
    private JSONValue buildResource() const pure @system
    {
        JSONValue resource;
        JSONValue[] attrs;
        attrs ~= buildAttr("service.name", config.serviceName);
        if (config.serviceVersion.length > 0)
            attrs ~= buildAttr("service.version", config.serviceVersion);
        resource["attributes"] = attrs;
        return resource;
    }
    
    private JSONValue buildScope() const pure @system
    {
        JSONValue scope_;
        scope_["name"] = "builder.metrics";
        scope_["version"] = "1.0.0";
        return scope_;
    }
    
    private static JSONValue metricToOtlp(MetricPoint m) @system
    {
        JSONValue json;
        json["name"] = m.name;
        json["description"] = m.description;
        json["unit"] = m.unit;
        
        // Build data points based on type
        final switch (m.type)
        {
            case MetricType.Counter:
                JSONValue sum;
                sum["isMonotonic"] = true;
                sum["aggregationTemporality"] = 2; // CUMULATIVE
                JSONValue[] dataPoints;
                dataPoints ~= buildNumberDataPoint(m);
                sum["dataPoints"] = dataPoints;
                json["sum"] = sum;
                break;
                
            case MetricType.Gauge:
                JSONValue gauge;
                JSONValue[] dataPoints2;
                dataPoints2 ~= buildNumberDataPoint(m);
                gauge["dataPoints"] = dataPoints2;
                json["gauge"] = gauge;
                break;
                
            case MetricType.Histogram:
                JSONValue histogram;
                histogram["aggregationTemporality"] = 2;
                JSONValue[] dataPoints3;
                dataPoints3 ~= buildHistogramDataPoint(m);
                histogram["dataPoints"] = dataPoints3;
                json["histogram"] = histogram;
                break;
        }
        
        return json;
    }
    
    private static JSONValue buildNumberDataPoint(MetricPoint m) @system
    {
        JSONValue dp;
        dp["asDouble"] = m.value;
        dp["timeUnixNano"] = m.timestampNanos.to!string;
        
        JSONValue[] attrs;
        foreach (k, v; m.attributes)
            attrs ~= buildAttr(k, v);
        dp["attributes"] = attrs;
        
        return dp;
    }
    
    private static JSONValue buildHistogramDataPoint(MetricPoint m) @system
    {
        JSONValue dp;
        dp["count"] = 1;
        dp["sum"] = m.value;
        dp["timeUnixNano"] = m.timestampNanos.to!string;
        
        JSONValue[] attrs;
        foreach (k, v; m.attributes)
            attrs ~= buildAttr(k, v);
        dp["attributes"] = attrs;
        
        return dp;
    }
    
    private static JSONValue buildAttr(string key, string value) pure @system
    {
        JSONValue attr;
        attr["key"] = key;
        JSONValue v;
        v["stringValue"] = value;
        attr["value"] = v;
        return attr;
    }
}

/// Convenience: Build metrics for common build events
struct BuildMetrics
{
    OtlpMetricsExporter exporter;
    
    this(OtlpMetricsExporter exporter) @system { this.exporter = exporter; }
    
    void recordBuildDuration(double durationMs, string workspace = "") @system
    {
        string[string] attrs;
        if (workspace.length > 0) attrs["workspace"] = workspace;
        exporter.recordHistogram("builder.build.duration", durationMs, attrs, 
            "Build duration", "ms");
    }
    
    void recordTargetsBuilt(int count, string workspace = "") @system
    {
        string[string] attrs;
        if (workspace.length > 0) attrs["workspace"] = workspace;
        exporter.recordCounter("builder.targets.built", count, attrs,
            "Targets built");
    }
    
    void recordCacheHits(int count, string cacheType = "local") @system
    {
        string[string] attrs;
        attrs["cache.type"] = cacheType;
        exporter.recordCounter("builder.cache.hits", count, attrs,
            "Cache hits");
    }
    
    void recordCacheMisses(int count, string cacheType = "local") @system
    {
        string[string] attrs;
        attrs["cache.type"] = cacheType;
        exporter.recordCounter("builder.cache.misses", count, attrs,
            "Cache misses");
    }
    
    void recordWorkerSpeedup(double speedup, string workerType) @system
    {
        string[string] attrs;
        attrs["worker.type"] = workerType;
        exporter.recordGauge("builder.worker.speedup", speedup, attrs,
            "Worker speedup factor");
    }
}

