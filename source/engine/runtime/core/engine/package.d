module engine.runtime.core.engine;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import core.atomic;
import core.memory : GC;
import engine.graph;
import infrastructure.config.schema.schema;
import languages.base.base;
import engine.runtime.services;
import frontend.cli.events.events;
import infrastructure.telemetry.distributed.tracing : Span, SpanKind, SpanStatus;
import infrastructure.utils.logging.logger;
import infrastructure.utils.simd.capabilities;
import infrastructure.errors;

// Import split modules
public import engine.runtime.core.engine.lifecycle;
public import engine.runtime.core.engine.executor;
public import engine.runtime.core.engine.coordinator;
public import engine.runtime.core.engine.discovery;

/// Thin orchestration layer for build execution
/// Composes specialized services to execute build graph
/// 
/// Design: Pure coordination - all work delegated to services
/// - SchedulingService: parallelism and task queueing
/// - CacheService: caching decisions
/// - ObservabilityService: events, tracing, logging
/// - ResilienceService: retry and checkpoint logic
/// - HandlerRegistry: language handler dispatch
/// - DynamicGraph: optional runtime dependency discovery
final class ExecutionEngine
{
    private EngineLifecycle lifecycle;
    private EngineExecutor executor;
    private EngineCoordinator coordinator;
    private DynamicBuildGraph dynamicGraph;
    private bool useDynamicGraph;
    
    this(
        BuildGraph graph,
        WorkspaceConfig config,
        ISchedulingService scheduling,
        ICacheService cache,
        IObservabilityService observability,
        IResilienceService resilience,
        IHandlerRegistry handlers,
        SIMDCapabilities simdCaps = null,
        bool enableDynamicGraph = true  // Enable by default
    ) @trusted
    {
        this.useDynamicGraph = enableDynamicGraph;
        
        // Create dynamic graph wrapper if enabled
        if (enableDynamicGraph)
        {
            this.dynamicGraph = new DynamicBuildGraph(graph);
            Logger.debugLog("Dynamic graph support enabled");
        }
        
        // Initialize lifecycle
        lifecycle.initialize(
            graph, config, scheduling, cache, 
            observability, resilience, handlers, simdCaps
        );
        
        // Initialize executor
        executor.initialize(
            cache, observability, resilience, 
            handlers, config, simdCaps
        );
        
        // Initialize coordinator
        coordinator.initialize(&lifecycle, &executor);
        
        // Enable dynamic graph in coordinator if available
        if (enableDynamicGraph)
        {
            coordinator.enableDynamicGraph(dynamicGraph, handlers);
        }
    }
    
    ~this() nothrow
    {
        import core.memory : GC;
        // Only call shutdown if not in GC finalizer to avoid allocation errors
        if (!GC.inFinalizer())
        {
            try { shutdown(); }
            catch (Exception) {}
        }
    }
    
    /// Shutdown engine and cleanup resources
    void shutdown() @trusted
    {
        lifecycle.shutdown();
    }
    
    /// Execute the build
    bool execute() @trusted
    {
        auto success = coordinator.execute();
        
        // Report discovery statistics if using dynamic graphs
        if (useDynamicGraph && dynamicGraph !is null)
        {
            auto stats = dynamicGraph.getDiscoveryStats();
            if (stats.targetsDiscovered > 0)
            {
                Logger.debugLog("Dynamic Discovery Summary:");
                Logger.debugLog("  Targets discovered: " ~ stats.targetsDiscovered.to!string);
                Logger.debugLog("  Total discoveries: " ~ stats.totalDiscoveries.to!string);
            }
        }
        
        return success;
    }
    
    /// Get dynamic graph (if enabled)
    @property DynamicBuildGraph getDynamicGraph() @trusted
    {
        return dynamicGraph;
    }
    
    /// Check if dynamic graph is enabled
    @property bool isDynamicGraphEnabled() const pure nothrow @nogc
    {
        return useDynamicGraph;
    }
}
