module infrastructure.plugins.manager.lifecycle;

import std.algorithm : filter, map, canFind, remove;
import std.array : array;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.datetime.stopwatch : StopWatch;
import std.file : timeLastModified, exists;
import std.range : empty;
import core.time : Duration, seconds, msecs;
import infrastructure.plugins.protocol;
import infrastructure.plugins.manager.registry;
import infrastructure.plugins.manager.loader;
import infrastructure.plugins.discovery.scanner;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Plugin health status for circuit breaker pattern
enum PluginHealthStatus {
    Healthy,        /// Plugin is functioning normally
    Degraded,       /// Plugin has some failures but is still usable
    Unhealthy,      /// Plugin has too many failures, circuit is open
    Recovering      /// Circuit is half-open, testing if plugin recovered
}

/// Circuit breaker states
enum CircuitState {
    Closed,     /// Normal operation - requests go through
    Open,       /// Failure state - requests blocked
    HalfOpen    /// Testing recovery - limited requests allowed
}

/// Plugin health tracking with circuit breaker pattern
struct PluginHealth {
    string pluginName;
    PluginHealthStatus status = PluginHealthStatus.Healthy;
    CircuitState circuitState = CircuitState.Closed;
    
    // Failure tracking
    int consecutiveFailures = 0;
    int totalFailures = 0;
    int totalCalls = 0;
    SysTime lastFailure;
    SysTime lastSuccess;
    string lastError;
    
    // Circuit breaker config
    int failureThreshold = 3;       /// Failures before opening circuit
    Duration resetTimeout = 30.seconds;  /// Time before trying half-open
    Duration cooldownPeriod = 5.seconds; /// Cooldown between retry attempts
    
    // Hot-reload tracking
    SysTime lastModified;
    string pluginPath;
    bool needsReload = false;
    
    /// Record successful execution
    void recordSuccess() @system {
        totalCalls++;
        consecutiveFailures = 0;
        lastSuccess = Clock.currTime();
        
        if (circuitState == CircuitState.HalfOpen) {
            circuitState = CircuitState.Closed;
            status = PluginHealthStatus.Healthy;
            structuredLog.info("plugin_").field("detail", "Plugin '" ~ pluginName ~ "' recovered, circuit closed").emit();
        } else if (status == PluginHealthStatus.Degraded) {
            status = PluginHealthStatus.Healthy;
        }
    }
    
    /// Record failed execution
    void recordFailure(string error) @system {
        totalCalls++;
        totalFailures++;
        consecutiveFailures++;
        lastFailure = Clock.currTime();
        lastError = error;
        
        if (consecutiveFailures >= failureThreshold) {
            if (circuitState != CircuitState.Open) {
                circuitState = CircuitState.Open;
                status = PluginHealthStatus.Unhealthy;
                structuredLog.warning("plugin_").field("detail", "Plugin '" ~ pluginName ~ "' circuit opened after " ~ 
                    consecutiveFailures.to!string ~ " failures").emit();
            }
        } else if (consecutiveFailures > 0) {
            status = PluginHealthStatus.Degraded;
        }
    }
    
    /// Check if requests should be allowed through
    bool shouldAllowRequest() @system {
        final switch (circuitState) {
            case CircuitState.Closed:
                return true;
            case CircuitState.Open:
                // Check if enough time has passed to try half-open
                if (Clock.currTime() - lastFailure >= resetTimeout) {
                    circuitState = CircuitState.HalfOpen;
                    status = PluginHealthStatus.Recovering;
                    structuredLog.info("plugin_").field("detail", "Plugin '" ~ pluginName ~ "' entering recovery mode").emit();
                    return true;
                }
                return false;
            case CircuitState.HalfOpen:
                return true;  // Allow limited requests in half-open state
        }
    }
    
    /// Calculate failure rate
    float failureRate() const pure nothrow @nogc @safe {
        return totalCalls > 0 ? cast(float)totalFailures / totalCalls : 0.0f;
    }
}

/// Plugin execution context for graceful degradation
struct PluginExecutionContext {
    PluginInfo plugin;
    PluginTarget target;
    PluginWorkspace workspace;
    PluginFailMode failMode;
    int retryCount = 0;
    int maxRetries = 2;
    Duration retryDelay = 100.msecs;
}

/// Build lifecycle hook manager with health tracking and graceful degradation
class LifecycleManager {
    private IPluginRegistry registry;
    private PluginLoader loader;
    private PluginHealth[string] healthRegistry;
    private PluginScanner scanner;
    private bool hotReloadEnabled = true;
    
    // Callbacks for external integration
    alias PluginFailureCallback = void delegate(string pluginName, BuildError error);
    alias PluginRecoveryCallback = void delegate(string pluginName);
    
    private PluginFailureCallback onPluginFailure;
    private PluginRecoveryCallback onPluginRecovery;
    
    this(IPluginRegistry registry, PluginLoader loader) @safe {
        this.registry = registry;
        this.loader = loader;
        this.scanner = new PluginScanner();
    }
    
    /// Configure hot-reload behavior
    void setHotReloadEnabled(bool enabled) @safe {
        hotReloadEnabled = enabled;
    }
    
    /// Register failure callback for external monitoring
    void setFailureCallback(PluginFailureCallback callback) @safe {
        onPluginFailure = callback;
    }
    
    /// Register recovery callback for external monitoring
    void setRecoveryCallback(PluginRecoveryCallback callback) @safe {
        onPluginRecovery = callback;
    }
    
    /// Get health status for all plugins
    PluginHealth[string] getHealthRegistry() @system {
        return healthRegistry.dup;
    }
    
    /// Get health for specific plugin
    PluginHealth* getPluginHealth(string name) @system {
        return name in healthRegistry;
    }
    
    /// Check and reload plugins if their executables have changed
    VoidBuildResult checkAndReloadPlugins() @system {
        if (!hotReloadEnabled) return Ok!BuildError();
        
        bool needsRefresh = false;
        
        foreach (name, ref health; healthRegistry) {
            if (health.pluginPath.empty) continue;
            
            try {
                if (!exists(health.pluginPath)) {
                    // Plugin was removed
                    health.needsReload = true;
                    needsRefresh = true;
                    structuredLog.info("plugin_").field("detail", "Plugin '" ~ name ~ "' executable removed, marking for refresh").emit();
                    continue;
                }
                
                auto currentMtime = timeLastModified(health.pluginPath);
                if (currentMtime > health.lastModified) {
                    health.needsReload = true;
                    health.lastModified = currentMtime;
                    needsRefresh = true;
                    structuredLog.info("plugin_").field("detail", "Plugin '" ~ name ~ "' executable changed, marking for reload").emit();
                    
                    // Reset circuit breaker on reload - plugin may have been fixed
                    health.circuitState = CircuitState.Closed;
                    health.consecutiveFailures = 0;
                    health.status = PluginHealthStatus.Healthy;
                }
            } catch (Exception e) {
                structuredLog.warning("failed_to_check_plugin_").field("detail", "Failed to check plugin '" ~ name ~ "' for changes: " ~ e.msg).emit();
            }
        }
        
        if (needsRefresh) {
            structuredLog.info("refreshing_plugin_registry_due_to_detect").emit();
            return registry.refresh();
        }
        
        return Ok!BuildError();
    }
    
    /// Force reload a specific plugin
    VoidBuildResult reloadPlugin(string name) @system {
        auto health = name in healthRegistry;
        if (health !is null) {
            health.needsReload = true;
            health.circuitState = CircuitState.Closed;
            health.consecutiveFailures = 0;
            health.status = PluginHealthStatus.Healthy;
        }
        
        return registry.refresh();
    }
    
    /// Execute pre-build hooks with graceful degradation
    VoidBuildResult executePreHooks(PluginTarget target, PluginWorkspace workspace) @system {
        auto plugins = registry.withCapability("build.pre_hook");
        if (plugins.length == 0) return Ok!BuildError();
        
        // Check for hot-reload before execution
        auto reloadResult = checkAndReloadPlugins();
        if (reloadResult.isErr)
            structuredLog.warning("hotreload_check_failed_").field("detail", "Hot-reload check failed: " ~ reloadResult.unwrapErr().message).emit();
        
        structuredLog.debug_("executing_prebuild_hooks_for_").field("detail", "Executing pre-build hooks for " ~ plugins.length.to!string ~ " plugins").emit();
        
        foreach (plugin; plugins) {
            auto ctx = PluginExecutionContext(plugin, target, workspace, plugin.failMode);
            auto result = executeWithGracefulDegradation(ctx, &executePreHook);
            
            // Pre-hooks with Required fail mode should fail the build
            if (result.isErr && plugin.failMode == PluginFailMode.Required)
                return result;
        }
        
        return Ok!BuildError();
    }
    
    /// Execute post-build hooks with graceful degradation
    VoidBuildResult executePostHooks(
        PluginTarget target,
        PluginWorkspace workspace,
        string[] outputs,
        bool buildSuccess,
        long durationMs
    ) @system {
        auto plugins = registry.withCapability("build.post_hook");
        if (plugins.length == 0) return Ok!BuildError();
        
        structuredLog.debug_("executing_postbuild_hooks_for_").field("detail", "Executing post-build hooks for " ~ plugins.length.to!string ~ " plugins").emit();
        
        foreach (plugin; plugins) {
            // Post-hooks always use graceful degradation - they shouldn't fail the build
            auto ctx = PluginExecutionContext(plugin, target, workspace, 
                plugin.failMode == PluginFailMode.Required ? PluginFailMode.Optional : plugin.failMode);
            
            executePostHookWithContext(ctx, outputs, buildSuccess, durationMs);
        }
        
        return Ok!BuildError();
    }
    
    /// Execute a plugin operation with graceful degradation
    private VoidBuildResult executeWithGracefulDegradation(
        PluginExecutionContext ctx,
        VoidBuildResult delegate(PluginExecutionContext) @system operation
    ) @system {
        auto health = getOrCreateHealth(ctx.plugin);
        
        // Circuit breaker check
        if (!health.shouldAllowRequest()) {
            auto msg = "Plugin '" ~ ctx.plugin.name ~ "' circuit is open (too many failures)";
            structuredLog.warning("log_event").field("message", msg).emit();
            
            if (ctx.failMode == PluginFailMode.Required) {
                return VoidBuildResult.err(
                    Errors.plugin(msg, Plugin.Error)
                        .withContext("last_error", health.lastError)
                        .withSuggestion("Plugin will automatically retry after " ~ 
                            health.resetTimeout.total!"seconds".to!string ~ " seconds")
                        .withSuggestion("Force reload: bldr plugin reload " ~ ctx.plugin.name));
            }
            return Ok!BuildError();  // Graceful degradation
        }
        
        // Execute with retry logic
        VoidBuildResult lastResult;
        foreach (attempt; 0 .. ctx.maxRetries + 1) {
            if (attempt > 0) {
                structuredLog.info("retrying_plugin_").field("detail", "Retrying plugin '" ~ ctx.plugin.name ~ "' (attempt " ~ 
                    (attempt + 1).to!string ~ "/" ~ (ctx.maxRetries + 1).to!string ~ ")").emit();
                import core.thread : Thread;
                Thread.sleep(ctx.retryDelay);
            }
            
            lastResult = operation(ctx);
            
            if (lastResult.isOk) {
                health.recordSuccess();
                if (health.status == PluginHealthStatus.Healthy && onPluginRecovery !is null)
                    onPluginRecovery(ctx.plugin.name);
                return lastResult;
            }
        }
        
        // All retries failed
        auto error = lastResult.unwrapErr();
        health.recordFailure(error.message);
        
        if (onPluginFailure !is null)
            onPluginFailure(ctx.plugin.name, error);
        
        // Apply fail mode
        final switch (ctx.failMode) {
            case PluginFailMode.Required:
                return lastResult;
            case PluginFailMode.Optional:
                structuredLog.warning("plugin_").field("detail", "Plugin '" ~ ctx.plugin.name ~ "' failed (optional): " ~ error.message).emit();
                return Ok!BuildError();
            case PluginFailMode.Silent:
                return Ok!BuildError();
        }
    }
    
    /// Execute pre-hook for a single plugin
    private VoidBuildResult executePreHook(PluginExecutionContext ctx) @system {
        auto sw = StopWatch();
        sw.start();
        
        structuredLog.info("running_prebuild_hook_").field("detail", "Running pre-build hook: " ~ ctx.plugin.name).emit();
        
        auto result = loader.callPreHook(ctx.plugin.name, ctx.target, ctx.workspace);
        sw.stop();
        
        if (result.isErr) {
            structuredLog.error("prebuild_hook_failed_").field("detail", "Pre-build hook failed: " ~ ctx.plugin.name ~ " - " ~ 
                result.unwrapErr().message).emit();
            return VoidBuildResult.err(result.unwrapErr());
        }
        
        auto hookResult = result.unwrap();
        
        foreach (log; hookResult.logs)
            structuredLog.info("log_event").field("detail", "[" ~ ctx.plugin.name ~ "] " ~ log).emit();
        
        if (!hookResult.success) {
            return VoidBuildResult.err(
                Errors.plugin("Pre-build hook failed: " ~ ctx.plugin.name, Build.Failed)
                    .withContext("plugin", ctx.plugin.name));
        }
        
        structuredLog.debug_("prebuild_hook_completed_").field("detail", "Pre-build hook completed: " ~ ctx.plugin.name ~ " (" ~ 
            sw.peek().total!"msecs".to!string ~ "ms)").emit();
        
        return Ok!BuildError();
    }
    
    /// Execute post-hook for a single plugin with additional context
    private void executePostHookWithContext(
        PluginExecutionContext ctx,
        string[] outputs,
        bool buildSuccess,
        long durationMs
    ) @system {
        auto health = getOrCreateHealth(ctx.plugin);
        
        if (!health.shouldAllowRequest()) {
            if (ctx.failMode != PluginFailMode.Silent)
                structuredLog.warning("skipping_posthook_").field("detail", "Skipping post-hook '" ~ ctx.plugin.name ~ "' (circuit open)").emit();
            return;
        }
        
        auto sw = StopWatch();
        sw.start();
        
        structuredLog.info("running_postbuild_hook_").field("detail", "Running post-build hook: " ~ ctx.plugin.name).emit();
        
        auto result = loader.callPostHook(
            ctx.plugin.name, ctx.target, ctx.workspace,
            outputs, buildSuccess, durationMs
        );
        
        sw.stop();
        
        if (result.isErr) {
            health.recordFailure(result.unwrapErr().message);
            if (ctx.failMode != PluginFailMode.Silent)
                structuredLog.warning("postbuild_hook_failed_").field("detail", "Post-build hook failed: " ~ ctx.plugin.name ~ " - " ~ 
                    result.unwrapErr().message).emit();
            return;
        }
        
        auto hookResult = result.unwrap();
        health.recordSuccess();
        
        foreach (log; hookResult.logs)
            structuredLog.info("log_event").field("detail", "[" ~ ctx.plugin.name ~ "] " ~ log).emit();
        
        if (!hookResult.success && ctx.failMode != PluginFailMode.Silent)
            structuredLog.warning("postbuild_hook_reported_failure_").field("detail", "Post-build hook reported failure: " ~ ctx.plugin.name).emit();
        
        structuredLog.debug_("postbuild_hook_completed_").field("detail", "Post-build hook completed: " ~ ctx.plugin.name ~ " (" ~ 
            sw.peek().total!"msecs".to!string ~ "ms)").emit();
    }
    
    /// Get or create health tracking for a plugin
    private PluginHealth* getOrCreateHealth(PluginInfo plugin) @system {
        if (auto existing = plugin.name in healthRegistry)
            return existing;
        
        PluginHealth health;
        health.pluginName = plugin.name;
        
        // Try to get plugin path for hot-reload tracking
        auto pathResult = scanner.findPlugin(plugin.name);
        if (pathResult.isOk) {
            health.pluginPath = pathResult.unwrap();
            try {
                health.lastModified = timeLastModified(health.pluginPath);
            } catch (Exception) {}
        }
        
        healthRegistry[plugin.name] = health;
        return plugin.name in healthRegistry;
    }
    
    /// Check if any plugins handle custom target type
    bool hasCustomTypeHandler(string targetType) @system {
        foreach (plugin; registry.list()) {
            if (plugin.capabilities.canFind("target.custom_type") ||
                plugin.capabilities.canFind("target.custom_type." ~ targetType))
                return true;
        }
        return false;
    }
    
    /// Get plugins that can handle a custom target type
    PluginInfo[] getCustomTypeHandlers(string targetType) @system {
        return registry.list()
            .filter!(p => 
                p.capabilities.canFind("target.custom_type") ||
                p.capabilities.canFind("target.custom_type." ~ targetType))
            .array;
    }
    
    /// Reset health for a specific plugin (useful for testing/admin)
    void resetPluginHealth(string name) @system {
        if (auto health = name in healthRegistry) {
            health.consecutiveFailures = 0;
            health.circuitState = CircuitState.Closed;
            health.status = PluginHealthStatus.Healthy;
            structuredLog.info("reset_health_for_plugin_").field("detail", "Reset health for plugin '" ~ name ~ "'").emit();
        }
    }
    
    /// Get summary of plugin health statuses
    string getHealthSummary() @safe {
        import std.format : format;
        
        uint healthy, degraded, unhealthy;
        foreach (name, health; healthRegistry) {
            final switch (health.status) {
                case PluginHealthStatus.Healthy: healthy++; break;
                case PluginHealthStatus.Degraded: degraded++; break;
                case PluginHealthStatus.Unhealthy: unhealthy++; break;
                case PluginHealthStatus.Recovering: degraded++; break;
            }
        }
        
        return format!"Plugins: %d healthy, %d degraded, %d unhealthy"(healthy, degraded, unhealthy);
    }
}
