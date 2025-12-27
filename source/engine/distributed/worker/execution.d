module engine.distributed.worker.execution;

import std.datetime : Duration, Clock, seconds, msecs;
import core.time : MonoTime;
import std.conv : to;
import std.file : read, exists;
import std.path : buildPath;
import core.thread : Thread;
import core.atomic;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.distributed.storage.artifacts;
import infrastructure.utils.logging;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.crypto.blake3 : Blake3;

/// Worker executor - handles action execution
struct WorkerExecutor
{
    private ArtifactStore artifactStore;
    
    /// Constructor
    this(ArtifactStore artifactStore) @safe
    {
        this.artifactStore = artifactStore;
    }
    
    /// Execute build action
    void executeAction(ActionRequest request, bool enableSandboxing, Capabilities defaultCapabilities,
        void delegate(ActionResult) @trusted sendResultCallback) @trusted
    {
        import engine.distributed.worker.sandbox;
        
        immutable startTime = MonoTime.currTime;
        structuredLog.debug_("executing_action_").field("detail", "Executing action: " ~ request.id.toString()).emit();
        
        try
        {
            // 1. Fetch input artifacts from artifact store
            InputArtifact[] inputs;
            foreach (inputSpec; request.inputs)
            {
                auto fetchResult = artifactStore.fetch(inputSpec);
                if (fetchResult.isErr)
                {
                    structuredLog.error("failed_to_fetch_input_artifact_").field("detail", "Failed to fetch input artifact " ~ inputSpec.id.toString()).emit();
                    structuredLog.error("log_event").field("message", formatError(fetchResult.unwrapErr())).emit();
                    reportFailure(request.id, "Input artifact fetch failed: " ~ inputSpec.path, startTime, sendResultCallback);
                    return;
                }
                inputs ~= fetchResult.unwrap();
                structuredLog.debug_("fetched_input_artifact_").field("detail", "Fetched input artifact: " ~ inputSpec.id.toString() ~ " (" ~ inputs[$-1].data.length.to!string ~ " bytes)").emit();
            }
            
            // 2. Prepare sandbox
            auto envResult = createSandbox(enableSandboxing).prepare(request, inputs);
            if (envResult.isErr)
            {
                structuredLog.error("sandbox_preparation_failed").emit();
                structuredLog.error("log_event").field("message", formatError(envResult.unwrapErr())).emit();
                reportFailure(request.id, "Sandbox preparation failed", startTime, sendResultCallback);
                return;
            }
            
            auto sandboxEnv = envResult.unwrap();
            scope(exit) sandboxEnv.cleanup();
            
            // 3. Execute command
            auto execResult = sandboxEnv.execute(request.command, request.env, request.timeout);
            if (execResult.isErr)
            {
                structuredLog.error("execution_failed").emit();
                structuredLog.error("log_event").field("message", formatError(execResult.unwrapErr())).emit();
                reportFailure(request.id, "Execution failed", startTime, sendResultCallback);
                return;
            }
            
            auto output = execResult.unwrap();
            immutable duration = MonoTime.currTime - startTime;
            
            // Check for resource violations
            auto monitor = sandboxEnv.monitor();
            if (monitor.isViolated())
            {
                foreach (violation; monitor.violations())
                {
                    structuredLog.warning("resource_violation_").field("detail", "Resource violation: " ~ violation.message).emit();
                    structuredLog.debug_("__type_").field("detail", "  Type: " ~ violation.type.to!string ~ ", Actual: " ~ violation.actual.to!string ~ ", Limit: " ~ violation.limit.to!string).emit();
                }
                reportFailure(request.id, "Resource limit violations", startTime, sendResultCallback);
                return;
            }
            
            // 4. Upload outputs to artifact store
            ArtifactId[] outputIds;
            foreach (outputSpec; request.outputs)
            {
                immutable outputPath = buildPath(sandboxEnv.getWorkDir(), outputSpec.path);
                if (!exists(outputPath))
                {
                    if (!outputSpec.optional)
                    {
                        structuredLog.error("required_output_not_found_").field("detail", "Required output not found: " ~ outputPath).emit();
                        reportFailure(request.id, "Missing required output: " ~ outputSpec.path, startTime, sendResultCallback);
                        return;
                    }
                    structuredLog.debug_("optional_output_not_found_").field("detail", "Optional output not found: " ~ outputPath).emit();
                    continue;
                }
                
                ubyte[] outputData;
                try { outputData = cast(ubyte[])read(outputPath); }
                catch (Exception e)
                {
                    structuredLog.error("failed_to_read_output_file_").field("detail", "Failed to read output file " ~ outputPath ~ ": " ~ e.msg).emit();
                    reportFailure(request.id, "Failed to read output: " ~ outputSpec.path, startTime, sendResultCallback);
                    return;
                }
                
                auto hasher = Blake3(0);
                hasher.put(outputData);
                ubyte[32] hash = hasher.finish(32)[0 .. 32];
                auto artifactId = ArtifactId(hash);
                
                auto uploadResult = artifactStore.upload(artifactId, outputData);
                if (uploadResult.isErr)
                {
                    structuredLog.error("failed_to_upload_output_artifact_").field("detail", "Failed to upload output artifact " ~ artifactId.toString()).emit();
                    structuredLog.error("log_event").field("message", formatError(uploadResult.unwrapErr())).emit();
                    reportFailure(request.id, "Output artifact upload failed: " ~ outputSpec.path, startTime, sendResultCallback);
                    return;
                }
                
                outputIds ~= artifactId;
                structuredLog.debug_("uploaded_output_artifact_").field("detail", "Uploaded output artifact: " ~ artifactId.toString() ~ " (" ~ outputData.length.to!string ~ " bytes)").emit();
            }
            
            // 5. Report success
            auto result = ActionResult(request.id, output.exitCode == 0 ? ResultStatus.Success : ResultStatus.Failure,
                duration, outputIds, output.stdout, output.stderr, output.exitCode, sandboxEnv.resourceUsage());
            sendResultCallback(result);
            
            if (result.status == ResultStatus.Success) structuredLog.debug_("action_succeeded_").field("detail", "Action succeeded: " ~ request.id.toString()).emit();
            else structuredLog.warning("action_failed_with_exit_code_").field("detail", "Action failed with exit code " ~ output.exitCode.to!string).emit();
        }
        catch (Exception e)
        {
            structuredLog.error("action_execution_exception_").field("detail", "Action execution exception: " ~ e.msg).emit();
            reportFailure(request.id, e.msg, startTime, sendResultCallback);
        }
    }
    
    /// Report action failure
    private void reportFailure(ActionId actionId, string error, MonoTime startTime,
        void delegate(ActionResult) @trusted sendResultCallback) @trusted
    {
        sendResultCallback(ActionResult(actionId, ResultStatus.Error, MonoTime.currTime - startTime, 
            [], "", error, 0, ResourceUsage.init));
    }
}

