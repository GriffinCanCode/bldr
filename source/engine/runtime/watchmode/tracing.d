module engine.runtime.watchmode.tracing;

import std.conv : to;
import std.datetime : Duration, SysTime;
import infrastructure.telemetry.distributed.tracing;

/// Watch mode tracing integration
/// Tracks file changes and rebuild triggers for incremental build observability
struct WatchModeTracing
{
    private Tracer tracer;
    
    this(Tracer tracer) @system { this.tracer = tracer; }
    
    /// Start span for file change detection batch
    Span startFileChangeDetection(size_t changedFiles) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("watch.detect_changes", SpanKind.Internal);
        if (span !is null)
        {
            span.setAttribute("watch.changed_files", changedFiles.to!string);
            span.addEvent("changes_detected");
        }
        return span;
    }
    
    /// Start span for rebuild trigger
    Span startRebuild(string[] changedFiles, string[] affectedTargets) @system
    {
        if (tracer is null) return null;
        
        // Start a new trace for each rebuild
        tracer.startTrace();
        
        auto span = tracer.startSpan("watch.rebuild", SpanKind.Internal);
        if (span !is null)
        {
            span.setAttribute("watch.trigger_files", changedFiles.length.to!string);
            span.setAttribute("watch.affected_targets", affectedTargets.length.to!string);
            span.setAttribute("watch.mode", "incremental");
            
            // Add changed files as event (limited to first 10)
            string[string] eventAttrs;
            foreach (i, f; changedFiles)
            {
                if (i >= 10) break;
                eventAttrs["file." ~ i.to!string] = f;
            }
            span.addEvent("rebuild_triggered", eventAttrs);
        }
        return span;
    }
    
    /// Start span for debounce wait period
    Span startDebounce(Duration debounceTime) @system
    {
        if (tracer is null) return null;
        
        auto span = tracer.startSpan("watch.debounce", SpanKind.Internal);
        if (span !is null)
            span.setAttribute("watch.debounce_ms", debounceTime.total!"msecs".to!string);
        return span;
    }
    
    /// Record rebuild completion
    void recordRebuildComplete(Span span, Duration buildTime, size_t built, size_t cached, size_t failed) @system
    {
        if (span is null) return;
        
        span.setAttribute("build.duration_ms", buildTime.total!"msecs".to!string);
        span.setAttribute("build.targets_built", built.to!string);
        span.setAttribute("build.targets_cached", cached.to!string);
        span.setAttribute("build.targets_failed", failed.to!string);
        
        if (failed > 0)
            span.setStatus(SpanStatus.Error, failed.to!string ~ " targets failed");
        else
            span.setStatus(SpanStatus.Ok);
    }
    
    /// Record watch mode session start
    Span startWatchSession(string workspace, string[] watchPatterns) @system
    {
        if (tracer is null) return null;
        
        tracer.startTrace();
        auto span = tracer.startSpan("watch.session", SpanKind.Internal);
        if (span !is null)
        {
            span.setAttribute("watch.workspace", workspace);
            span.setAttribute("watch.patterns", watchPatterns.length.to!string);
        }
        return span;
    }
    
    /// Record session statistics
    void recordSessionStats(Span span, size_t totalRebuilds, Duration totalTime) @system
    {
        if (span is null) return;
        span.setAttribute("watch.total_rebuilds", totalRebuilds.to!string);
        span.setAttribute("watch.session_duration_s", totalTime.total!"seconds".to!string);
    }
    
    /// Finish span
    void finish(Span span) @system
    {
        if (tracer !is null && span !is null)
            tracer.finishSpan(span);
    }
}

