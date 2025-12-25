module infrastructure.plugins.discovery.scanner;

import std.file;
import std.path;
import std.process : environment;
import std.algorithm : canFind, filter, map, startsWith;
import std.array : array, split;
import std.string : strip, toStringz;
import std.range : empty;
import std.conv : to;
import std.json;
import infrastructure.plugins.protocol;
import infrastructure.utils.logging.logger;
import infrastructure.utils.process.checker;
import infrastructure.errors;

/// Plugin scanner for discovering installed plugins
class PluginScanner {
    private static immutable PLUGIN_PREFIX = "builder-plugin-";
    private static immutable CACHE_FILE = ".builder-cache/plugins.json";
    
    /// Search paths for plugins (in priority order)
    private string[] searchPaths;
    
    this() @safe {
        initializeSearchPaths();
    }
    
    /// Initialize search paths from environment
    private void initializeSearchPaths() @trusted {
        searchPaths = [];
        
        // 1. User plugin directory
        auto home = environment.get("HOME");
        if (home) {
            searchPaths ~= buildPath(home, ".builder", "plugins");
        }
        
        // 2. System directories
        searchPaths ~= "/usr/local/bin";
        searchPaths ~= "/opt/homebrew/bin";
        
        // 3. PATH directories
        auto pathEnv = environment.get("PATH");
        if (pathEnv) {
            foreach (dir; pathEnv.split(":")) {
                if (!dir.strip().empty && !searchPaths.canFind(dir)) {
                    searchPaths ~= dir.strip();
                }
            }
        }
    }
    
    /// Discover all installed plugins
    BuildResult!(PluginInfo[]) discover() @system {
        Logger.debugLog("Scanning for plugins in " ~ searchPaths.length.to!string ~ " directories");
        
        PluginInfo[] plugins;
        
        foreach (dir; searchPaths) {
            if (!exists(dir) || !isDir(dir))
                continue;
            
            try {
                auto entries = dirEntries(dir, SpanMode.shallow)
                    .filter!(e => e.isFile)
                    .filter!(e => baseName(e.name).startsWith(PLUGIN_PREFIX))
                    .array;
                
                foreach (entry; entries) {
                    auto infoResult = queryPluginInfo(entry.name);
                    if (infoResult.isOk) {
                        plugins ~= infoResult.unwrap();
                        Logger.debugLog("Found plugin: " ~ infoResult.unwrap().name);
                    } else {
                        Logger.warning("Failed to query plugin " ~ entry.name ~ ": " ~ 
                            infoResult.unwrapErr().message);
                    }
                }
            } catch (Exception e) {
                Logger.warning("Failed to scan directory " ~ dir ~ ": " ~ e.msg);
            }
        }
        
        Logger.info("Discovered " ~ plugins.length.to!string ~ " plugins");
        return Ok!(PluginInfo[], BuildError)(plugins);
    }
    
    /// Find plugin by name
    BuildResult!string findPlugin(string name) @system {
        auto fullName = name.startsWith(PLUGIN_PREFIX) ? name : PLUGIN_PREFIX ~ name;
        
        foreach (dir; searchPaths) {
            auto path = buildPath(dir, fullName);
            if (exists(path) && isFile(path)) {
                // Check if executable
                version(Posix) {
                    import core.sys.posix.sys.stat;
                    stat_t statbuf;
                    if (stat(path.toStringz(), &statbuf) == 0) {
                        if ((statbuf.st_mode & S_IXUSR) != 0) {
                            return Ok!(string, BuildError)(path);
                        }
                    }
                }
                version(Windows) {
                    // On Windows, check file extension
                    auto ext = extension(path);
                    if (ext == ".exe" || ext == ".bat" || ext == ".cmd") {
                        return Ok!(string, BuildError)(path);
                    }
                }
            }
        }
        
        return Err!(string, BuildError)(
            Errors.plugin("Plugin not found: " ~ name, ErrorCode.ToolNotFound)
                .withSuggestion("Install the plugin: brew install builder-plugin-" ~ name)
                .withSuggestion("Check if the plugin is in PATH: which " ~ fullName)
                .withSuggestion("List installed plugins: bldr plugin list")
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
    
    /// Query plugin for its metadata
    BuildResult!PluginInfo queryPluginInfo(string pluginPath) @system {
        import std.process : pipeProcess, Redirect, wait;
        import std.stdio : File;
        
        try {
            // Create info request
            auto request = RPCCodec.infoRequest(1);
            auto requestJson = RPCCodec.encodeRequest(request);
            
            // Launch plugin process
            auto pipes = pipeProcess(
                [pluginPath],
                Redirect.stdin | Redirect.stdout | Redirect.stderr
            );
            
            // Send request
            pipes.stdin.writeln(requestJson);
            pipes.stdin.flush();
            pipes.stdin.close();
            
            // Read response (timeout after 5 seconds)
            import core.time : seconds;
            import std.datetime.stopwatch : StopWatch;
            
            string responseLine;
            auto sw = StopWatch();
            sw.start();
            
            while (sw.peek() < 5.seconds) {
                if (!pipes.stdout.eof) {
                    responseLine = pipes.stdout.readln();
                    if (responseLine) break;
                }
            }
            
            // Wait for process to finish
            auto status = wait(pipes.pid);
            
            if (responseLine.empty) {
                return Err!(PluginInfo, BuildError)(
                    Errors.plugin("Plugin did not respond to info request: " ~ pluginPath, ErrorCode.PluginTimeout)
                        .withSuggestion("Check if the plugin is a valid Builder plugin")
                        .withSuggestion("Run the plugin manually to see error output")
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            // Decode response
            auto responseResult = RPCCodec.decodeResponse(responseLine.strip());
            if (responseResult.isErr) {
                return Err!(PluginInfo, BuildError)(responseResult.unwrapErr());
            }
            
            auto response = responseResult.unwrap();
            if (response.isError) {
                return Err!(PluginInfo, BuildError)(
                    Errors.plugin("Plugin returned error: " ~ response.error.message, ErrorCode.PluginError)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            // Parse plugin info
            return PluginInfo.fromJSON(response.result);
            
        } catch (Exception e) {
            return Err!(PluginInfo, BuildError)(
                Errors.plugin("Failed to query plugin " ~ pluginPath ~ ": " ~ e.msg, ErrorCode.PluginError)
                    .withContext("querying plugin", "process execution failed")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Load cached plugin information
    BuildResult!(PluginInfo[]) loadCache() @system {
        try {
            if (!exists(CACHE_FILE))
                return Ok!(PluginInfo[], BuildError)([]);
            
            auto json = parseJSON(readText(CACHE_FILE));
            PluginInfo[] plugins;
            
            foreach (item; json.array) {
                auto infoResult = PluginInfo.fromJSON(item);
                if (infoResult.isOk) {
                    plugins ~= infoResult.unwrap();
                }
            }
            
            return Ok!(PluginInfo[], BuildError)(plugins);
        } catch (Exception e) {
            // Cache load failure is non-fatal, just return empty
            return Ok!(PluginInfo[], BuildError)([]);
        }
    }
    
    /// Save plugin information to cache
    VoidBuildResult saveCache(PluginInfo[] plugins) @system {
        try {
            import std.file : mkdirRecurse;
            
            // Ensure cache directory exists
            auto cacheDir = dirName(CACHE_FILE);
            if (!exists(cacheDir)) {
                mkdirRecurse(cacheDir);
            }
            
            // Convert to JSON array
            JSONValue[] jsonArray;
            foreach (plugin; plugins) {
                jsonArray ~= plugin.toJSON();
            }
            
            // Write to file
            auto json = JSONValue(jsonArray);
            std.file.write(CACHE_FILE, json.toPrettyString());
            
            return Ok!BuildError();
        } catch (Exception e) {
            return VoidBuildResult.err(
                Errors.plugin("Failed to save plugin cache: " ~ e.msg, ErrorCode.CacheSaveFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
}

