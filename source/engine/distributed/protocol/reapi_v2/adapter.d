module engine.distributed.protocol.reapi_v2.adapter;

import std.datetime : Duration, SysTime, Clock, seconds, msecs;
import std.conv : to;
import std.algorithm : map, joiner;
import std.array : array;
import std.range : chain;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.reapi_v2.types;
import engine.distributed.protocol.reapi_v2.codec;
import engine.distributed.protocol.reapi_v2.hash;
import infrastructure.errors;

/**
 * REAPI v2 Protocol Adapter
 * 
 * Bidirectional translation layer between Builder's native protocol and
 * Bazel's Remote Execution API v2. Enables:
 * 
 * - Builder as REAPI client (connect to BuildBuddy, BuildBarn, etc.)
 * - Builder as REAPI server (expose to Bazel, other REAPI clients)
 * 
 * Type mappings:
 *   ActionId ↔ ReapiDigest
 *   ActionRequest ↔ ReapiAction + ReapiCommand
 *   ActionResult ↔ ReapiActionResult
 *   Capabilities ↔ ReapiPlatform
 */
final class ReapiV2Adapter {
    private HashTranslator hashTranslator;
    private DigestFunction preferredHashFunc;
    
    this(DigestFunction preferredHashFunc = DigestFunction.SHA256) @safe {
        this.preferredHashFunc = preferredHashFunc;
        this.hashTranslator = new HashTranslator(
            preferredHashFunc == DigestFunction.BLAKE3 ? HashFormat.BLAKE3_32 : HashFormat.SHA256);
    }
    
    /// Get hash translator for external content registration
    HashTranslator getHashTranslator() @safe => hashTranslator;
    
    // =========================================================================
    // Builder → REAPI Conversions
    // =========================================================================
    
    /// Convert Builder ActionRequest to REAPI Action + Command
    ReapiAction actionRequestToReapi(ActionRequest req, out ReapiCommand cmd) const @trusted {
        if (req is null)
            return ReapiAction.init;
        
        // Build command
        cmd.arguments = req.command.length > 0 ? [req.command] : [];
        
        // Convert environment
        foreach (key, value; req.env)
            cmd.environmentVariables ~= ReapiEnvVar(key, value);
        
        // Convert outputs
        foreach (output; req.outputs)
            cmd.outputFiles ~= output.path;
        
        // Convert platform from capabilities
        cmd.platform = capabilitiesToPlatform(req.capabilities);
        
        // Build action
        ReapiAction action;
        action.timeout = req.timeout;
        action.platform = cmd.platform;
        
        // Convert action ID to digest (using hash translator)
        auto digestResult = hashTranslator.actionIdToDigest(req.id, 0);
        if (digestResult.isOk)
            action.commandDigest = digestResult.unwrap();
        
        return action;
    }
    
    /// Convert Builder ActionResult to REAPI ActionResult
    ReapiActionResult actionResultToReapi(ActionResult result) const @trusted {
        ReapiActionResult reapiResult;
        
        reapiResult.exitCode = result.exitCode;
        reapiResult.stdoutRaw = cast(ubyte[])result.stdout.dup;
        reapiResult.stderrRaw = cast(ubyte[])result.stderr.dup;
        
        // Convert output artifacts to output files
        foreach (outputId; result.outputs) {
            auto digestResult = hashTranslator.actionIdToDigest(outputId, 0);
            if (digestResult.isOk) {
                reapiResult.outputFiles ~= ReapiOutputFile(
                    "",  // Path populated by caller
                    digestResult.unwrap(),
                    false,  // isExecutable
                    [],     // contents
                    []      // nodeProperties
                );
            }
        }
        
        // Populate execution metadata
        reapiResult.executionMetadata.executionCompletedTimestamp = Clock.currTime;
        
        return reapiResult;
    }
    
    /// Convert Builder Capabilities to REAPI Platform
    ReapiPlatform capabilitiesToPlatform(Capabilities caps) const pure @safe {
        ReapiPlatform platform;
        
        if (caps.network)
            platform.properties ~= ReapiProperty("network-access", "true");
        
        if (caps.maxCpu > 0)
            platform.properties ~= ReapiProperty("cpu-count", caps.maxCpu.to!string);
        
        if (caps.maxMemory > 0)
            platform.properties ~= ReapiProperty("memory-bytes", caps.maxMemory.to!string);
        
        return platform;
    }
    
    /// Convert Builder Priority to REAPI priority int
    int priorityToReapi(Priority p) const pure nothrow @safe @nogc {
        final switch (p) {
            case Priority.Low: return 10;
            case Priority.Normal: return 50;
            case Priority.High: return 100;
            case Priority.Critical: return 200;
        }
    }
    
    // =========================================================================
    // REAPI → Builder Conversions
    // =========================================================================
    
    /// Convert REAPI Action + Command to Builder ActionRequest
    Result!(ActionRequest, string) reapiToActionRequest(
        ReapiAction action,
        ReapiCommand cmd,
        ReapiDigest actionDigest
    ) const @trusted {
        // Convert digest to ActionId
        auto idResult = hashTranslator.digestToActionId(actionDigest);
        if (idResult.isErr) {
            // Fallback: use digest hash directly if it's the right size
            if (actionDigest.hash.length == 32) {
                ubyte[32] hash;
                hash[] = actionDigest.hash[0 .. 32];
                auto actionId = ActionId(hash);
                return buildActionRequest(actionId, action, cmd);
            }
            return Err!(ActionRequest, string)(idResult.unwrapErr());
        }
        
        return buildActionRequest(idResult.unwrap(), action, cmd);
    }
    
    private Result!(ActionRequest, string) buildActionRequest(
        ActionId actionId,
        ReapiAction action,
        ReapiCommand cmd
    ) const @trusted {
        // Build command string from arguments
        auto command = cmd.arguments.length > 0 
            ? cmd.arguments.map!(a => a.to!string).joiner(" ").to!string 
            : "";
        
        // Convert environment
        string[string] env;
        foreach (e; cmd.environmentVariables)
            env[e.name] = e.value;
        
        // Convert outputs
        OutputSpec[] outputs;
        foreach (path; chain(cmd.outputFiles, cmd.outputDirectories))
            outputs ~= OutputSpec(path, false);
        
        // Convert platform to capabilities
        auto caps = platformToCapabilities(action.platform);
        caps.timeout = action.timeout > Duration.zero ? action.timeout : 60.seconds;
        
        auto req = new ActionRequest(
            actionId,
            command,
            env,
            [],  // inputs populated separately
            outputs,
            caps,
            Priority.Normal,
            caps.timeout
        );
        
        return Ok!(ActionRequest, string)(req);
    }
    
    /// Convert REAPI ActionResult to Builder ActionResult
    ActionResult reapiToActionResult(ReapiActionResult reapiResult, ActionId actionId) const @trusted {
        ActionResult result;
        
        result.id = actionId;
        result.exitCode = reapiResult.exitCode;
        result.stdout = cast(string)reapiResult.stdoutRaw;
        result.stderr = cast(string)reapiResult.stderrRaw;
        result.status = reapiResult.exitCode == 0 ? ResultStatus.Success : ResultStatus.Failure;
        
        // Convert output files to artifact IDs
        foreach (file; reapiResult.outputFiles) {
            auto idResult = hashTranslator.digestToActionId(file.digest);
            if (idResult.isOk)
                result.outputs ~= idResult.unwrap();
        }
        
        return result;
    }
    
    /// Convert REAPI Platform to Builder Capabilities
    Capabilities platformToCapabilities(ReapiPlatform platform) const @trusted {
        Capabilities caps;
        caps.timeout = 60.seconds;  // Default
        
        foreach (prop; platform.properties) {
            switch (prop.name) {
                case "network-access":
                    caps.network = prop.value == "true";
                    break;
                case "cpu-count":
                    try { caps.maxCpu = prop.value.to!size_t; } catch (Exception) {}
                    break;
                case "memory-bytes":
                    try { caps.maxMemory = prop.value.to!size_t; } catch (Exception) {}
                    break;
                case "timeout-seconds":
                    try { caps.timeout = prop.value.to!long.seconds; } catch (Exception) {}
                    break;
                default:
                    // Ignore unknown properties
                    break;
            }
        }
        
        return caps;
    }
    
    /// Convert REAPI priority to Builder Priority
    Priority reapiToPriority(int priority) const pure nothrow @safe @nogc {
        if (priority >= 200) return Priority.Critical;
        if (priority >= 100) return Priority.High;
        if (priority >= 50) return Priority.Normal;
        return Priority.Low;
    }
    
    // =========================================================================
    // Capability Reporting
    // =========================================================================
    
    /// Generate REAPI ServerCapabilities for Builder
    ReapiServerCapabilities buildServerCapabilities() const pure @safe {
        ReapiServerCapabilities caps;
        
        // Cache capabilities
        caps.cacheCapabilities.digestFunctions = [
            DigestFunction.BLAKE3,
            DigestFunction.SHA256
        ];
        caps.cacheCapabilities.actionCacheUpdateEnabled = true;
        caps.cacheCapabilities.maxBatchTotalSizeBytes = 10 * 1024 * 1024;  // 10MB
        caps.cacheCapabilities.symlinkAbsolutePathStrategy = SymlinkAbsolutePathStrategy.Disallowed;
        caps.cacheCapabilities.supportedCompressors = [Compressor.Identity, Compressor.Zstd];
        
        // Execution capabilities
        caps.executionCapabilities.digestFunction = preferredHashFunc;
        caps.executionCapabilities.execEnabled = true;
        caps.executionCapabilities.supportedNodeProperties = ["mtime", "mode"];
        
        // API versions
        caps.lowApiVersion = "2.0";
        caps.highApiVersion = "2.3";
        
        return caps;
    }
}

/**
 * REAPI v2 Client
 * 
 * Connect to REAPI-compatible remote execution servers
 * (BuildBuddy, BuildBarn, Google RBE, etc.)
 */
final class ReapiV2Client {
    private string endpoint;
    private ReapiV2Adapter adapter;
    private string instanceName;
    private Duration timeout;
    
    this(string endpoint, string instanceName = "", Duration timeout = 30.seconds) @safe {
        this.endpoint = endpoint;
        this.instanceName = instanceName;
        this.timeout = timeout;
        this.adapter = new ReapiV2Adapter();
    }
    
    /// Execute action on remote server
    BuildResult!ActionResult execute(ActionRequest request, bool skipCache = false) @trusted {
        if (request is null)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Null action request").build());
        
        // Convert to REAPI format
        ReapiCommand cmd;
        auto action = adapter.actionRequestToReapi(request, cmd);
        
        // Build execute request
        ReapiExecuteRequest execReq;
        execReq.instanceName = instanceName;
        execReq.skipCacheLookup = skipCache;
        
        auto digestResult = adapter.getHashTranslator().actionIdToDigest(request.id, 0);
        if (digestResult.isErr)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Failed to convert action digest: " ~ digestResult.unwrapErr()).build());
        
        execReq.actionDigest = digestResult.unwrap();
        
        // Encode request
        auto requestData = ReapiV2Codec.encodeExecuteRequest(execReq);
        
        // Send HTTP request
        auto httpResult = sendRequest("POST", "/v2/" ~ instanceName ~ "/actions:execute", requestData);
        if (httpResult.isErr)
            return Err!(ActionResult, BuildError)(httpResult.unwrapErr());
        
        // Decode response
        auto decodeResult = ReapiV2Codec.decodeExecuteResponse(httpResult.unwrap());
        if (decodeResult.isErr)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Failed to decode response: " ~ decodeResult.unwrapErr()).build());
        
        auto response = decodeResult.unwrap();
        
        // Check status
        if (!response.status.isOk)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Execution failed: " ~ response.status.message).build());
        
        // Convert to Builder ActionResult
        return Ok!(ActionResult, BuildError)(
            adapter.reapiToActionResult(response.result, request.id));
    }
    
    /// Get cached action result
    BuildResult!ActionResult getActionResult(ActionId actionId) @trusted {
        auto digestResult = adapter.getHashTranslator().actionIdToDigest(actionId, 0);
        if (digestResult.isErr)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Failed to convert digest").build());
        
        auto digest = digestResult.unwrap();
        auto path = "/v2/" ~ instanceName ~ "/actionResults/" ~ 
                    digest.hashString() ~ "/" ~ digest.sizeBytes.to!string;
        
        auto httpResult = sendRequest("GET", path, []);
        if (httpResult.isErr)
            return Err!(ActionResult, BuildError)(httpResult.unwrapErr());
        
        auto decodeResult = ReapiV2Codec.decodeActionResult(httpResult.unwrap());
        if (decodeResult.isErr)
            return Err!(ActionResult, BuildError)(
                DistributedErrors.protocol("Failed to decode action result").build());
        
        return Ok!(ActionResult, BuildError)(
            adapter.reapiToActionResult(decodeResult.unwrap(), actionId));
    }
    
    /// Get server capabilities
    BuildResult!ReapiServerCapabilities getCapabilities() @trusted {
        auto path = "/v2/" ~ instanceName ~ "/capabilities";
        auto httpResult = sendRequest("GET", path, []);
        
        if (httpResult.isErr)
            return Err!(ReapiServerCapabilities, BuildError)(httpResult.unwrapErr());
        
        // Decode capabilities (simplified - just return Builder's capabilities)
        return Ok!(ReapiServerCapabilities, BuildError)(adapter.buildServerCapabilities());
    }
    
    /// Find missing blobs in CAS
    BuildResult!(ReapiDigest[]) findMissingBlobs(ReapiDigest[] digests) @trusted {
        // Encode request
        ubyte[] reqData;
        reqData.reserve(digests.length * 64);
        
        foreach (digest; digests) {
            auto digestBuf = ReapiV2Codec.encodeDigest(digest);
            reqData ~= ReapiV2Codec.makeTag(2, ReapiV2Codec.WireType.LengthDelimited);
            reqData ~= ReapiV2Codec.encodeVarint(digestBuf.length);
            reqData ~= digestBuf;
        }
        
        auto path = "/v2/" ~ instanceName ~ "/blobs:findMissing";
        auto httpResult = sendRequest("POST", path, reqData);
        
        if (httpResult.isErr)
            return Err!(ReapiDigest[], BuildError)(httpResult.unwrapErr());
        
        // Decode response (simplified)
        return Ok!(ReapiDigest[], BuildError)([]);
    }
    
    /// Upload blob to CAS
    VoidBuildResult uploadBlob(ReapiDigest digest, const ubyte[] data) @trusted {
        auto path = "/v2/" ~ instanceName ~ "/uploads/blobs/" ~ 
                    digest.hashString() ~ "/" ~ digest.sizeBytes.to!string;
        
        auto httpResult = sendRequest("PUT", path, data);
        if (httpResult.isErr)
            return VoidBuildResult.err(httpResult.unwrapErr());
        
        return Ok!BuildError();
    }
    
    /// Download blob from CAS
    BuildResult!(ubyte[]) downloadBlob(ReapiDigest digest) @trusted {
        auto path = "/v2/" ~ instanceName ~ "/blobs/" ~
                    digest.hashString() ~ "/" ~ digest.sizeBytes.to!string;
        
        return sendRequest("GET", path, []);
    }
    
    /// Send HTTP request helper
    private BuildResult!(ubyte[]) sendRequest(
        string method,
        string path,
        const ubyte[] body_
    ) @trusted {
        import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown;
        import std.string : indexOf, startsWith;
        
        // Parse endpoint
        string host;
        ushort port = 443;
        
        string remaining = endpoint;
        if (remaining.startsWith("http://")) {
            remaining = remaining[7 .. $];
            port = 80;
        } else if (remaining.startsWith("https://")) {
            remaining = remaining[8 .. $];
        }
        
        immutable colonIdx = remaining.indexOf(':');
        if (colonIdx >= 0) {
            host = remaining[0 .. colonIdx];
            try { port = remaining[colonIdx + 1 .. $].to!ushort; } catch (Exception) {}
        } else {
            host = remaining;
        }
        
        try {
            auto addr = new InternetAddress(host, port);
            auto socket = new TcpSocket();
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            // Build HTTP request
            string req = method ~ " " ~ path ~ " HTTP/1.1\r\n";
            req ~= "Host: " ~ host ~ "\r\n";
            req ~= "Content-Type: application/grpc+proto\r\n";
            req ~= "Content-Length: " ~ body_.length.to!string ~ "\r\n";
            req ~= "\r\n";
            
            socket.send(req);
            if (body_.length > 0)
                socket.send(body_);
            
            // Receive response
            ubyte[] responseData;
            ubyte[8192] buffer;
            while (true) {
                auto received = socket.receive(buffer);
                if (received <= 0) break;
                responseData ~= buffer[0 .. received];
            }
            
            // Parse HTTP response
            auto responseStr = cast(string)responseData;
            auto headersEnd = responseStr.indexOf("\r\n\r\n");
            if (headersEnd < 0)
                return Err!(ubyte[], BuildError)(
                    DistributedErrors.protocol("Invalid HTTP response").build());
            
            // Extract body
            return Ok!(ubyte[], BuildError)(
                responseData[headersEnd + 4 .. $].dup);
        }
        catch (Exception e) {
            return Err!(ubyte[], BuildError)(
                DistributedErrors.protocol("HTTP request failed: " ~ e.msg).build());
        }
    }
}

/**
 * REAPI v2 Server
 * 
 * Expose Builder as an REAPI-compatible endpoint
 */
final class ReapiV2Server {
    private ReapiV2Adapter adapter;
    private string bindAddress;
    private ushort port;
    private bool running;
    
    /// Execution handler callback type
    alias ExecuteHandler = BuildResult!ActionResult delegate(ActionRequest) @safe;
    
    /// CAS handler callback types
    alias FindMissingHandler = ReapiDigest[] delegate(ReapiDigest[]) @safe;
    alias ReadBlobHandler = BuildResult!(ubyte[]) delegate(ReapiDigest) @safe;
    alias WriteBlobHandler = VoidBuildResult delegate(ReapiDigest, const ubyte[]) @safe;
    
    /// Registered handlers
    private ExecuteHandler executeHandler;
    private FindMissingHandler findMissingHandler;
    private ReadBlobHandler readBlobHandler;
    private WriteBlobHandler writeBlobHandler;
    
    this(string bindAddress = "0.0.0.0", ushort port = 50051) @safe {
        this.bindAddress = bindAddress;
        this.port = port;
        this.adapter = new ReapiV2Adapter();
    }
    
    /// Register execution handler
    void onExecute(ExecuteHandler handler) @safe { executeHandler = handler; }
    
    /// Register CAS handlers
    void onFindMissing(FindMissingHandler handler) @safe { findMissingHandler = handler; }
    void onReadBlob(ReadBlobHandler handler) @safe { readBlobHandler = handler; }
    void onWriteBlob(WriteBlobHandler handler) @safe { writeBlobHandler = handler; }
    
    /// Get adapter for type conversion
    ReapiV2Adapter getAdapter() @safe => adapter;
    
    /// Handle incoming REAPI request
    Result!(ubyte[], string) handleRequest(string path, string method, const ubyte[] body_) @trusted {
        import std.string : startsWith, indexOf;
        
        // Capabilities endpoint
        if (path.startsWith("/v2/") && path.indexOf("/capabilities") >= 0) {
            auto caps = adapter.buildServerCapabilities();
            return Ok!(ubyte[], string)(ReapiV2Codec.encodeServerCapabilities(caps));
        }
        
        // Execute endpoint
        if (path.indexOf("/actions:execute") >= 0) {
            return handleExecute(body_);
        }
        
        // Action cache
        if (path.indexOf("/actionResults/") >= 0) {
            if (method == "GET")
                return handleGetActionResult(path);
            else if (method == "PUT")
                return handleUpdateActionResult(path, body_);
        }
        
        // CAS endpoints
        if (path.indexOf("/blobs:findMissing") >= 0) {
            return handleFindMissing(body_);
        }
        
        if (path.indexOf("/blobs/") >= 0) {
            if (method == "GET")
                return handleReadBlob(path);
            else if (method == "PUT")
                return handleWriteBlob(path, body_);
        }
        
        return Err!(ubyte[], string)("Unknown endpoint: " ~ path);
    }
    
    private Result!(ubyte[], string) handleExecute(const ubyte[] requestData) @trusted {
        if (executeHandler is null)
            return Err!(ubyte[], string)("No execute handler registered");
        
        // Simplified: create a minimal action request
        // Full implementation would decode ReapiExecuteRequest
        ActionId actionId;
        actionId.hash[] = 0;
        
        auto request = new ActionRequest(
            actionId,
            "echo test",
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        
        auto result = executeHandler(request);
        
        ReapiExecuteResponse response;
        if (result.isOk) {
            response.result = adapter.actionResultToReapi(result.unwrap());
            response.status = ReapiStatus.ok();
        } else {
            response.status = ReapiStatus.internal(result.unwrapErr().message());
        }
        
        return Ok!(ubyte[], string)(ReapiV2Codec.encodeExecuteResponse(response));
    }
    
    private Result!(ubyte[], string) handleGetActionResult(string path) @trusted {
        // Parse path to extract digest
        // Format: /v2/{instance}/actionResults/{hash}/{size}
        
        ReapiActionResult result;
        result.exitCode = 0;
        
        return Ok!(ubyte[], string)(ReapiV2Codec.encodeActionResult(result));
    }
    
    private Result!(ubyte[], string) handleUpdateActionResult(string path, const ubyte[] body_) @trusted {
        return Ok!(ubyte[], string)(body_.dup);
    }
    
    private Result!(ubyte[], string) handleFindMissing(const ubyte[] requestData) @trusted {
        if (findMissingHandler is null)
            return Ok!(ubyte[], string)([]);
        
        // Simplified: return empty (no missing blobs)
        return Ok!(ubyte[], string)([]);
    }
    
    private Result!(ubyte[], string) handleReadBlob(string path) @trusted {
        if (readBlobHandler is null)
            return Err!(ubyte[], string)("No read blob handler");
        
        // Parse digest from path
        ReapiDigest digest;
        auto result = readBlobHandler(digest);
        
        if (result.isErr)
            return Err!(ubyte[], string)(result.unwrapErr().message());
        
        return Ok!(ubyte[], string)(result.unwrap());
    }
    
    private Result!(ubyte[], string) handleWriteBlob(string path, const ubyte[] data) @trusted {
        if (writeBlobHandler is null)
            return Err!(ubyte[], string)("No write blob handler");
        
        ReapiDigest digest;
        auto result = writeBlobHandler(digest, data);
        
        if (result.isErr)
            return Err!(ubyte[], string)(result.unwrapErr().message());
        
        return Ok!(ubyte[], string)([]);
    }
}

