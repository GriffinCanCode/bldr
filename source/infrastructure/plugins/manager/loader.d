module infrastructure.plugins.manager.loader;

import std.process : pipeProcess, Redirect, wait, kill, ProcessPipes;
import std.stdio : File;
import std.string : strip;
import std.conv : to;
import std.range : empty;
import core.time : seconds, Duration;
import std.datetime.stopwatch : StopWatch;
import infrastructure.plugins.protocol;
import infrastructure.plugins.discovery;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Plugin execution result
struct PluginExecution {
    RPCResponse response;
    string[] stderr;
    int exitCode;
    Duration duration;
}

/// Plugin loader for executing plugins
class PluginLoader {
    private PluginScanner scanner;
    private Duration defaultTimeout;
    private long nextRequestId;
    
    this(Duration timeout = 30.seconds) @safe {
        scanner = new PluginScanner();
        defaultTimeout = timeout;
        nextRequestId = 1;
    }
    
    /// Execute plugin with RPC request
    BuildResult!PluginExecution execute(
        string pluginName,
        RPCRequest request,
        Duration timeout = Duration.init
    ) @system {
        // Find plugin executable
        auto findResult = scanner.findPlugin(pluginName);
        if (findResult.isErr) {
            return Err!(PluginExecution, BuildError)(findResult.unwrapErr());
        }
        
        auto pluginPath = findResult.unwrap();
        auto actualTimeout = timeout == Duration.init ? defaultTimeout : timeout;
        
        return executePlugin(pluginPath, request, actualTimeout);
    }
    
    /// Execute plugin by path
    BuildResult!PluginExecution executePlugin(
        string pluginPath,
        RPCRequest request,
        Duration timeout
    ) @system {
        auto sw = StopWatch();
        sw.start();
        
        try {
            // Launch plugin process
            auto pipes = pipeProcess(
                [pluginPath],
                Redirect.stdin | Redirect.stdout | Redirect.stderr
            );
            
            // Send request
            auto requestJson = RPCCodec.encodeRequest(request);
            pipes.stdin.writeln(requestJson);
            pipes.stdin.flush();
            pipes.stdin.close();
            
            // Read response with timeout
            string responseLine;
            string[] stderrLines;
            
            auto readStart = StopWatch();
            readStart.start();
            
            while (readStart.peek() < timeout) {
                // Check if process has exited
                import core.sys.posix.signal : SIGTERM;
                import std.process : tryWait;
                
                auto status = tryWait(pipes.pid);
                if (status.terminated) {
                    // Process exited, read remaining output
                    if (!pipes.stdout.eof) {
                        responseLine = pipes.stdout.readln();
                    }
                    
                    // Read stderr
                    while (!pipes.stderr.eof) {
                        auto line = pipes.stderr.readln();
                        if (line) stderrLines ~= line.strip();
                    }
                    
                    break;
                }
                
                // Try to read response
                if (!pipes.stdout.eof) {
                    responseLine = pipes.stdout.readln();
                    if (responseLine) break;
                }
            }
            
            // Check for timeout
            if (readStart.peek() >= timeout) {
                // Kill plugin process
                kill(pipes.pid);
                wait(pipes.pid);
                
                auto err = new PluginError(
                    "Plugin timed out after " ~ timeout.total!"seconds".to!string ~ " seconds",
                    ErrorCode.PluginTimeout
                );
                err.addContext(ErrorContext("executing plugin", pluginPath));
                err.addSuggestion("Check if the plugin is hanging");
                err.addSuggestion("Increase timeout if the operation is expected to be slow");
                return Err!(PluginExecution, BuildError)(err);
            }
            
            // Wait for process
            auto exitCode = wait(pipes.pid);
            
            // Check if we got a response
            if (responseLine.empty) {
                auto err = new PluginError(
                    "Plugin did not produce any output",
                    ErrorCode.PluginCrashed
                );
                err.addContext(ErrorContext("executing plugin", pluginPath));
                err.addContext(ErrorContext("exit code", exitCode.to!string));
                
                if (stderrLines.length > 0) {
                    err.addContext(ErrorContext("stderr", stderrLines[0]));
                    foreach (line; stderrLines) {
                        Logger.error("Plugin stderr: " ~ line);
                    }
                }
                
                return Err!(PluginExecution, BuildError)(err);
            }
            
            // Decode response
            auto responseResult = RPCCodec.decodeResponse(responseLine.strip());
            if (responseResult.isErr) {
                return Err!(PluginExecution, BuildError)(responseResult.unwrapErr());
            }
            
            sw.stop();
            
            auto execution = PluginExecution(
                responseResult.unwrap(),
                stderrLines,
                exitCode,
                sw.peek()
            );
            
            return Ok!(PluginExecution, BuildError)(execution);
            
        } catch (Exception e) {
            auto err = new PluginError(
                "Failed to execute plugin: " ~ e.msg,
                ErrorCode.PluginError
            );
            err.addContext(ErrorContext("executing plugin", pluginPath));
            return Err!(PluginExecution, BuildError)(err);
        }
    }
    
    /// Query plugin info
    BuildResult!PluginInfo queryInfo(string pluginName) @system {
        auto request = RPCCodec.infoRequest(nextRequestId++);
        auto execResult = execute(pluginName, request, 5.seconds);
        
        if (execResult.isErr) {
            return Err!(PluginInfo, BuildError)(execResult.unwrapErr());
        }
        
        auto execution = execResult.unwrap();
        
        if (execution.response.isError) {
            auto err = new PluginError(
                "Plugin returned error: " ~ execution.response.error.message,
                ErrorCode.PluginError
            );
            return Err!(PluginInfo, BuildError)(err);
        }
        
        return PluginInfo.fromJSON(execution.response.result);
    }
    
    /// Call pre-build hook
    BuildResult!HookResult callPreHook(
        string pluginName,
        PluginTarget target,
        PluginWorkspace workspace
    ) @system {
        auto request = RPCCodec.preHookRequest(nextRequestId++, target, workspace);
        auto execResult = execute(pluginName, request);
        
        if (execResult.isErr) {
            return Err!(HookResult, BuildError)(execResult.unwrapErr());
        }
        
        auto execution = execResult.unwrap();
        
        if (execution.response.isError) {
            auto err = new PluginError(
                "Plugin hook failed: " ~ execution.response.error.message,
                ErrorCode.BuildFailed
            );
            return Err!(HookResult, BuildError)(err);
        }
        
        return HookResult.fromJSON(execution.response.result);
    }
    
    /// Call post-build hook
    BuildResult!HookResult callPostHook(
        string pluginName,
        PluginTarget target,
        PluginWorkspace workspace,
        string[] outputs,
        bool success,
        long durationMs
    ) @system {
        auto request = RPCCodec.postHookRequest(
            nextRequestId++,
            target,
            workspace,
            outputs,
            success,
            durationMs
        );
        auto execResult = execute(pluginName, request);
        
        if (execResult.isErr) {
            return Err!(HookResult, BuildError)(execResult.unwrapErr());
        }
        
        auto execution = execResult.unwrap();
        
        if (execution.response.isError) {
            auto err = new PluginError(
                "Plugin hook failed: " ~ execution.response.error.message,
                ErrorCode.BuildFailed
            );
            return Err!(HookResult, BuildError)(err);
        }
        
        return HookResult.fromJSON(execution.response.result);
    }
}

