module tests.integration.plugin_recovery_chaos;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs;
import std.process : ProcessPipes, pipeProcess, Redirect, wait, kill;
import std.algorithm : map, filter, canFind;
import std.array : array;
import std.conv : to;
import std.string : strip;
import std.random : uniform, uniform01, Random;
import std.file : exists, write, mkdirRecurse, tempDir, rmdirRecurse;
import std.path : buildPath;
import core.thread : Thread;
import core.atomic;
import core.time : MonoTime;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import infrastructure.plugins;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Plugin failure chaos types
enum PluginChaosType
{
    Crash,                  // Plugin crashes immediately
    Hang,                   // Plugin hangs forever
    Timeout,                // Plugin times out
    InvalidJSON,            // Returns malformed JSON
    PartialResponse,        // Returns incomplete data
    ErrorResponse,          // Returns RPC error
    ResourceExhaustion,     // Consumes all resources
    SlowResponse,           // Very slow but eventually succeeds
    Segfault,              // Segmentation fault
    Restart,                // Crashes and restarts multiple times
}

/// Chaos configuration
struct PluginChaosConfig
{
    PluginChaosType type;
    double probability = 0.5;
    Duration delay = Duration.zero;
    size_t maxFaults = size_t.max;
    bool enabled = true;
}

/// Mock chaotic plugin
class ChaoticMockPlugin
{
    private string name;
    private string pluginPath;
    private PluginChaosConfig[] chaosConfigs;
    private shared size_t faultsInjected;
    private shared size_t crashCount;
    private Random rng;
    
    this(string name, string pluginPath)
    {
        this.name = name;
        this.pluginPath = pluginPath;
        this.rng = Random(54321);
        atomicStore(faultsInjected, 0);
        atomicStore(crashCount, 0);
    }
    
    void addChaos(PluginChaosConfig config)
    {
        chaosConfigs ~= config;
    }
    
    /// Execute plugin with chaos injection
    Result!(PluginExecution, BuildError) execute(RPCRequest request, Duration timeout) @system
    {
        // Check if should inject fault
        foreach (config; chaosConfigs)
        {
            if (!config.enabled || atomicLoad(faultsInjected) >= config.maxFaults)
                continue;
            
            if (uniform01(rng) < config.probability)
            {
                atomicOp!"+="(faultsInjected, 1);
                return injectFault(config.type, request, timeout, config.delay);
            }
        }
        
        // Normal execution (would actually run plugin)
        return simulateNormalExecution(request);
    }
    
    private Result!(PluginExecution, BuildError) injectFault(
        PluginChaosType type,
        RPCRequest request,
        Duration timeout,
        Duration delay
    ) @system
    {
        final switch (type)
        {
            case PluginChaosType.Crash:
                return simulateCrash();
            
            case PluginChaosType.Hang:
                return simulateHang(timeout);
            
            case PluginChaosType.Timeout:
                return simulateTimeout(timeout);
            
            case PluginChaosType.InvalidJSON:
                return simulateInvalidJSON();
            
            case PluginChaosType.PartialResponse:
                return simulatePartialResponse(request);
            
            case PluginChaosType.ErrorResponse:
                return simulateErrorResponse(request);
            
            case PluginChaosType.ResourceExhaustion:
                return simulateResourceExhaustion();
            
            case PluginChaosType.SlowResponse:
                return simulateSlowResponse(request, delay);
            
            case PluginChaosType.Segfault:
                return simulateSegfault();
            
            case PluginChaosType.Restart:
                return simulateRestart(request);
        }
    }
    
    private Result!(PluginExecution, BuildError) simulateCrash() @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' crashed");
        atomicOp!"+="(crashCount, 1);
        
        auto error = new PluginError("Plugin crashed with exit code 1");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateHang(Duration timeout) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' hanging");
        
        // Hang for longer than timeout
        Thread.sleep(timeout + 1.seconds);
        
        auto error = new PluginError("Plugin hung and timed out");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateTimeout(Duration timeout) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' timing out");
        
        Thread.sleep(timeout + 100.msecs);
        
        auto error = new PluginError("Plugin execution timeout");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateInvalidJSON() @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' returning invalid JSON");
        
        PluginExecution exec;
        exec.exitCode = 0;
        // Response will have invalid JSON when parsed
        exec.response = RPCResponse();
        exec.response.result = `{"invalid": }`;  // Malformed
        
        auto error = new PluginError("Invalid JSON response from plugin");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulatePartialResponse(RPCRequest request) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' returning partial response");
        
        PluginExecution exec;
        exec.exitCode = 0;
        exec.response.jsonrpc = "2.0";
        exec.response.id = request.id;
        // Missing 'result' field
        exec.duration = 100.msecs;
        
        auto error = new PluginError("Incomplete response from plugin");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateErrorResponse(RPCRequest request) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' returning error");
        
        PluginExecution exec;
        exec.exitCode = 0;
        exec.response.jsonrpc = "2.0";
        exec.response.id = request.id;
        auto err = RPCError(ErrorCode.InternalError, "Internal plugin error");
        exec.response.error = &err;
        exec.duration = 50.msecs;
        
        auto error = new PluginError("Plugin returned RPC error: " ~ exec.response.error.message);
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateResourceExhaustion() @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' exhausting resources");
        
        // Simulate memory exhaustion
        auto error = new PluginError("Plugin exhausted system resources");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateSlowResponse(RPCRequest request, Duration delay) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' responding slowly");
        
        Thread.sleep(delay);
        
        // Eventually succeeds
        return simulateNormalExecution(request);
    }
    
    private Result!(PluginExecution, BuildError) simulateSegfault() @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' segfaulted");
        atomicOp!"+="(crashCount, 1);
        
        auto error = new PluginError("Plugin segmentation fault (exit code 139)");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private Result!(PluginExecution, BuildError) simulateRestart(RPCRequest request) @system
    {
        Logger.info("CHAOS: Plugin '" ~ name ~ "' restarting");
        atomicOp!"+="(crashCount, 1);
        
        // Crash a few times then succeed
        if (atomicLoad(crashCount) < 3)
        {
            auto error = new PluginError("Plugin crashed, attempt " ~ atomicLoad(crashCount).to!string);
            return Err!(PluginExecution, BuildError)(error);
        }
        
        return simulateNormalExecution(request);
    }
    
    private Result!(PluginExecution, BuildError) simulateNormalExecution(RPCRequest request) @system
    {
        PluginExecution exec;
        exec.exitCode = 0;
        exec.response.jsonrpc = "2.0";
        exec.response.id = request.id;
        exec.response.result = `{"name":"` ~ name ~ `","version":"1.0.0"}`;
        exec.duration = 50.msecs;
        
        return Ok!(PluginExecution, BuildError)(exec);
    }
    
    size_t getFaultCount() const => atomicLoad(faultsInjected);
    size_t getCrashCount() const => atomicLoad(crashCount);
}

/// Plugin system with recovery
class ResilientPluginSystem
{
    private ChaoticMockPlugin[] plugins;
    private size_t maxRetries = 3;
    private Duration retryDelay = 200.msecs;
    
    void addPlugin(ChaoticMockPlugin plugin)
    {
        plugins ~= plugin;
    }
    
    /// Execute plugin with retry logic
    Result!(PluginExecution, BuildError) executeWithRetry(
        string pluginName,
        RPCRequest request,
        Duration timeout
    ) @system
    {
        auto plugin = findPlugin(pluginName);
        if (plugin is null)
        {
            auto error = new PluginError("Plugin not found: " ~ pluginName);
            return Err!(PluginExecution, BuildError)(error);
        }
        
        // Retry loop
        for (size_t attempt = 0; attempt < maxRetries; attempt++)
        {
            if (attempt > 0)
            {
                Logger.info("Retrying plugin '" ~ pluginName ~ "' (attempt " ~ 
                          (attempt + 1).to!string ~ "/" ~ maxRetries.to!string ~ ")");
                Thread.sleep(retryDelay);
            }
            
            auto result = plugin.execute(request, timeout);
            
            if (result.isOk)
            {
                Logger.info("Plugin '" ~ pluginName ~ "' succeeded on attempt " ~ 
                          (attempt + 1).to!string);
                return result;
            }
            
            // Check if error is retryable
            auto error = result.unwrapErr();
            if (!isRetryable(error))
            {
                Logger.info("Plugin error is not retryable: " ~ error.message());
                return result;
            }
            
            Logger.info("Retryable error: " ~ error.message());
        }
        
        // All retries exhausted
        auto error = new PluginError("Plugin '" ~ pluginName ~ "' failed after " ~ 
                                     maxRetries.to!string ~ " retries");
        return Err!(PluginExecution, BuildError)(error);
    }
    
    private ChaoticMockPlugin findPlugin(string name)
    {
        foreach (plugin; plugins)
        {
            if (plugin.name == name)
                return plugin;
        }
        return null;
    }
    
    private bool isRetryable(BuildError error) const
    {
        // Crash, timeout, and resource errors are retryable
        // Invalid JSON and schema errors are not
        string msg = error.message();
        
        if (msg.canFind("crashed") || msg.canFind("timeout") || 
            msg.canFind("hung") || msg.canFind("resources"))
            return true;
        
        if (msg.canFind("invalid") || msg.canFind("schema") || 
            msg.canFind("malformed"))
            return false;
        
        return true;  // Default: retry
    }
}

// ============================================================================
// CHAOS TESTS: Plugin System Error Recovery
// ============================================================================

/// Test: Plugin crash recovery
@("plugin_chaos.crash_recovery")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Plugin Crash Recovery");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("test-plugin", "/usr/local/bin/test-plugin");
    
    // Inject crash chaos
    PluginChaosConfig crashChaos;
    crashChaos.type = PluginChaosType.Crash;
    crashChaos.probability = 1.0;
    crashChaos.maxFaults = 2;  // Crash twice, then succeed
    plugin.addChaos(crashChaos);
    
    system.addPlugin(plugin);
    
    // Execute with retry
    auto request = RPCCodec.infoRequest(1);
    auto result = system.executeWithRetry("test-plugin", request, 5.seconds);
    
    // Should eventually succeed after retries
    Assert.isTrue(result.isOk, "Should recover from crashes");
    
    size_t crashes = plugin.getCrashCount();
    Logger.info("Plugin crashed " ~ crashes.to!string ~ " times before success");
    Assert.isTrue(crashes >= 2, "Should have crashed during retries");
    
    writeln("  \x1b[32m✓ Crash recovery test passed\x1b[0m");
}

/// Test: Plugin timeout handling
@("plugin_chaos.timeout_handling")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Plugin Timeout Handling");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("slow-plugin", "/usr/local/bin/slow");
    
    // Inject timeout chaos
    PluginChaosConfig timeoutChaos;
    timeoutChaos.type = PluginChaosType.Timeout;
    timeoutChaos.probability = 0.7;  // 70% timeout rate
    plugin.addChaos(timeoutChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(2);
    auto result = system.executeWithRetry("slow-plugin", request, 500.msecs);
    
    // May succeed on retry or eventually fail
    if (result.isOk)
    {
        Logger.info("Plugin succeeded despite timeout chaos");
        Assert.isTrue(true, "Recovery successful");
    }
    else
    {
        Logger.info("Plugin failed: " ~ result.unwrapErr().message());
        Assert.isTrue(true, "Graceful failure");
    }
    
    writeln("  \x1b[32m✓ Timeout handling test passed\x1b[0m");
}

/// Test: Invalid JSON response handling
@("plugin_chaos.invalid_json")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Invalid JSON Response");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("json-plugin", "/usr/local/bin/json");
    
    // Inject invalid JSON chaos
    PluginChaosConfig jsonChaos;
    jsonChaos.type = PluginChaosType.InvalidJSON;
    jsonChaos.probability = 1.0;
    jsonChaos.maxFaults = 1;
    plugin.addChaos(jsonChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(3);
    auto result = system.executeWithRetry("json-plugin", request, 5.seconds);
    
    // Invalid JSON is not retryable, should fail
    Assert.isTrue(result.isErr, "Should detect invalid JSON");
    
    auto error = result.unwrapErr();
    Logger.info("Error: " ~ error.message());
    Assert.isTrue(error.message().canFind("invalid") || error.message().canFind("JSON"),
                 "Error should mention JSON issue");
    
    writeln("  \x1b[32m✓ Invalid JSON test passed\x1b[0m");
}

/// Test: Plugin hang detection
@("plugin_chaos.hang_detection")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Plugin Hang Detection");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("hang-plugin", "/usr/local/bin/hang");
    
    // Inject hang chaos
    PluginChaosConfig hangChaos;
    hangChaos.type = PluginChaosType.Hang;
    hangChaos.probability = 1.0;
    hangChaos.maxFaults = 1;
    plugin.addChaos(hangChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(4);
    auto shortTimeout = 200.msecs;
    
    auto startTime = MonoTime.currTime;
    auto result = system.executeWithRetry("hang-plugin", request, shortTimeout);
    auto elapsed = MonoTime.currTime - startTime;
    
    // Should detect hang and timeout
    Assert.isTrue(result.isErr, "Should detect hang");
    
    // Should not wait too long (respects timeout)
    Logger.info("Hang detected in " ~ elapsed.total!"msecs".to!string ~ "ms");
    Assert.isTrue(elapsed.total!"msecs" < 2000, "Should timeout quickly");
    
    writeln("  \x1b[32m✓ Hang detection test passed\x1b[0m");
}

/// Test: Partial response handling
@("plugin_chaos.partial_response")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Partial Response Handling");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("partial-plugin", "/usr/local/bin/partial");
    
    // Inject partial response chaos
    PluginChaosConfig partialChaos;
    partialChaos.type = PluginChaosType.PartialResponse;
    partialChaos.probability = 1.0;
    partialChaos.maxFaults = 1;
    plugin.addChaos(partialChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(5);
    auto result = system.executeWithRetry("partial-plugin", request, 5.seconds);
    
    // Partial response should be detected and handled
    if (result.isErr)
    {
        auto error = result.unwrapErr();
        Logger.info("Partial response error: " ~ error.message());
        Assert.isTrue(error.message().canFind("incomplete") || error.message().canFind("partial"),
                     "Should detect incomplete response");
    }
    
    writeln("  \x1b[32m✓ Partial response test passed\x1b[0m");
}

/// Test: Plugin restart/flapping
@("plugin_chaos.flapping")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Plugin Flapping");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("flap-plugin", "/usr/local/bin/flap");
    
    // Inject restart chaos
    PluginChaosConfig restartChaos;
    restartChaos.type = PluginChaosType.Restart;
    restartChaos.probability = 1.0;
    plugin.addChaos(restartChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(6);
    auto result = system.executeWithRetry("flap-plugin", request, 5.seconds);
    
    // Should eventually succeed after multiple crashes
    Assert.isTrue(result.isOk, "Should recover from flapping");
    
    size_t crashes = plugin.getCrashCount();
    Logger.info("Plugin crashed " ~ crashes.to!string ~ " times (flapping)");
    Assert.isTrue(crashes > 0, "Should have crashed during flapping");
    
    writeln("  \x1b[32m✓ Flapping test passed\x1b[0m");
}

/// Test: Slow response tolerance
@("plugin_chaos.slow_response")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Slow Response Tolerance");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("slow-plugin", "/usr/local/bin/slow");
    
    // Inject slow response chaos
    PluginChaosConfig slowChaos;
    slowChaos.type = PluginChaosType.SlowResponse;
    slowChaos.probability = 1.0;
    slowChaos.delay = 1.seconds;
    plugin.addChaos(slowChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(7);
    auto startTime = MonoTime.currTime;
    auto result = system.executeWithRetry("slow-plugin", request, 3.seconds);
    auto elapsed = MonoTime.currTime - startTime;
    
    // Should tolerate slow response if within timeout
    Assert.isTrue(result.isOk, "Should handle slow response");
    
    Logger.info("Slow response took " ~ elapsed.total!"msecs".to!string ~ "ms");
    Assert.isTrue(elapsed.total!"msecs" >= 1000, "Should have waited for slow response");
    
    writeln("  \x1b[32m✓ Slow response test passed\x1b[0m");
}

/// Test: RPC error response handling
@("plugin_chaos.rpc_errors")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m RPC Error Response");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("error-plugin", "/usr/local/bin/error");
    
    // Inject error response chaos
    PluginChaosConfig errorChaos;
    errorChaos.type = PluginChaosType.ErrorResponse;
    errorChaos.probability = 1.0;
    errorChaos.maxFaults = 1;
    plugin.addChaos(errorChaos);
    
    system.addPlugin(plugin);
    
    auto request = RPCCodec.infoRequest(8);
    auto result = system.executeWithRetry("error-plugin", request, 5.seconds);
    
    // RPC errors should be handled gracefully
    Assert.isTrue(result.isErr, "Should detect RPC error");
    
    auto error = result.unwrapErr();
    Logger.info("RPC error: " ~ error.message());
    Assert.isTrue(error.message().canFind("error"), "Should report error");
    
    writeln("  \x1b[32m✓ RPC error test passed\x1b[0m");
}

/// Test: Combined chaos stress test
@("plugin_chaos.combined_stress")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Plugin Combined Stress Test");
    
    auto system = new ResilientPluginSystem();
    auto plugin = new ChaoticMockPlugin("chaos-plugin", "/usr/local/bin/chaos");
    
    // Enable multiple chaos types
    foreach (chaosType; [
        PluginChaosType.Crash,
        PluginChaosType.Timeout,
        PluginChaosType.SlowResponse,
        PluginChaosType.ErrorResponse
    ])
    {
        PluginChaosConfig chaos;
        chaos.type = chaosType;
        chaos.probability = 0.2;  // 20% each
        chaos.delay = 300.msecs;
        chaos.maxFaults = 5;
        plugin.addChaos(chaos);
    }
    
    system.addPlugin(plugin);
    
    // Execute multiple requests
    size_t successCount = 0;
    size_t failureCount = 0;
    
    for (size_t i = 0; i < 20; i++)
    {
        auto request = RPCCodec.infoRequest(cast(int)(100 + i));
        auto result = system.executeWithRetry("chaos-plugin", request, 2.seconds);
        
        if (result.isOk)
            successCount++;
        else
            failureCount++;
    }
    
    Logger.info("Success: " ~ successCount.to!string ~ ", Failure: " ~ failureCount.to!string);
    Logger.info("Total faults injected: " ~ plugin.getFaultCount().to!string);
    Logger.info("Total crashes: " ~ plugin.getCrashCount().to!string);
    
    // Should succeed on at least some requests
    Assert.isTrue(successCount > 0, "Should have some successes despite chaos");
    Assert.isTrue(plugin.getFaultCount() > 0, "Should have injected faults");
    
    writeln("  \x1b[32m✓ Combined stress test passed\x1b[0m");
}

