module engine.runtime.remote.protocol.reapi;

import std.datetime : Duration, seconds;
import std.conv : to;
import std.digest : toHexString;
import std.string : toLower, format;
import std.algorithm : map;
import std.array : array;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.grpc.connection;
import engine.distributed.protocol.grpc.frame : ReapiServices;
import infrastructure.errors;

/// Remote Execution API protocol adapter
/// Provides Bazel REAPI compatibility while using Builder's native protocol
///
/// Design: Protocol translation layer that maps REAPI semantics to Builder's
/// efficient native protocol. Avoids gRPC dependency bloat while maintaining
/// wire-level compatibility with standard REAPI clients.

/// REAPI digest (content-addressed identifier)
struct Digest
{
    ubyte[32] hash;      // BLAKE3 hash (32 bytes)
    size_t sizeBytes;    // Size in bytes
    
    this(const ubyte[32] hash, size_t sizeBytes) pure nothrow @safe @nogc
    {
        this.hash = hash;
        this.sizeBytes = sizeBytes;
    }
    
    /// Create from ActionId
    this(ActionId actionId, size_t sizeBytes) pure nothrow @safe @nogc
    {
        this.hash = actionId.hash;
        this.sizeBytes = sizeBytes;
    }
    
    /// Convert to ActionId
    ActionId toActionId() const pure nothrow @safe @nogc
    {
        return ActionId(hash);
    }
    
    /// String representation (hex)
    string toString() const @trusted
    {
        return toHexString(hash[]).toLower();
    }
    
    /// Parse from string
    static Result!(Digest, string) parse(string hexStr, size_t sizeBytes) @trusted
    {
        if (hexStr.length != 64)
            return Err!(Digest, string)("Invalid digest length");
        
        try
        {
            import std.conv : to;
            import std.string : fromStringz;
            ubyte[32] hash;
            
            for (size_t i = 0; i < 32; i++)
            {
                auto hexPair = hexStr[i * 2 .. i * 2 + 2];
                hash[i] = cast(ubyte)hexPair.to!ubyte(16);
            }
            
            return Ok!(Digest, string)(Digest(hash, sizeBytes));
        }
        catch (Exception e)
        {
            return Err!(Digest, string)("Failed to parse digest: " ~ e.msg);
        }
    }
}

/// REAPI execution platform
struct Platform
{
    Property[] properties;
    
    /// Property key-value pair
    static struct Property
    {
        string name;
        string value;
    }
    
    /// Convert to Builder Capabilities
    Capabilities toCapabilities() const pure @safe
    {
        Capabilities caps;
        
        foreach (prop; properties)
        {
            switch (prop.name)
            {
                case "OSFamily":
                    // Handle OS family (linux, macos, windows)
                    break;
                case "container-image":
                    // Docker image specification
                    break;
                case "Pool":
                    // Worker pool specification
                    break;
                default:
                    // Custom properties
                    break;
            }
        }
        
        return caps;
    }
}

/// REAPI command
struct Command
{
    string[] arguments;                     // Command arguments
    EnvironmentVariable[] environmentVariables;
    string[] outputFiles;                   // Expected output files
    string[] outputDirectories;             // Expected output directories
    string[] outputPaths;                   // Output path prefixes
    Platform platform;                      // Execution platform
    string workingDirectory;                // Working directory
    bool outputNodeProperties;              // Include node properties
    
    /// Environment variable
    static struct EnvironmentVariable
    {
        string name;
        string value;
    }
    
    /// Convert to Builder ActionRequest
    ActionRequest toActionRequest(Digest actionDigest) const @safe
    {
        import std.algorithm : joiner, map;
        import std.range : chain;
        import std.conv : to;
        
        // Build command string - convert to mutable array first
        immutable cmdStr = arguments.length > 0 ? 
            arguments.map!(a => a.to!string).joiner(" ").to!string : "";
        
        // Build environment map
        string[string] env;
        foreach (envVar; environmentVariables)
        {
            env[envVar.name] = envVar.value;
        }
        
        // Build output specs
        OutputSpec[] outputs;
        foreach (path; chain(outputFiles, outputDirectories))
        {
            outputs ~= OutputSpec(path, false);
        }
        
        auto caps = platform.toCapabilities();
        
        return new ActionRequest(
            actionDigest.toActionId(),
            cmdStr,
            env,
            [],  // Inputs populated separately
            outputs,
            caps,
            Priority.Normal,
            caps.timeout
        );
    }
}

/// REAPI action
struct Action
{
    Digest commandDigest;                   // Command digest
    Digest inputRootDigest;                 // Input root digest
    Duration timeout;                       // Execution timeout
    bool doNotCache;                        // Skip caching?
    string salt;                            // Differentiation salt
    Platform platform;                      // Execution platform
    
    /// Compute action digest
    Digest digest() const @trusted
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        
        auto hasher = Blake3(0);
        hasher.put(cast(const(ubyte)[])commandDigest.hash);
        hasher.put(cast(const(ubyte)[])inputRootDigest.hash);
        
        auto timeoutMs = timeout.total!"msecs";
        hasher.put((cast(ubyte*)&timeoutMs)[0 .. timeoutMs.sizeof]);
        
        if (salt.length > 0)
            hasher.put(cast(const ubyte[])salt);
        
        auto hashBytes = hasher.finish(32);
        ubyte[32] hash;
        hash[0 .. 32] = hashBytes[0 .. 32];
        
        // Size is serialized representation size (approximate)
        immutable size = 64 + 8 + salt.length;
        
        return Digest(hash, size);
    }
}

/// REAPI execution result
struct ExecuteResponse
{
    ActionResult result;                    // Execution result
    bool cachedResult;                      // From cache?
    Status status;                          // Execution status
    string serverLogs;                      // Server logs
    string message;                         // Status message
    
    /// gRPC-style status
    static struct Status
    {
        int code;                           // Status code (0 = OK)
        string message;                     // Error message
        
        static Status ok() pure nothrow @safe @nogc
        {
            return Status(0, "");
        }
        
        static Status error(string message) pure @safe
        {
            return Status(2, message);  // UNKNOWN
        }
    }
}

/// REAPI action result
struct ActionResult
{
    /// Output node properties
    static struct OutputNode
    {
        static struct Property
        {
            string name;
            string value;
        }
        
        Property[] properties;
    }
    
    /// Output file
    static struct OutputFile
    {
        string path;
        Digest digest;
        bool isExecutable;
        string contents;                    // Inline contents (if small)
        OutputNode nodeProperties;
    }
    
    /// Output directory
    static struct OutputDirectory
    {
        string path;
        Digest treeDigest;                  // Directory tree digest
        OutputNode nodeProperties;
    }
    
    /// Execution metadata
    static struct ExecutionMetadata
    {
        string worker;                      // Worker identifier
        Duration queuedTime;                // Time in queue
        Duration workerStartTime;           // Worker start
        Duration workerCompleteTime;        // Worker complete
        Duration inputFetchStartTime;       // Input fetch start
        Duration inputFetchCompleteTime;    // Input fetch complete
        Duration executionStartTime;        // Execution start
        Duration executionCompleteTime;     // Execution complete
        Duration outputUploadStartTime;     // Output upload start
        Duration outputUploadCompleteTime;  // Output upload complete
    }
    
    OutputFile[] outputFiles;               // Output files
    OutputDirectory[] outputDirectories;    // Output directories
    int exitCode;                           // Exit code
    string stdoutRaw;                       // Stdout (if small)
    string stderrRaw;                       // Stderr (if small)
    Digest stdoutDigest;                    // Stdout digest (if large)
    Digest stderrDigest;                    // Stderr digest (if large)
    ExecutionMetadata executionMetadata;    // Execution metadata
    
    /// Convert from Builder ActionResult
    static ActionResult fromBuilderResult(
        engine.distributed.protocol.protocol.ActionResult builderResult,
        OutputFile[] outputFiles
    ) @safe
    {
        ActionResult result;
        result.outputFiles = outputFiles;
        result.exitCode = builderResult.exitCode;
        result.stdoutRaw = builderResult.stdout;
        result.stderrRaw = builderResult.stderr;
        
        // Populate metadata
        result.executionMetadata.executionStartTime = Duration.zero;
        result.executionMetadata.executionCompleteTime = builderResult.duration;
        
        return result;
    }
}

/// REAPI protocol adapter
/// Translates between REAPI and Builder's native protocol using proper HTTP/2 gRPC
final class ReapiAdapter
{
    private string remoteUrl;
    private GrpcConnection grpcConn;
    private Duration timeout;
    
    this(string remoteUrl, Duration timeout = 30.seconds) @safe
    {
        this.remoteUrl = remoteUrl;
        this.timeout = timeout;
    }
    
    /// Ensure gRPC connection is established
    private BuildResult!GrpcConnection ensureConnection() @trusted
    {
        if (grpcConn !is null && grpcConn.isConnected)
            return Ok!(GrpcConnection, BuildError)(grpcConn);
        
        auto poolResult = GrpcConnectionPool.instance.getConnection(remoteUrl);
        if (poolResult.isErr)
            return Err!(GrpcConnection, BuildError)(
                Errors.generic("gRPC connection failed: " ~ poolResult.unwrapErr(), ErrorCode.NetworkError));
        
        grpcConn = poolResult.unwrap();
        return Ok!(GrpcConnection, BuildError)(grpcConn);
    }
    
    /// Execute action via REAPI using gRPC server streaming
    BuildResult!ExecuteResponse execute(
        Action action,
        bool skipCacheLookup = false
    ) @trusted
    {
        auto connResult = ensureConnection();
        if (connResult.isErr)
            return Err!(ExecuteResponse, BuildError)(connResult.unwrapErr());
        
        auto conn = connResult.unwrap();
        
        // Serialize execute request
        auto requestData = ReapiCodec.serializeExecuteRequest(action, skipCacheLookup);
        
        // Send gRPC server streaming call (Execute returns stream of Operation)
        auto streamResult = conn.serverStreamingCall(ReapiServices.execute().path, requestData, timeout);
        if (streamResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("Execute gRPC call failed: " ~ streamResult.unwrapErr(), ErrorCode.NetworkError));
        
        // Get final response from stream
        auto responses = streamResult.unwrap();
        if (responses.length == 0)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("No response from Execute stream", ErrorCode.NetworkError));
        
        // Deserialize final response
        auto parseResult = ReapiCodec.deserializeExecuteResponse(responses[$ - 1]);
        if (parseResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("Failed to parse execute response: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ExecuteResponse, BuildError)(parseResult.unwrap());
    }
    
    /// Wait for execution using gRPC WaitExecution streaming
    BuildResult!ExecuteResponse waitExecution(
        string operationName,
        Duration waitTimeout = 0.seconds
    ) @trusted
    {
        auto connResult = ensureConnection();
        if (connResult.isErr)
            return Err!(ExecuteResponse, BuildError)(connResult.unwrapErr());
        
        auto conn = connResult.unwrap();
        
        // Serialize WaitExecution request
        auto requestData = ReapiCodec.serializeWaitExecutionRequest(operationName);
        
        auto effectiveTimeout = waitTimeout > Duration.zero ? waitTimeout : timeout;
        
        // WaitExecution is server streaming - blocks until operation completes
        auto streamResult = conn.serverStreamingCall(
            ReapiServices.waitExecution().path, requestData, effectiveTimeout);
        
        if (streamResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("WaitExecution gRPC call failed: " ~ streamResult.unwrapErr(), ErrorCode.NetworkError));
        
        auto responses = streamResult.unwrap();
        if (responses.length == 0)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("No response from WaitExecution stream", ErrorCode.NetworkError));
        
        // Parse final Operation response
        auto parseResult = ReapiCodec.deserializeExecuteResponse(responses[$ - 1]);
        if (parseResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("Failed to parse operation status: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ExecuteResponse, BuildError)(parseResult.unwrap());
    }
    
    /// Get action result from cache using gRPC
    BuildResult!ActionResult getActionResult(
        Digest actionDigest
    ) @trusted
    {
        auto connResult = ensureConnection();
        if (connResult.isErr)
            return Err!(ActionResult, BuildError)(connResult.unwrapErr());
        
        auto conn = connResult.unwrap();
        
        // Serialize GetActionResult request
        auto requestData = ReapiCodec.serializeGetActionResultRequest(actionDigest);
        
        auto grpcResult = conn.unaryCall(ReapiServices.getActionResult().path, requestData, timeout);
        if (grpcResult.isErr)
        {
            // gRPC NOT_FOUND is expected for cache misses
            if (grpcResult.unwrapErr().indexOf("NOT_FOUND") >= 0 ||
                grpcResult.unwrapErr().indexOf("5") >= 0)
            {
                ActionResult emptyResult;
                return Ok!(ActionResult, BuildError)(emptyResult);
            }
            return Err!(ActionResult, BuildError)(
                Errors.generic("GetActionResult gRPC call failed: " ~ grpcResult.unwrapErr(), ErrorCode.NetworkError));
        }
        
        // Deserialize action result
        auto parseResult = deserializeActionResult(grpcResult.unwrap());
        if (parseResult.isErr)
            return Err!(ActionResult, BuildError)(
                Errors.generic("Failed to parse action result: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ActionResult, BuildError)(parseResult.unwrap());
    }
    
    /// Update action result in cache using gRPC
    VoidBuildResult updateActionResult(
        Digest actionDigest,
        ActionResult result
    ) @trusted
    {
        auto connResult = ensureConnection();
        if (connResult.isErr)
            return VoidBuildResult.err(connResult.unwrapErr());
        
        auto conn = connResult.unwrap();
        
        // Serialize UpdateActionResult request
        auto resultData = serializeActionResult(result);
        auto requestData = ReapiCodec.serializeUpdateActionResultRequest(actionDigest, resultData);
        
        auto grpcResult = conn.unaryCall(ReapiServices.updateActionResult().path, requestData, timeout);
        if (grpcResult.isErr)
            return VoidBuildResult.err(
                Errors.generic("UpdateActionResult gRPC call failed: " ~ grpcResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!BuildError();
    }
    
    /// Deserialize action result
    private Result!(ActionResult, string) deserializeActionResult(const ubyte[] data) @system
    {
        import std.bitmanip : read;
        
        if (data.length < 4)
            return Err!(ActionResult, string)("ActionResult data too short");
        
        ActionResult result;
        ubyte[] mutableData = data.dup;
        size_t offset = 0;
        
        try
        {
            // Parse exit code
            if (offset + 4 > data.length)
                return Err!(ActionResult, string)("Unexpected end of data");
            auto exitSlice = mutableData[offset .. offset + 4];
            result.exitCode = exitSlice.read!int();
            offset += 4;
            
            // Parse stdout length and content
            if (offset + 4 > data.length)
                return Err!(ActionResult, string)("Unexpected end of data");
            auto stdoutLenSlice = mutableData[offset .. offset + 4];
            immutable stdoutLen = stdoutLenSlice.read!uint();
            offset += 4;
            
            if (offset + stdoutLen > data.length)
                return Err!(ActionResult, string)("Stdout data truncated");
            if (stdoutLen > 0)
            {
                result.stdoutRaw = cast(string)mutableData[offset .. offset + stdoutLen];
                offset += stdoutLen;
            }
            
            // Parse stderr length and content
            if (offset + 4 > data.length)
                return Err!(ActionResult, string)("Unexpected end of data");
            auto stderrLenSlice = mutableData[offset .. offset + 4];
            immutable stderrLen = stderrLenSlice.read!uint();
            offset += 4;
            
            if (offset + stderrLen > data.length)
                return Err!(ActionResult, string)("Stderr data truncated");
            if (stderrLen > 0)
            {
                result.stderrRaw = cast(string)mutableData[offset .. offset + stderrLen];
                offset += stderrLen;
            }
            
            // Parse output files count
            if (offset + 4 > data.length)
                return Err!(ActionResult, string)("Unexpected end of data");
            auto filesCountSlice = mutableData[offset .. offset + 4];
            immutable filesCount = filesCountSlice.read!uint();
            offset += 4;
            
            // Parse output files
            for (uint i = 0; i < filesCount; i++)
            {
                ActionResult.OutputFile outFile;
                
                // Parse path length and content
                if (offset + 4 > data.length)
                    return Err!(ActionResult, string)("Output file path truncated");
                auto pathLenSlice = mutableData[offset .. offset + 4];
                immutable pathLen = pathLenSlice.read!uint();
                offset += 4;
                
                if (offset + pathLen > data.length)
                    return Err!(ActionResult, string)("Output file path data truncated");
                outFile.path = cast(string)mutableData[offset .. offset + pathLen];
                offset += pathLen;
                
                // Parse digest hash (32 bytes)
                if (offset + 32 > data.length)
                    return Err!(ActionResult, string)("Output file digest truncated");
                ubyte[32] hash = mutableData[offset .. offset + 32];
                offset += 32;
                
                // Parse digest size
                if (offset + 8 > data.length)
                    return Err!(ActionResult, string)("Output file size truncated");
                auto sizeSlice = mutableData[offset .. offset + 8];
                immutable size = sizeSlice.read!ulong();
                offset += 8;
                
                outFile.digest = Digest(hash, size);
                
                // Parse executable flag
                if (offset >= data.length)
                    return Err!(ActionResult, string)("Executable flag truncated");
                auto execSlice = mutableData[offset .. offset + 1];
                outFile.isExecutable = execSlice.read!ubyte() != 0;
                offset += 1;
                
                result.outputFiles ~= outFile;
            }
            
            // Parse execution metadata if present (optional)
            if (offset + 8 <= data.length)
            {
                auto execTimeSlice = mutableData[offset .. offset + 8];
                immutable execTimeMs = execTimeSlice.read!long();
                offset += 8;
                result.executionMetadata.executionCompleteTime = Duration.init;
            }
            
            return Ok!(ActionResult, string)(result);
        }
        catch (Exception e)
        {
            return Err!(ActionResult, string)("Parse error: " ~ e.msg);
        }
    }
    
    /// Serialize action result
    private ubyte[] serializeActionResult(ActionResult result) @trusted
    {
        import std.bitmanip : write;
        
        ubyte[] buffer;
        buffer.reserve(4096);
        
        // Exit code
        buffer.write!int(result.exitCode, buffer.length);
        
        // Stdout
        buffer.write!uint(cast(uint)result.stdoutRaw.length, buffer.length);
        buffer ~= cast(ubyte[])result.stdoutRaw;
        
        // Stderr
        buffer.write!uint(cast(uint)result.stderrRaw.length, buffer.length);
        buffer ~= cast(ubyte[])result.stderrRaw;
        
        // Output files
        buffer.write!uint(cast(uint)result.outputFiles.length, buffer.length);
        foreach (file; result.outputFiles)
        {
            buffer.write!uint(cast(uint)file.path.length, buffer.length);
            buffer ~= cast(ubyte[])file.path;
            buffer ~= file.digest.hash;
            buffer.write!ulong(file.digest.sizeBytes, buffer.length);
            buffer.write!ubyte(file.isExecutable ? 1 : 0, buffer.length);
        }
        
        return buffer;
    }
}

/// REAPI request/response serialization
/// Wire format compatible with Bazel REAPI using protobuf encoding
struct ReapiCodec
{
    /// Protobuf wire types
    private enum WireType : ubyte {
        Varint = 0, LengthDelimited = 2
    }
    
    private static ubyte makeTag(uint fieldNumber, WireType wireType) pure nothrow @safe @nogc =>
        cast(ubyte)((fieldNumber << 3) | wireType);
    
    private static ubyte[] encodeVarint(long value) @trusted {
        ubyte[] buf;
        auto uvalue = cast(ulong)value;
        while (uvalue >= 0x80) {
            buf ~= cast(ubyte)(uvalue | 0x80);
            uvalue >>= 7;
        }
        buf ~= cast(ubyte)uvalue;
        return buf;
    }
    
    /// Serialize ExecuteRequest (protobuf wire format)
    static ubyte[] serializeExecuteRequest(Action action, bool skipCacheLookup) @trusted
    {
        ubyte[] buffer;
        buffer.reserve(256);
        
        // Field 3: action_digest (Digest message)
        auto digestBuf = encodeDigest(action.digest());
        buffer ~= makeTag(3, WireType.LengthDelimited);
        buffer ~= encodeVarint(digestBuf.length);
        buffer ~= digestBuf;
        
        // Field 2: skip_cache_lookup (bool)
        if (skipCacheLookup) {
            buffer ~= makeTag(2, WireType.Varint);
            buffer ~= 0x01;
        }
        
        return buffer;
    }
    
    /// Encode Digest message
    private static ubyte[] encodeDigest(Digest digest) @trusted {
        ubyte[] buf;
        
        // Field 1: hash (string as hex)
        auto hexStr = digest.toString();
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(hexStr.length);
        buf ~= cast(ubyte[])hexStr;
        
        // Field 2: size_bytes
        buf ~= makeTag(2, WireType.Varint);
        buf ~= encodeVarint(digest.sizeBytes);
        
        return buf;
    }
    
    /// Serialize WaitExecutionRequest
    static ubyte[] serializeWaitExecutionRequest(string operationName) @trusted {
        ubyte[] buffer;
        
        // Field 1: name (string)
        buffer ~= makeTag(1, WireType.LengthDelimited);
        buffer ~= encodeVarint(operationName.length);
        buffer ~= cast(ubyte[])operationName;
        
        return buffer;
    }
    
    /// Serialize GetActionResultRequest
    static ubyte[] serializeGetActionResultRequest(Digest actionDigest) @trusted {
        ubyte[] buffer;
        
        // Field 2: action_digest
        auto digestBuf = encodeDigest(actionDigest);
        buffer ~= makeTag(2, WireType.LengthDelimited);
        buffer ~= encodeVarint(digestBuf.length);
        buffer ~= digestBuf;
        
        return buffer;
    }
    
    /// Serialize UpdateActionResultRequest
    static ubyte[] serializeUpdateActionResultRequest(Digest actionDigest, ubyte[] resultData) @trusted {
        ubyte[] buffer;
        
        // Field 2: action_digest
        auto digestBuf = encodeDigest(actionDigest);
        buffer ~= makeTag(2, WireType.LengthDelimited);
        buffer ~= encodeVarint(digestBuf.length);
        buffer ~= digestBuf;
        
        // Field 3: action_result
        buffer ~= makeTag(3, WireType.LengthDelimited);
        buffer ~= encodeVarint(resultData.length);
        buffer ~= resultData;
        
        return buffer;
    }
    
    /// Deserialize ExecuteResponse
    static Result!(ExecuteResponse, string) deserializeExecuteResponse(const ubyte[] data) @system
    {
        import std.bitmanip : read;
        
        if (data.length < 4)
            return Err!(ExecuteResponse, string)("Response too short");
        
        ExecuteResponse response;
        ubyte[] mutableData = data.dup;
        size_t offset = 0;
        
        try
        {
            // Parse status code
            auto statusSlice = mutableData[offset .. offset + 4];
            response.status.code = statusSlice.read!int();
            offset += 4;
            
            // Parse cached result flag
            if (offset >= data.length)
                return Err!(ExecuteResponse, string)("Unexpected end of data");
            auto cachedSlice = mutableData[offset .. offset + 1];
            response.cachedResult = cachedSlice.read!ubyte() != 0;
            offset += 1;
            
            // Parse exit code
            if (offset + 4 > data.length)
                return Err!(ExecuteResponse, string)("Unexpected end of data");
            auto exitSlice = mutableData[offset .. offset + 4];
            response.result.exitCode = exitSlice.read!int();
            offset += 4;
            
            // Parse stdout length and content
            if (offset + 4 > data.length)
                return Err!(ExecuteResponse, string)("Unexpected end of data");
            auto stdoutLenSlice = mutableData[offset .. offset + 4];
            immutable stdoutLen = stdoutLenSlice.read!uint();
            offset += 4;
            
            if (offset + stdoutLen > data.length)
                return Err!(ExecuteResponse, string)("Stdout data truncated");
            if (stdoutLen > 0)
            {
                response.result.stdoutRaw = cast(string)mutableData[offset .. offset + stdoutLen];
                offset += stdoutLen;
            }
            
            // Parse stderr length and content
            if (offset + 4 > data.length)
                return Err!(ExecuteResponse, string)("Unexpected end of data");
            auto stderrLenSlice = mutableData[offset .. offset + 4];
            immutable stderrLen = stderrLenSlice.read!uint();
            offset += 4;
            
            if (offset + stderrLen > data.length)
                return Err!(ExecuteResponse, string)("Stderr data truncated");
            if (stderrLen > 0)
            {
                response.result.stderrRaw = cast(string)mutableData[offset .. offset + stderrLen];
                offset += stderrLen;
            }
            
            // Parse output files count
            if (offset + 4 > data.length)
                return Err!(ExecuteResponse, string)("Unexpected end of data");
            auto filesCountSlice = mutableData[offset .. offset + 4];
            immutable filesCount = filesCountSlice.read!uint();
            offset += 4;
            
            // Parse output files
            for (uint i = 0; i < filesCount; i++)
            {
                ActionResult.OutputFile outFile;
                
                // Parse path length and content
                if (offset + 4 > data.length)
                    return Err!(ExecuteResponse, string)("Output file path truncated");
                auto pathLenSlice = mutableData[offset .. offset + 4];
                immutable pathLen = pathLenSlice.read!uint();
                offset += 4;
                
                if (offset + pathLen > data.length)
                    return Err!(ExecuteResponse, string)("Output file path data truncated");
                outFile.path = cast(string)mutableData[offset .. offset + pathLen];
                offset += pathLen;
                
                // Parse digest hash (32 bytes)
                if (offset + 32 > data.length)
                    return Err!(ExecuteResponse, string)("Output file digest truncated");
                ubyte[32] hash = mutableData[offset .. offset + 32];
                offset += 32;
                
                // Parse digest size
                if (offset + 8 > data.length)
                    return Err!(ExecuteResponse, string)("Output file size truncated");
                auto sizeSlice = mutableData[offset .. offset + 8];
                immutable size = sizeSlice.read!ulong();
                offset += 8;
                
                outFile.digest = Digest(hash, size);
                
                // Parse executable flag
                if (offset >= data.length)
                    return Err!(ExecuteResponse, string)("Executable flag truncated");
                auto execSlice = mutableData[offset .. offset + 1];
                outFile.isExecutable = execSlice.read!ubyte() != 0;
                offset += 1;
                
                response.result.outputFiles ~= outFile;
            }
            
            // Parse execution metadata (timing information)
            if (offset + 8 > data.length)
            {
                // Metadata is optional in some implementations
                return Ok!(ExecuteResponse, string)(response);
            }
            
            auto execTimeSlice = mutableData[offset .. offset + 8];
            immutable execTimeMs = execTimeSlice.read!long();
            offset += 8;
            response.result.executionMetadata.executionCompleteTime = Duration.init;
            
            // Parse message length if present
            if (offset + 4 <= data.length)
            {
                auto msgLenSlice = mutableData[offset .. offset + 4];
                immutable msgLen = msgLenSlice.read!uint();
                offset += 4;
                
                if (offset + msgLen <= data.length)
                {
                    response.message = cast(string)mutableData[offset .. offset + msgLen];
                    offset += msgLen;
                }
            }
            
            return Ok!(ExecuteResponse, string)(response);
        }
        catch (Exception e)
        {
            return Err!(ExecuteResponse, string)("Parse error: " ~ e.msg);
        }
    }
}

/// REAPI capabilities
/// Reports worker capabilities to REAPI clients
struct ExecutionCapabilities
{
    DigestFunction digestFunction;          // Hash function
    ActionCacheUpdateCapabilities actionCacheUpdateCapabilities;
    ExecutionPriorityCapabilities executionPriorityCapabilities;
    SymlinkAbsolutePathStrategy symlinkAbsolutePathStrategy;
    
    /// Digest function enum
    enum DigestFunction
    {
        BLAKE3,     // Builder's native
        SHA256,     // REAPI standard
        SHA1
    }
    
    /// Action cache capabilities
    struct ActionCacheUpdateCapabilities
    {
        bool updateEnabled = true;
    }
    
    /// Priority capabilities
    struct ExecutionPriorityCapabilities
    {
        Priority[] priorities;
    }
    
    /// Symlink handling
    enum SymlinkAbsolutePathStrategy
    {
        UNKNOWN,
        DISALLOWED,
        ALLOWED
    }
}

