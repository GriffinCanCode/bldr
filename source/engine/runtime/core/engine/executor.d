module engine.runtime.core.engine.executor;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime.stopwatch;
import engine.graph;
import infrastructure.config.schema.schema;
import languages.base.base;
import engine.runtime.services;
import frontend.cli.events.events;
import infrastructure.telemetry.distributed.tracing : Span, SpanKind, SpanStatus;
import infrastructure.utils.logging;
import infrastructure.di : IServiceContainer;
import infrastructure.errors;
import engine.runtime.hermetic.determinism;

/// Node build result
struct BuildResult
{
    string targetId;
    bool success;
    bool cached;
    string error;
}

/// Engine executor - handles individual target builds
/// Uses IServiceContainer for dependency injection of observability services.
struct EngineExecutor
{
    private ICacheService cache;
    private IObservabilityService observability;
    private IResilienceService resilience;
    private IHandlerRegistry handlers;
    private IServiceContainer services;
    
    /// Initialize executor with services
    void initialize(
        ICacheService cache,
        IObservabilityService observability,
        IResilienceService resilience,
        IHandlerRegistry handlers,
        IServiceContainer services
    ) @trusted
    {
        this.cache = cache;
        this.observability = observability;
        this.resilience = resilience;
        this.handlers = handlers;
        this.services = services;
    }
    
    /// Build a single node
    BuildResult buildNode(BuildNode node) @trusted
    {
        auto targetSpan = observability.startSpan("build-target", SpanKind.Internal);
        scope(exit) observability.finishSpan(targetSpan);
        
        observability.setSpanAttribute(targetSpan, "target.id", node.idString);
        observability.setSpanAttribute(targetSpan, "target.language", node.target.language.to!string);
        observability.setSpanAttribute(targetSpan, "target.type", node.target.type.to!string);
        
        BuildResult result;
        result.targetId = node.id.toString();
        auto nodeTimer = StopWatch(AutoStart.yes);
        
        try
        {
            observability.logInfo("Building target", [
                "target.language": node.target.language.to!string,
                "target.type": node.target.type.to!string
            ]);
            publishTargetStarted(node, nodeTimer.peek());
            
            auto target = node.target;
            auto deps = node.dependencyIds;
            
            // Check cache
            auto cacheSpan = observability.startSpan("cache-check", SpanKind.Internal, targetSpan);
            bool isCached = cache.isCached(node.id.toString(), target.sources, deps.map!(d => d.toString()).array);
            observability.setSpanAttribute(cacheSpan, "cache.hit", isCached.to!string);
            observability.finishSpan(cacheSpan);
            
            if (isCached)
            {
                observability.setSpanAttribute(targetSpan, "build.cached", "true");
                observability.setSpanStatus(targetSpan, SpanStatus.Ok);
                
                result.success = true;
                result.cached = true;
                
                observability.publishEvent(new TargetCachedEvent(node.idString, nodeTimer.peek()));
                return result;
            }
            
            // Get handler - use ShellHandler for Shell targets, otherwise language handler
            LanguageHandler handler;
            if (target.type == TargetType.Shell)
            {
                import languages.custom.shell : ShellHandler;
                handler = new ShellHandler();
            }
            else
            {
                handler = handlers.get(target.language);
            }
            
            if (handler is null)
            {
                result.error = "No language handler found for: " ~ target.language.to!string;
                observability.recordException(targetSpan, new Exception(result.error));
                observability.setSpanStatus(targetSpan, SpanStatus.Error, result.error);
                return result;
            }
            
            // Build with action-level caching
            auto compileSpan = observability.startSpan("compile", SpanKind.Internal, targetSpan);
            observability.setSpanAttribute(compileSpan, "target.sources_count", target.sources.length.to!string);
            
            // Create build context with service container (DI pattern)
            BuildContext buildContext;
            buildContext.target = target;
            buildContext.config = services.config;
            buildContext.services = services;
            buildContext.incrementalEnabled = services.config.options.incremental;
            buildContext.recorder = (actionId, inputs, outputs, metadata, success) {
                cache.recordAction(actionId, inputs, outputs, metadata, success);
            };
            buildContext.depRecorder = (sourceFile, dependencies) {
                structuredLog.debug_("dependencies_recorded_for_").field("detail", "Dependencies recorded for " ~ sourceFile).emit();
            };
            
            // Execute with retry logic
            auto policy = resilience.policyFor(new BuildFailureError(node.idString, ""));
            auto buildResult = resilience.withRetryString(
                node.idString,
                () {
                    node.incrementRetries();
                    return handler.buildWithContext(buildContext);
                },
                policy
            );
            
            observability.finishSpan(compileSpan);
            
            if (buildResult.isOk)
            {
                auto outputHash = buildResult.unwrap();
                
                // Update cache
                auto cacheUpdateSpan = observability.startSpan("cache-update", SpanKind.Internal, targetSpan);
                cache.update(node.id.toString(), target.sources, deps.map!(d => d.toString()).array, outputHash);
                observability.finishSpan(cacheUpdateSpan);
                
                observability.setSpanStatus(targetSpan, SpanStatus.Ok);
                
                result.success = true;
                node.resetRetries();
                
                // Automatic determinism verification if enabled
                if (services.config.options.determinism.verifyAutomatic)
                {
                    auto verifySpan = observability.startSpan("determinism-verify", SpanKind.Internal, targetSpan);
                    scope(exit) observability.finishSpan(verifySpan);
                    
                    performAutomaticVerification(target, buildContext, observability, verifySpan);
                }
                
                observability.publishEvent(new TargetCompletedEvent(node.idString, nodeTimer.peek(), 0, nodeTimer.peek()));
            }
            else
            {
                auto error = buildResult.unwrapErr();
                result.error = error.message();
                
                observability.recordException(targetSpan, new Exception(error.message()));
                observability.setSpanStatus(targetSpan, SpanStatus.Error, error.message());
                
                observability.publishEvent(new TargetFailedEvent(node.idString, error.message(), nodeTimer.peek(), nodeTimer.peek()));
            }
        }
        catch (Exception e)
        {
            result.error = "Build failed with exception: " ~ e.msg;
            observability.recordException(targetSpan, e);
            observability.setSpanStatus(targetSpan, SpanStatus.Error, e.msg);
            observability.logException(e, "Build failed with exception");
            
            observability.publishEvent(new TargetFailedEvent(node.idString, result.error, nodeTimer.peek(), nodeTimer.peek()));
        }
        
        return result;
    }
    
    /// Publish target started event
    private void publishTargetStarted(BuildNode node, Duration elapsed) @trusted
    {
        // Note: This requires access to the graph for topological sort
        // Will be provided by coordinator
        observability.publishEvent(new TargetStartedEvent(node.idString, 0, 0, elapsed));
    }
    
    /// Perform automatic determinism verification after successful build
    private void performAutomaticVerification(
        Target target,
        BuildContext buildContext,
        IObservabilityService observability,
        Span verifySpan
    ) @trusted
    {
        try
        {
            auto cfg = buildContext.services.config;
            structuredLog.info("performing_automatic_determinism_verific").field("detail", "Performing automatic determinism verification for " ~ target.name).emit();
            observability.logInfo("Starting automatic determinism verification", [
                "target.name": target.name,
                "iterations": cfg.options.determinism.verifyIterations.to!string
            ]);
            
            // Create verification configuration from build options
            VerificationConfig verifyConfig;
            verifyConfig.mode = VerificationMode.Automatic;
            verifyConfig.iterations = cfg.options.determinism.verifyIterations;
            verifyConfig.failOnViolation = cfg.options.determinism.strictMode;
            verifyConfig.outputDir = cfg.options.cacheDir ~ "/verify";
            
            // Parse strategy from config
            final switch (cfg.options.determinism.verifyStrategy)
            {
                case "hash":
                    verifyConfig.strategy = VerificationStrategy.ContentHash;
                    break;
                case "bitwise":
                    verifyConfig.strategy = VerificationStrategy.BitwiseCompare;
                    break;
                case "fuzzy":
                    verifyConfig.strategy = VerificationStrategy.Fuzzy;
                    break;
                case "structural":
                    verifyConfig.strategy = VerificationStrategy.Structural;
                    break;
            }
            
            // Create integration
            auto integrationResult = DeterminismIntegration.create(verifyConfig);
            if (integrationResult.isErr)
            {
                structuredLog.warning("failed_to_create_determinism_integration").field("detail", "Failed to create determinism integration: " ~ 
                             integrationResult.unwrapErr().message()).emit();
                observability.logInfo("Determinism verification skipped", [
                    "reason": "integration_failed"
                ]);
                return;
            }
            
            auto integration = integrationResult.unwrap();
            
            // For automatic verification, we perform a quick check only
            // Full two-build comparison should be done explicitly via `bldr verify`
            // to avoid doubling build times automatically
            
            // Quick check: analyze for potential non-determinism
            auto detections = NonDeterminismDetector.analyzeCompilerCommand(
                buildContext.target.flags
            );
            
            if (detections.length > 0)
            {
                structuredLog.warning("potential_nondeterminism_detected_in_").field("detail", "Potential non-determinism detected in " ~ target.name).emit();
                observability.logInfo("Non-determinism potential detected", [
                    "target.name": target.name,
                    "detection_count": detections.length.to!string
                ]);
                
                // Log suggestions
                auto suggestions = RepairEngine.generateSuggestions(detections);
                foreach (suggestion; suggestions)
                {
                    if (suggestion.priority <= 2) // Critical and high priority only
                    {
                        structuredLog.warning("__").field("detail", "  " ~ suggestion.title ~ ": " ~ suggestion.description).emit();
                        if (suggestion.compilerFlags.length > 0)
                            structuredLog.info("____suggested_flag_").field("detail", "    Suggested flag: " ~ suggestion.compilerFlags[0]).emit();
                    }
                }
                
                observability.setSpanAttribute(verifySpan, "determinism.issues", detections.length.to!string);
                observability.setSpanAttribute(verifySpan, "determinism.verified", "false");
                
                // Fail build if strict mode
                if (cfg.options.determinism.strictMode)
                {
                    structuredLog.error("build_failed_due_to_potential_nondetermi").emit();
                    structuredLog.info("run_bldr_verify_").field("detail", "Run 'bldr verify " ~ target.name ~ "' for full verification").emit();
                    observability.setSpanStatus(verifySpan, SpanStatus.Error, 
                        "Non-determinism detected in strict mode");
                }
            }
            else
            {
                structuredLog.info("no_obvious_nondeterminism_detected_in_").field("detail", "No obvious non-determinism detected in " ~ target.name).emit();
                observability.logInfo("Determinism check passed", [
                    "target.name": target.name
                ]);
                observability.setSpanAttribute(verifySpan, "determinism.issues", "0");
                observability.setSpanAttribute(verifySpan, "determinism.verified", "true");
            }
            
            structuredLog.info("for_full_verification_run_bldr_verify_").field("detail", "For full verification, run: bldr verify " ~ target.name).emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("determinism_verification_failed_").field("detail", "Determinism verification failed: " ~ e.msg).emit();
            observability.logException(e, "Determinism verification error");
            observability.setSpanStatus(verifySpan, SpanStatus.Error, e.msg);
        }
    }
}

