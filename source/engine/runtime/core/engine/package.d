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
import infrastructure.utils.logging;
import infrastructure.di : IServiceContainer;
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
/// - IServiceContainer: DI container for observability
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
        ISchedulingService scheduling,
        ICacheService cache,
        IObservabilityService observability,
        IResilienceService resilience,
        IHandlerRegistry handlers,
        IServiceContainer services,
        bool enableDynamicGraph = true
    ) @trusted
    {
        this.useDynamicGraph = enableDynamicGraph;
        
        // Create dynamic graph wrapper if enabled
        if (enableDynamicGraph)
        {
            this.dynamicGraph = new DynamicBuildGraph(graph);
            structuredLog.debug_("dynamic_graph_support_enabled").emit();
        }
        
        // Initialize lifecycle
        lifecycle.initialize(
            graph, scheduling, cache, 
            observability, resilience, handlers, services
        );
        
        // Initialize executor with service container
        executor.initialize(
            cache, observability, resilience, handlers, services
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
                structuredLog.debug_("dynamic_discovery_summary").emit();
                structuredLog.debug_("__targets_discovered_").field("detail", "  Targets discovered: " ~ stats.targetsDiscovered.to!string).emit();
                structuredLog.debug_("__total_discoveries_").field("detail", "  Total discoveries: " ~ stats.totalDiscoveries.to!string).emit();
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
