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
        slog.debug_("action_execution_start")
            .field("action_id", request.id.toString())
            .field("inputs", request.inputs.length)
            .field("outputs", request.outputs.length)
            .field("sandboxed", enableSandboxing)
            .emit();
        
        try
        {
            // 1. Fetch input artifacts from artifact store
            InputArtifact[] inputs;
            foreach (inputSpec; request.inputs)
            {
                auto fetchResult = artifactStore.fetch(inputSpec);
                if (fetchResult.isErr)
                {
                    slog.error("action_input_fetch_failed")
                        .field("action_id", request.id.toString())
                        .field("artifact_id", inputSpec.id.toString())
                        .field("path", inputSpec.path)
                        .field("error", formatError(fetchResult.unwrapErr()))
                        .field("hint", "Check if artifact exists in cache or remote store")
                        .emit();
                    reportFailure(request.id, "Input artifact fetch failed: " ~ inputSpec.path, startTime, sendResultCallback);
                    return;
                }
                inputs ~= fetchResult.unwrap();
                slog.trace("action_input_fetched")
                    .field("artifact_id", inputSpec.id.toString())
                    .field("size_bytes", inputs[$-1].data.length)
                    .emit();
            }
            
            // 2. Prepare sandbox
            auto envResult = createSandbox(enableSandboxing).prepare(request, inputs);
            if (envResult.isErr)
            {
                slog.error("action_sandbox_failed")
                    .field("action_id", request.id.toString())
                    .field("error", formatError(envResult.unwrapErr()))
                    .field("hint", "Check sandbox permissions and available disk space")
                    .emit();
                reportFailure(request.id, "Sandbox preparation failed", startTime, sendResultCallback);
                return;
            }
            
            auto sandboxEnv = envResult.unwrap();
            scope(exit) sandboxEnv.cleanup();
            
            // 3. Execute command
            auto execResult = sandboxEnv.execute(request.command, request.env, request.timeout);
            if (execResult.isErr)
            {
                slog.error("action_command_failed")
                    .field("action_id", request.id.toString())
                    .field("command", request.command.length > 0 ? request.command[0] : "")
                    .field("error", formatError(execResult.unwrapErr()))
                    .field("hint", "Check command syntax and that required tools are installed")
                    .emit();
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
                    slog.warning("action_resource_violation")
                        .field("action_id", request.id.toString())
                        .field("violation", violation.message)
                        .field("type", violation.type.to!string)
                        .field("actual", violation.actual)
                        .field("limit", violation.limit)
                        .field("hint", "Consider increasing resource limits in Builderfile or optimizing the build")
                        .emit();
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
                        slog.error("action_output_missing")
                            .field("action_id", request.id.toString())
                            .field("path", outputPath)
                            .field("hint", "Build command succeeded but expected output file was not created")
                            .emit();
                        reportFailure(request.id, "Missing required output: " ~ outputSpec.path, startTime, sendResultCallback);
                        return;
                    }
                    slog.debug_("action_output_optional_skipped")
                        .field("path", outputPath)
                        .emit();
                    continue;
                }
                
                ubyte[] outputData;
                try { outputData = cast(ubyte[])read(outputPath); }
                catch (Exception e)
                {
                    slog.error("action_output_read_failed")
                        .field("action_id", request.id.toString())
                        .field("path", outputPath)
                        .field("error", e.msg)
                        .field("hint", "Check file permissions and disk space")
                        .emit();
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

