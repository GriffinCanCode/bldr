module infrastructure.errors.codes.telemetry;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Telemetry and observability error codes (10000-11999)
/// Covers metrics, tracing, and logging
enum Telemetry : int
{
    /// No active telemetry session
    NoSession = 10000,
    /// Telemetry storage error
    Storage = 10001,
    /// Invalid telemetry data
    Invalid = 10002,
    /// Telemetry export failed
    ExportFailed = 10003,
    /// Telemetry collector unavailable
    CollectorUnavailable = 10004,
    /// Metric registration failed
    MetricRegistrationFailed = 10005,
    /// Counter overflow
    CounterOverflow = 10006,
    /// Histogram error
    HistogramError = 10007,
    /// Gauge error
    GaugeError = 10008,
    /// Invalid trace format
    TraceInvalidFormat = 11000,
    /// No active span
    TraceNoActiveSpan = 11001,
    /// Trace export failed
    TraceExportFailed = 11002,
    /// Span context invalid
    SpanContextInvalid = 11003,
    /// Trace ID invalid
    TraceIDInvalid = 11004,
    /// Parent span not found
    ParentSpanNotFound = 11005,
    /// Trace sampling error
    SamplingError = 11006,
    /// Log shipping failed
    LogShipFailed = 11007,
    /// Buffer overflow
    BufferOverflow = 11008,
    /// Aggregation error
    AggregationError = 11009,
}

/// Namespace for telemetry error utilities
struct TelemetryErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Telemetry; }
    
    static Recoverability recoverabilityOf(Telemetry code) pure nothrow @nogc
    {
        switch (code)
        {
            case Telemetry.ExportFailed:
            case Telemetry.CollectorUnavailable:
            case Telemetry.TraceExportFailed:
            case Telemetry.LogShipFailed:
            case Telemetry.BufferOverflow:
                return Recoverability.Transient;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Telemetry code) pure nothrow @safe
    {
        final switch (code)
        {
            case Telemetry.NoSession:               return "No active telemetry session";
            case Telemetry.Storage:                 return "Telemetry storage error";
            case Telemetry.Invalid:                 return "Invalid telemetry data";
            case Telemetry.ExportFailed:            return "Telemetry export failed";
            case Telemetry.CollectorUnavailable:    return "Telemetry collector unavailable";
            case Telemetry.MetricRegistrationFailed: return "Metric registration failed";
            case Telemetry.CounterOverflow:         return "Counter overflow";
            case Telemetry.HistogramError:          return "Histogram error";
            case Telemetry.GaugeError:              return "Gauge error";
            case Telemetry.TraceInvalidFormat:      return "Invalid trace format";
            case Telemetry.TraceNoActiveSpan:       return "No active span";
            case Telemetry.TraceExportFailed:       return "Trace export failed";
            case Telemetry.SpanContextInvalid:      return "Span context invalid";
            case Telemetry.TraceIDInvalid:          return "Trace ID invalid";
            case Telemetry.ParentSpanNotFound:      return "Parent span not found";
            case Telemetry.SamplingError:           return "Trace sampling error";
            case Telemetry.LogShipFailed:           return "Log shipping failed";
            case Telemetry.BufferOverflow:          return "Buffer overflow";
            case Telemetry.AggregationError:        return "Aggregation error";
        }
    }
}

