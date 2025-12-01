module infrastructure.plugins.manager.registry;

import std.algorithm : canFind, filter;
import std.array : array;
import infrastructure.plugins.protocol;
import infrastructure.plugins.discovery;
import infrastructure.errors;

/// Plugin registry interface
interface IPluginRegistry {
    /// Discover and register all plugins
    Result!BuildError refresh();
    
    /// Get plugin info by name
    Result!(PluginInfo, BuildError) get(string name);
    
    /// Check if plugin exists
    bool has(string name);
    
    /// List all registered plugins
    PluginInfo[] list();
    
    /// Get plugins with specific capability
    PluginInfo[] withCapability(string capability);
}

/// Concrete plugin registry implementation
class PluginRegistry : IPluginRegistry {
    private PluginInfo[string] plugins;
    private PluginScanner scanner;
    private PluginValidator validator;
    private bool initialized;
    
    this(string builderVersion) @safe {
        scanner = new PluginScanner();
        validator = new PluginValidator(builderVersion);
        initialized = false;
    }
    
    /// Discover and register all plugins
    Result!BuildError refresh() @system {
        // Try to load from cache first
        auto cacheResult = scanner.loadCache();
        if (cacheResult.isOk) {
            auto cached = cacheResult.unwrap();
            if (cached.length > 0) {
                foreach (info; cached) {
                    plugins[info.name] = info;
                }
                initialized = true;
                return Ok!BuildError();
            }
        }
        
        // Discover plugins
        auto discoverResult = scanner.discover();
        if (discoverResult.isErr) {
            return Result!BuildError.err(discoverResult.unwrapErr());
        }
        
        auto discovered = discoverResult.unwrap();
        
        // Validate and register each plugin
        foreach (info; discovered) {
            auto validateResult = validator.validate(info);
            if (validateResult.isOk) {
                plugins[info.name] = info;
            }
        }
        
        // Save to cache
        auto saveResult = scanner.saveCache(plugins.values);
        if (saveResult.isErr) {
            // Cache save failure is non-fatal
        }
        
        initialized = true;
        return Ok!BuildError();
    }
    
    /// Get plugin info by name
    Result!(PluginInfo, BuildError) get(string name) @system {
        if (!initialized) {
            auto refreshResult = refresh();
            if (refreshResult.isErr) {
                return Err!(PluginInfo, BuildError)(refreshResult.unwrapErr());
            }
        }
        
        if (auto info = name in plugins) {
            return Ok!(PluginInfo, BuildError)(*info);
        }
        
        auto err = new PluginError(
            "Plugin not found: " ~ name,
            ErrorCode.ToolNotFound
        );
        err.addSuggestion("Install the plugin: brew install builder-plugin-" ~ name);
        err.addSuggestion("List available plugins: bldr plugin list");
        err.addSuggestion("Refresh plugin registry: bldr plugin refresh");
        return Err!(PluginInfo, BuildError)(err);
    }
    
    /// Check if plugin exists
    bool has(string name) @system {
        if (!initialized) {
            auto refreshResult = refresh();
            if (refreshResult.isErr) {
                return false;
            }
        }
        
        return (name in plugins) !is null;
    }
    
    /// List all registered plugins
    PluginInfo[] list() @system {
        if (!initialized) {
            auto refreshResult = refresh();
            if (refreshResult.isErr) {
                return [];
            }
        }
        
        return plugins.values;
    }
    
    /// Get plugins with specific capability
    PluginInfo[] withCapability(string capability) @system {
        if (!initialized) {
            auto refreshResult = refresh();
            if (refreshResult.isErr) {
                return [];
            }
        }
        
        return plugins.values
            .filter!(p => p.capabilities.canFind(capability))
            .array;
    }
}

/// Null plugin registry for testing
class NullPluginRegistry : IPluginRegistry {
    Result!BuildError refresh() @system {
        return Ok!BuildError();
    }
    
    Result!(PluginInfo, BuildError) get(string name) @system {
        auto err = new PluginError(
            "Plugin not found: " ~ name,
            ErrorCode.ToolNotFound
        );
        return Err!(PluginInfo, BuildError)(err);
    }
    
    bool has(string name) pure nothrow @nogc @safe {
        return false;
    }
    
    PluginInfo[] list() pure nothrow @safe {
        return [];
    }
    
    PluginInfo[] withCapability(string capability) pure nothrow @safe {
        return [];
    }
}

