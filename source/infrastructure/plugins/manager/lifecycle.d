module infrastructure.plugins.manager.lifecycle;

import std.algorithm : filter, map;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import infrastructure.plugins.protocol;
import infrastructure.plugins.manager.registry;
import infrastructure.plugins.manager.loader;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Build lifecycle hook manager
class LifecycleManager {
    private IPluginRegistry registry;
    private PluginLoader loader;
    
    this(IPluginRegistry registry, PluginLoader loader) @safe {
        this.registry = registry;
        this.loader = loader;
    }
    
    /// Execute pre-build hooks for all registered plugins
    VoidBuildResult executePreHooks(
        PluginTarget target,
        PluginWorkspace workspace
    ) @system {
        // Get plugins with pre-hook capability
        auto plugins = registry.withCapability("build.pre_hook");
        
        if (plugins.length == 0) {
            return Ok!BuildError();
        }
        
        Logger.debugLog("Executing pre-build hooks for " ~ plugins.length.to!string ~ " plugins");
        
        foreach (plugin; plugins) {
            auto sw = StopWatch();
            sw.start();
            
            Logger.info("Running pre-build hook: " ~ plugin.name);
            
            auto result = loader.callPreHook(plugin.name, target, workspace);
            
            sw.stop();
            
            if (result.isErr) {
                Logger.error("Pre-build hook failed: " ~ plugin.name ~ " - " ~ 
                    result.unwrapErr().message);
                return VoidBuildResult.err(result.unwrapErr());
            }
            
            auto hookResult = result.unwrap();
            
            // Log plugin output
            foreach (log; hookResult.logs) {
                Logger.info("[" ~ plugin.name ~ "] " ~ log);
            }
            
            if (!hookResult.success) {
                return VoidBuildResult.err(
                    Errors.plugin("Pre-build hook failed: " ~ plugin.name, ErrorCode.BuildFailed)
                        .withContext("plugin", plugin.name)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            Logger.debugLog("Pre-build hook completed: " ~ plugin.name ~ " (" ~ 
                sw.peek().total!"msecs".to!string ~ "ms)");
        }
        
        return Ok!BuildError();
    }
    
    /// Execute post-build hooks for all registered plugins
    VoidBuildResult executePostHooks(
        PluginTarget target,
        PluginWorkspace workspace,
        string[] outputs,
        bool buildSuccess,
        long durationMs
    ) @system {
        // Get plugins with post-hook capability
        auto plugins = registry.withCapability("build.post_hook");
        
        if (plugins.length == 0) {
            return Ok!BuildError();
        }
        
        Logger.debugLog("Executing post-build hooks for " ~ plugins.length.to!string ~ " plugins");
        
        foreach (plugin; plugins) {
            auto sw = StopWatch();
            sw.start();
            
            Logger.info("Running post-build hook: " ~ plugin.name);
            
            auto result = loader.callPostHook(
                plugin.name,
                target,
                workspace,
                outputs,
                buildSuccess,
                durationMs
            );
            
            sw.stop();
            
            if (result.isErr) {
                // Post-hook failures are non-fatal (just log them)
                Logger.error("Post-build hook failed: " ~ plugin.name ~ " - " ~ 
                    result.unwrapErr().message);
                continue;
            }
            
            auto hookResult = result.unwrap();
            
            // Log plugin output
            foreach (log; hookResult.logs) {
                Logger.info("[" ~ plugin.name ~ "] " ~ log);
            }
            
            if (!hookResult.success) {
                Logger.warning("Post-build hook reported failure: " ~ plugin.name);
            }
            
            Logger.debugLog("Post-build hook completed: " ~ plugin.name ~ " (" ~ 
                sw.peek().total!"msecs".to!string ~ "ms)");
        }
        
        return Ok!BuildError();
    }
    
    /// Check if any plugins handle custom target type
    bool hasCustomTypeHandler(string targetType) @system {
        auto plugins = registry.list();
        
        foreach (plugin; plugins) {
            if (plugin.capabilities.canFind("target.custom_type") ||
                plugin.capabilities.canFind("target.custom_type." ~ targetType)) {
                return true;
            }
        }
        
        return false;
    }
    
    /// Get plugins that can handle a custom target type
    PluginInfo[] getCustomTypeHandlers(string targetType) @system {
        return registry.list()
            .filter!(p => 
                p.capabilities.canFind("target.custom_type") ||
                p.capabilities.canFind("target.custom_type." ~ targetType)
            )
            .array;
    }
}

