module engine.runtime.core.engine.coordinator;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import std.format : format;
import core.atomic;
import core.memory : GC;
import engine.graph;
import infrastructure.config.schema.schema;
import languages.base.base;
import engine.runtime.services : ISchedulingService, ICacheService, IObservabilityService, IResilienceService, IHandlerRegistry;
import engine.runtime.services.scheduling : NodeBuildResult;
import frontend.cli.events.events;
import infrastructure.telemetry.distributed.tracing : Span, SpanKind, SpanStatus;
import infrastructure.utils.logging;
import infrastructure.utils.simd.capabilities;
import infrastructure.errors;
import engine.runtime.core.engine.lifecycle;
import engine.runtime.core.engine.executor;
import engine.runtime.core.engine.discovery;

/// Engine coordinator - orchestrates build execution
struct EngineCoordinator
{
    private enum size_t BYTES_PER_KB = 1024;
    private enum size_t KB_PER_MB = 1024;
    private enum size_t MB_PER_GB = 1024;
    private enum size_t MAX_STAT_STRING_LENGTH = 4;
    
    private EngineLifecycle* lifecycle;
    private EngineExecutor* executor;
    private DynamicBuildGraph dynamicGraph;  // Optional: null if not using dynamic graphs
    private DiscoveryExecutor discoveryExec;
    
    /// Initialize coordinator with lifecycle and executor
    void initialize(EngineLifecycle* lifecycle, EngineExecutor* executor) @trusted
    {
        this.lifecycle = lifecycle;
        this.executor = executor;
    }
    
    /// Enable dynamic graph support (optional)
    void enableDynamicGraph(DynamicBuildGraph dynamicGraph, IHandlerRegistry handlers) @trusted
    {
        this.dynamicGraph = dynamicGraph;
        
        // Initialize discovery executor
        auto config = lifecycle.getConfig();
        discoveryExec.initialize(dynamicGraph, handlers, config);
        
        // Mark discoverable targets
        DiscoveryMarker.markCodeGenTargets(dynamicGraph);
        
        structuredLog.debug_("dynamic_graph_enabled").emit();
    }
    
    /// Execute the build
    bool execute() @trusted
    {
        auto sw = StopWatch(AutoStart.yes);
        
        auto graph = lifecycle.getGraph();
        auto config = lifecycle.getConfig();
        auto scheduling = lifecycle.getScheduling();
        auto cache = lifecycle.getCache();
        auto observability = lifecycle.getObservability();
        auto resilience = lifecycle.getResilience();
        
        // Start distributed trace
        observability.startTrace();
        auto buildSpan = observability.startSpan("build-execute", SpanKind.Internal);
        scope(exit) {
            observability.finishSpan(buildSpan);
            observability.flush();
        }
        
        // Topological sort
        auto sortResult = graph.topologicalSort();
        if (sortResult.isErr)
        {
            auto error = sortResult.unwrapErr();
            auto errorMsg = error.message();
            observability.recordException(buildSpan, new Exception(errorMsg));
            observability.setSpanStatus(buildSpan, SpanStatus.Error, errorMsg);
            observability.logError("Cannot build: " ~ errorMsg, ["error.type": "topological_sort_failed"]);
            observability.publishEvent(new BuildFailedEvent(errorMsg, 0, sw.peek(), sw.peek(), 
                observability.getCurrentTraceId()));
            return false;
        }
        
        auto sorted = sortResult.unwrap();
        observability.setSpanAttribute(buildSpan, "build.total_targets", sorted.length.to!string);
        observability.setSpanAttribute(buildSpan, "build.max_parallelism", scheduling.workerCount().to!string);
        observability.logInfo("Building targets", [
            "total_targets": sorted.length.to!string,
            "parallelism": scheduling.workerCount().to!string
        ]);
        
        // Handle checkpoint/resume
        if (!handleCheckpointResume(buildSpan, sorted.length))
        {
            // Checkpoint handling failed but we can continue
        }
        
        // GC control for large builds
        immutable bool useGcControl = lifecycle.shouldDisableGC(sorted.length);
        if (useGcControl)
        {
            GC.disable();
            observability.setSpanAttribute(buildSpan, "gc.disabled", "true");
            observability.addSpanEvent(buildSpan, "gc-disabled");
            observability.logDebug("GC disabled for large build", ["target_count": sorted.length.to!string]);
        }
        
        scope(exit)
        {
            if (useGcControl)
            {
                GC.enable();
                GC.collect();
                observability.addSpanEvent(buildSpan, "gc-enabled");
                observability.logDebug("GC re-enabled and collected");
            }
        }
        
        // Initialize scheduling
        scheduling.initialize(0); // 0 = auto-detect CPU count
        
        // Publish build started event
        observability.publishEvent(new BuildStartedEvent(sorted.length, scheduling.workerCount(), sw.peek()));
        
        size_t built = 0;
        size_t cached = 0;
        
        structuredLog.debug_("max_parallelism_set")
            .field("jobs", scheduling.workerCount())
            .emit();
        
        // Initialize pending dependency counters
        foreach (node; sorted)
            node.initPendingDeps();
        
        // Enqueue initially ready nodes
        foreach (node; sorted)
        {
            if (node.pendingDeps == 0)
                scheduling.submit(node);
        }
        
        // Main execution loop
        while (lifecycle.getFailedTasks() == 0)
        {
            // Discovery phase: execute discovery actions first if using dynamic graphs
            if (dynamicGraph !is null && discoveryExec.hasPendingDiscoveries())
            {
                // Apply pending discoveries and get new nodes
                auto discoveredNodes = DiscoveryCoordinator.executeDiscoveryPhase(
                    [],
                    discoveryExec,
                    observability
                );
                
                // Integrate discovered nodes into execution
                auto readyDiscovered = DiscoveryCoordinator.integrateDiscoveredNodes(
                    discoveredNodes,
                    graph
                );
                
                // Submit ready discovered nodes
                foreach (node; readyDiscovered)
                    scheduling.submit(node);
            }
            
            // Dequeue batch of ready nodes
            auto batch = scheduling.dequeueReady(scheduling.workerCount());
            
            // If no ready nodes and no active tasks, check for final discoveries
            if (batch.length == 0 && lifecycle.getActiveTasks() == 0)
            {
                // Try applying any remaining discoveries
                if (dynamicGraph !is null && dynamicGraph.hasPendingDiscoveries())
                {
                    auto finalDiscoveries = dynamicGraph.applyDiscoveries();
                    if (finalDiscoveries.isOk && !finalDiscoveries.unwrap().empty)
                    {
                        // More nodes discovered, continue
                        foreach (node; finalDiscoveries.unwrap())
                        {
                            if (node.pendingDeps == 0)
                                scheduling.submit(node);
                        }
                        continue;
                    }
                }
                // No more work
                break;
            }
            
            // Wait briefly if no ready nodes but tasks are active
            if (batch.length == 0)
            {
                import core.thread : Thread;
                import core.time : msecs;
                Thread.sleep(1.msecs);
                continue;
            }
            
            structuredLog.debug_("building_batch")
                .field("targets", batch.map!(n => n.idString).join(","))
                .emit();
            
            // Execute discovery for batch if using dynamic graphs
            if (dynamicGraph !is null)
            {
                auto discoveredInBatch = DiscoveryCoordinator.executeDiscoveryPhase(
                    batch,
                    discoveryExec,
                    observability
                );
                
                // Don't wait for discovered nodes, they'll be picked up in next iteration
                if (!discoveredInBatch.empty)
                {
                    auto readyDiscovered = DiscoveryCoordinator.integrateDiscoveredNodes(
                        discoveredInBatch,
                        graph
                    );
                    foreach (node; readyDiscovered)
                        scheduling.submit(node);
                }
            }
            
            lifecycle.incrementActiveTasks(batch.length);
            
            // Mark nodes as building
            foreach (node; batch)
                node.status = BuildStatus.Building;
            
            // Execute batch in parallel - convert between BuildResult types
            NodeBuildResult delegate(BuildNode) @system execDelegate = (BuildNode node) @system {
                auto execResult = executor.buildNode(node);
                NodeBuildResult schedResult;
                schedResult.targetId = execResult.targetId;
                schedResult.success = execResult.success;
                schedResult.cached = execResult.cached;
                schedResult.error = execResult.error;
                return schedResult;
            };
            auto results = scheduling.executeBatch(batch, execDelegate);
            
            // Process results
            foreach (i, result; results)
            {
                auto node = batch[i];
                
                if (result.success)
                {
                    node.status = result.cached ? BuildStatus.Cached : BuildStatus.Success;
                    if (result.cached)
                        cached++;
                    else
                        built++;
                    
                    // Enqueue ready dependents
                    foreach (dependentId; node.dependentIds)
                    {
                        auto dependent = graph.getNode(dependentId);
                        if (dependent !is null)
                        {
                            immutable remaining = dependent.decrementPendingDeps();
                            if (remaining == 0)
                                scheduling.submit(*dependent);
                        }
                    }
                }
                else
                {
                    node.status = BuildStatus.Failed;
                    lifecycle.incrementFailedTasks();
                    structuredLog.error("build_failed")
                        .field("target", node.idString)
                        .field("error", result.error)
                        .emit();
                    
                    // Mark all dependents as failed (cascading failure)
                    foreach (dependentId; node.dependentIds)
                    {
                        auto dependent = graph.getNode(dependentId);
                        if (dependent !is null && dependent.status == BuildStatus.Pending)
                        {
                            dependent.status = BuildStatus.Failed;
                            lifecycle.incrementFailedTasks();
                        }
                    }
                }
            }
            
            lifecycle.decrementActiveTasks(batch.length);
        }
        
        sw.stop();
        
        auto failed = lifecycle.getFailedTasks();
        
        // Flush caches
        cache.flush();
        
        // Publish events and statistics
        publishCompletionEvents(sorted.length, built, cached, failed, sw.peek());
        
        // Print summary
        printSummary(built, cached, failed, sw.peek());
        
        return failed == 0;
    }
    
    /// Handle checkpoint and resume logic
    private bool handleCheckpointResume(Span buildSpan, size_t totalTargets) @trusted
    {
        auto resilience = lifecycle.getResilience();
        auto observability = lifecycle.getObservability();
        auto graph = lifecycle.getGraph();
        
        if (!resilience.hasCheckpoint())
            return false;
        
        auto checkpointSpan = observability.startSpan("checkpoint-load", SpanKind.Internal, buildSpan);
        scope(exit) observability.finishSpan(checkpointSpan);
        
        auto checkpointResult = resilience.loadCheckpoint();
        if (checkpointResult.isErr)
            return false;
        
        auto checkpoint = checkpointResult.unwrap();
        
        if (checkpoint.isValid(graph) && !resilience.isCheckpointStale())
        {
            auto timestampStr = checkpoint.timestamp.toSimpleString();
            observability.setSpanAttribute(checkpointSpan, "checkpoint.valid", "true");
            observability.setSpanAttribute(checkpointSpan, "checkpoint.timestamp", timestampStr);
            observability.logInfo("Found valid checkpoint", ["checkpoint.timestamp": timestampStr]);
            
            // Plan resume
            auto planResult = resilience.planResume(graph);
            if (planResult.isOk)
            {
                auto plan = planResult.unwrap();
                plan.print();
                auto savings = plan.estimatedSavings().to!string;
                observability.setSpanAttribute(checkpointSpan, "checkpoint.savings_pct", savings);
                observability.logInfo("Resuming build", ["savings_percent": savings, "checkpoint.timestamp": timestampStr]);
                return true;
            }
        }
        else
        {
            observability.setSpanAttribute(checkpointSpan, "checkpoint.valid", "false");
            observability.logInfo("Checkpoint stale or invalid, rebuilding");
            resilience.clearCheckpoint();
        }
        
        return false;
    }
    
    /// Publish completion events and statistics
    private void publishCompletionEvents(size_t total, size_t built, size_t cached, size_t failed, Duration elapsed) @trusted
    {
        auto observability = lifecycle.getObservability();
        auto cache = lifecycle.getCache();
        auto traceId = observability.getCurrentTraceId();
        
        if (failed > 0)
        {
            observability.publishEvent(new BuildFailedEvent("Build failed", failed, elapsed, elapsed, traceId));
        }
        else
        {
            observability.publishEvent(new BuildCompletedEvent(built, cached, failed, elapsed, elapsed, traceId));
        }
        
        // Publish statistics
        auto cacheStats = cache.getStats();
        
        BuildStats buildStats;
        buildStats.totalTargets = total;
        buildStats.completedTargets = built;
        buildStats.cachedTargets = cached;
        buildStats.failedTargets = failed;
        buildStats.elapsed = elapsed;
        buildStats.targetsPerSecond = total > 0 ? (total * 1000.0) / elapsed.total!"msecs" : 0.0;
        
        // Map to event cache stats
        frontend.cli.events.events.CacheStats cliCacheStats;
        cliCacheStats.hits = cacheStats.metadataHits;
        cliCacheStats.misses = cacheStats.contentHashes;
        cliCacheStats.totalEntries = cacheStats.totalEntries;
        cliCacheStats.totalSize = cacheStats.totalSize;
        cliCacheStats.hitRate = cacheStats.metadataHitRate;
        
        observability.publishEvent(new StatisticsEvent(cliCacheStats, buildStats, elapsed));
    }
    
    /// Print build summary to console
    private void printSummary(size_t built, size_t cached, size_t failed, Duration elapsed) @trusted
    {
        auto cache = lifecycle.getCache();
        
        writeln();
        structuredLog.info("build_summary")
            .field("built", built)
            .field("cached", cached)
            .field("failed", failed)
            .field("elapsed_ms", elapsed.total!"msecs")
            .emit();
        
        auto cacheStats = cache.getStats();
        if (cacheStats.metadataHits + cacheStats.contentHashes > 0)
        {
            structuredLog.debug_("cache_performance")
                .field("total_entries", cacheStats.totalEntries)
                .field("cache_size", formatSize(cacheStats.totalSize))
                .field("metadata_hit_rate", cacheStats.metadataHitRate)
                .field("hash_cache_hit_rate", cacheStats.hashCacheHitRate)
                .field("hash_cache_saves", cacheStats.hashCacheHits)
                .emit();
        }
        
        if (cacheStats.actionEntries > 0)
        {
            structuredLog.debug_("action_cache_stats")
                .field("total_actions", cacheStats.actionEntries)
                .field("cache_size", formatSize(cacheStats.actionSize))
                .field("hit_rate", cacheStats.actionHitRate)
                .field("successful_actions", cacheStats.successfulActions)
                .field("failed_actions", cacheStats.failedActions)
                .emit();
        }
    }
    
    /// Format size in human-readable format
    private static string formatSize(size_t bytes) pure @system
    {
        static immutable size_t[4] thresholds = [1, BYTES_PER_KB, BYTES_PER_KB * KB_PER_MB, BYTES_PER_KB * KB_PER_MB * MB_PER_GB];
        static immutable string[4] units = [" B", " KB", " MB", " GB"];
        
        foreach_reverse (i, threshold; thresholds)
            if (bytes >= threshold)
                return format("%d%s", bytes / threshold, units[i]);
        
        return format("%d B", bytes);
    }
    
    /// Format percentage
    private static string formatPercent(float rate) pure @system
    {
        auto str = rate.to!string;
        return str[0..min(MAX_STAT_STRING_LENGTH, str.length)] ~ "%";
    }
}

