module infrastructure.telemetry.distributed;

/// Distributed tracing subsystem
/// 
/// This module provides OpenTelemetry-compatible distributed tracing for
/// parallel builds with span tracking and context propagation.
/// 
/// Components:
/// - Tracer: Global trace management
/// - Span: Individual traced operations
/// - SpanExporter: Export traces to various backends
/// - OtlpHttpExporter: OTLP/HTTP exporter for Jaeger, Tempo, Grafana Cloud
/// 
/// Usage with OTLP backend:
/// ```d
/// auto config = OtlpConfig.jaeger("localhost", 4318);
/// config.serviceName = "my-build-system";
/// auto exporter = new OtlpHttpExporter(config);
/// auto tracer = new Tracer(exporter);
/// ```

public import infrastructure.telemetry.distributed.tracing;
public import infrastructure.telemetry.distributed.otlp;

