module engine.workers.protocol.transport;

import std.process;
import std.stdio : File;
import std.string;
import std.conv;
import std.datetime;
import core.time : MonoTime, Duration, msecs, seconds;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import engine.workers.protocol.types;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Alias for std.process.Config to avoid name collision with error Config
private alias ProcessConfig = std.process.Config;

/// Transport interface for worker communication
interface IWorkerTransport
{
    /// Send a work request to the worker
    Result!WorkerError sendRequest(WorkRequest request);
    
    /// Receive a work response from the worker
    Result!(WorkResponse, WorkerError) receiveResponse(Duration timeout);
    
    /// Check if transport is connected
    bool isConnected() const;
    
    /// Close the transport
    void close();
}

/// Worker-specific error type
class WorkerError : BaseBuildError
{
    WorkerErrorCode workerCode;
    
    this(string msg, WorkerErrorCode code = WorkerErrorCode.Unknown) @trusted
    {
        super(Build.Failed, msg);
        this.workerCode = code;
    }
}

enum WorkerErrorCode
{
    Unknown,
    ProcessDied,
    Timeout,
    ProtocolError,
    StartupFailed,
    IOError
}

/// Stdio-based transport (Bazel-compatible newline-delimited JSON)
final class StdioWorkerTransport : IWorkerTransport
{
    private ProcessPipes pipes;
    private bool connected;
    private Mutex mutex;
    private uint nextRequestId;
    
    this(ProcessPipes pipes) @trusted
    {
        this.pipes = pipes;
        this.connected = true;
        this.mutex = new Mutex();
        this.nextRequestId = 1;
    }
    
    Result!WorkerError sendRequest(WorkRequest request) @trusted
    {
        synchronized (mutex)
        {
            if (!connected)
                return Result!WorkerError.err(new WorkerError("Transport not connected", WorkerErrorCode.IOError));
            
            try
            {
                auto json = request.toJson();
                pipes.stdin.writeln(json);
                pipes.stdin.flush();
                structuredLog.debug_("sent_request_").field("detail", "Sent request " ~ request.requestId.to!string ~ " to worker").emit();
                return Result!WorkerError.ok();
            }
            catch (Exception e)
            {
                connected = false;
                return Result!WorkerError.err(new WorkerError("Send failed: " ~ e.msg, WorkerErrorCode.IOError));
            }
        }
    }
    
    Result!(WorkResponse, WorkerError) receiveResponse(Duration timeout) @trusted
    {
        auto deadline = MonoTime.currTime + timeout;
        
        synchronized (mutex)
        {
            if (!connected)
                return Err!(WorkResponse, WorkerError)(new WorkerError("Transport not connected", WorkerErrorCode.IOError));
            
            try
            {
                // Poll for response with timeout
                while (MonoTime.currTime < deadline)
                {
                    // Check if process terminated
                    auto status = tryWait(pipes.pid);
                    if (status.terminated)
                    {
                        connected = false;
                        return Err!(WorkResponse, WorkerError)(
                            new WorkerError("Worker process died", WorkerErrorCode.ProcessDied));
                    }
                    
                    // Try to read a line (non-blocking would be ideal, but D's stdio is blocking)
                    if (!pipes.stdout.eof)
                    {
                        auto line = pipes.stdout.readln();
                        if (line.length > 0)
                        {
                            auto trimmed = line.strip();
                            if (trimmed.length > 0)
                            {
                                auto response = WorkResponse.fromJson(trimmed);
                                structuredLog.debug_("received_response_").field("detail", "Received response " ~ response.requestId.to!string ~ " from worker").emit();
                                return Ok!(WorkResponse, WorkerError)(response);
                            }
                        }
                    }
                    
                    // Small sleep to avoid busy-waiting
                    Thread.sleep(msecs(10));
                }
                
                return Err!(WorkResponse, WorkerError)(new WorkerError("Response timeout", WorkerErrorCode.Timeout));
            }
            catch (Exception e)
            {
                return Err!(WorkResponse, WorkerError)(
                    new WorkerError("Receive failed: " ~ e.msg, WorkerErrorCode.ProtocolError));
            }
        }
    }
    
    bool isConnected() const @safe
    {
        return connected;
    }
    
    void close() @trusted
    {
        synchronized (mutex)
        {
            if (connected)
            {
                connected = false;
                try
                {
                    pipes.stdin.close();
                    auto status = tryWait(pipes.pid);
                    if (!status.terminated)
                    {
                        // Give it a moment to exit gracefully
                        Thread.sleep(msecs(100));
                        status = tryWait(pipes.pid);
                        if (!status.terminated)
                        {
                            import core.sys.posix.signal : SIGTERM;
                            kill(pipes.pid, SIGTERM);
                        }
                    }
                }
                catch (Exception e)
                {
                    structuredLog.error("error_closing_worker_transport_").field("detail", "Error closing worker transport: " ~ e.msg).emit();
                }
            }
        }
    }
    
    /// Get stderr output for diagnostics
    string readStderr() @trusted
    {
        string output;
        try
        {
            while (!pipes.stderr.eof)
            {
                auto line = pipes.stderr.readln();
                if (line.length > 0)
                    output ~= line;
            }
        }
        catch (Exception)
        {
            // Ignore read errors
        }
        return output;
    }
}

/// Create a transport by spawning a worker process
Result!(StdioWorkerTransport, WorkerError) spawnWorkerTransport(
    string executable,
    string[] args,
    string workDir = null,
    string[string] env = null
) @trusted
{
    try
    {
        auto pipes = pipeProcess(
            [executable] ~ args,
            Redirect.stdin | Redirect.stdout | Redirect.stderr,
            env,
            ProcessConfig.none,
            workDir
        );
        
        return Ok!(StdioWorkerTransport, WorkerError)(new StdioWorkerTransport(pipes));
    }
    catch (Exception e)
    {
        return Err!(StdioWorkerTransport, WorkerError)(
            new WorkerError("Failed to spawn worker: " ~ e.msg, WorkerErrorCode.StartupFailed));
    }
}

