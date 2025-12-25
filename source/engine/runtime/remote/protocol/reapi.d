module engine.runtime.remote.protocol.reapi;

import std.datetime : Duration, seconds;
import std.conv : to;
import std.digest : toHexString;
import std.string : toLower, format;
import std.algorithm : map;
import std.array : array;
import engine.distributed.protocol.protocol;
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
/// Translates between REAPI and Builder's native protocol
final class ReapiAdapter
{
    private string remoteUrl;
    
    this(string remoteUrl) @safe
    {
        this.remoteUrl = remoteUrl;
    }
    
    /// Execute action via REAPI
    BuildResult!ExecuteResponse execute(
        Action action,
        bool skipCacheLookup = false
    ) @trusted
    {
        // Convert to Builder action request
        auto actionDigest = action.digest();
        
        // Serialize execute request
        auto requestData = ReapiCodec.serializeExecuteRequest(action, skipCacheLookup);
        
        // Send to remote execution endpoint
        auto httpResult = sendHttpRequest("POST", remoteUrl ~ "/v2/actions/execute", requestData);
        
        if (httpResult.isErr)
            return Err!(ExecuteResponse, BuildError)(httpResult.unwrapErr());
        
        // Deserialize response
        auto parseResult = ReapiCodec.deserializeExecuteResponse(httpResult.unwrap());
        if (parseResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("Failed to parse execute response: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ExecuteResponse, BuildError)(parseResult.unwrap());
    }
    
    /// Wait for execution (long-running operation)
    BuildResult!ExecuteResponse waitExecution(
        string operationName,
        Duration timeout = 0.seconds
    ) @trusted
    {
        import core.time : MonoTime;
        import core.thread : Thread;
        import std.datetime : msecs;
        
        // Poll for operation completion
        auto startTime = MonoTime.currTime;
        immutable timeoutMonoTime = timeout > Duration.zero ? startTime + timeout : MonoTime.max;
        
        while (MonoTime.currTime < timeoutMonoTime)
        {
            // Query operation status
            auto statusResult = getOperationStatus(operationName);
            if (statusResult.isErr)
                return Err!(ExecuteResponse, BuildError)(statusResult.unwrapErr());
            
            auto response = statusResult.unwrap();
            
            // Check if completed
            if (response.status.code == 0)
                return Ok!(ExecuteResponse, BuildError)(response);
            
            // Check if error
            if (response.status.code != 0 && response.status.code != 1) // 1 = IN_PROGRESS
                return Err!(ExecuteResponse, BuildError)(
                    Errors.generic("Operation failed: " ~ response.status.message, ErrorCode.BuildFailed));
            
            // Wait before polling again
            Thread.sleep(500.msecs);
        }
        
        // Timeout reached
        return Err!(ExecuteResponse, BuildError)(
            Errors.generic("Operation timeout", ErrorCode.BuildTimeout));
    }
    
    /// Get operation status
    private BuildResult!ExecuteResponse getOperationStatus(string operationName) @trusted
    {
        auto httpResult = sendHttpRequest("GET", remoteUrl ~ "/v2/operations/" ~ operationName, []);
        
        if (httpResult.isErr)
            return Err!(ExecuteResponse, BuildError)(httpResult.unwrapErr());
        
        auto parseResult = ReapiCodec.deserializeExecuteResponse(httpResult.unwrap());
        if (parseResult.isErr)
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("Failed to parse operation status: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ExecuteResponse, BuildError)(parseResult.unwrap());
    }
    
    /// Get action result from cache
    BuildResult!ActionResult getActionResult(
        Digest actionDigest
    ) @trusted
    {
        import std.uri : encode;
        
        // Query action cache via HTTP GET
        immutable path = format("/v2/actionResults/%s/%s", 
            actionDigest.toString(), actionDigest.sizeBytes);
        
        auto httpResult = sendHttpRequest("GET", remoteUrl ~ path, []);
        
        if (httpResult.isErr)
        {
            // Not found is expected for cache misses
            auto err = httpResult.unwrapErr();
            if (auto cacheErr = cast(CacheError)err)
            {
                if (cacheErr.code == ErrorCode.CacheNotFound)
                {
                    ActionResult emptyResult;
                    return Ok!(ActionResult, BuildError)(emptyResult);
                }
            }
            return Err!(ActionResult, BuildError)(err);
        }
        
        // Deserialize action result
        auto parseResult = deserializeActionResult(httpResult.unwrap());
        if (parseResult.isErr)
            return Err!(ActionResult, BuildError)(
                Errors.generic("Failed to parse action result: " ~ parseResult.unwrapErr(), ErrorCode.NetworkError));
        
        return Ok!(ActionResult, BuildError)(parseResult.unwrap());
    }
    
    /// Update action result in cache
    VoidBuildResult updateActionResult(
        Digest actionDigest,
        ActionResult result
    ) @trusted
    {
        import std.uri : encode;
        
        // Serialize action result
        auto resultData = serializeActionResult(result);
        
        // Upload to cache via HTTP PUT
        immutable path = format("/v2/actionResults/%s/%s",
            actionDigest.toString(), actionDigest.sizeBytes);
        
        auto httpResult = sendHttpRequest("PUT", remoteUrl ~ path, resultData);
        
        if (httpResult.isErr)
            return VoidBuildResult.err(httpResult.unwrapErr());
        
        return Ok!BuildError();
    }
    
    /// Send HTTP request helper
    private BuildResult!(ubyte[]) sendHttpRequest(
        string method,
        string url,
        const ubyte[] body_
    ) @trusted
    {
        import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown;
        import std.string : indexOf, startsWith;
        
        // Parse URL
        string host;
        ushort port = 80;
        string path;
        
        string remaining = url;
        if (remaining.startsWith("http://"))
            remaining = remaining[7 .. $];
        else if (remaining.startsWith("https://"))
        {
            remaining = remaining[8 .. $];
            port = 443;
        }
        
        immutable slashPos = remaining.indexOf('/');
        if (slashPos >= 0)
        {
            host = remaining[0 .. slashPos];
            path = remaining[slashPos .. $];
        }
        else
        {
            host = remaining;
            path = "/";
        }
        
        try
        {
            auto addr = new InternetAddress(host, port);
            auto socket = new TcpSocket();
            socket.connect(addr);
            scope(exit) { socket.shutdown(SocketShutdown.BOTH); socket.close(); }
            
            // Build HTTP request
            string request = method ~ " " ~ path ~ " HTTP/1.1\r\n";
            request ~= "Host: " ~ host ~ "\r\n";
            request ~= "Content-Length: " ~ body_.length.to!string ~ "\r\n";
            request ~= "Content-Type: application/octet-stream\r\n";
            request ~= "\r\n";
            
            // Send request
            socket.send(request);
            if (body_.length > 0)
                socket.send(body_);
            
            // Receive response
            ubyte[] responseData;
            ubyte[4096] buffer;
            while (true)
            {
                auto received = socket.receive(buffer);
                if (received <= 0)
                    break;
                responseData ~= buffer[0 .. received];
            }
            
            // Parse HTTP response (simple)
            immutable responseStr = cast(string)responseData;
            immutable headersEnd = responseStr.indexOf("\r\n\r\n");
            if (headersEnd < 0)
                return Err!(ubyte[], BuildError)(
                    Errors.generic("Invalid HTTP response", ErrorCode.NetworkError));
            
            // Extract status code
            import std.array : split;
            immutable firstLine = responseStr[0 .. responseStr.indexOf('\r')];
            auto parts = firstLine.split(' ');
            if (parts.length < 2)
                return Err!(ubyte[], BuildError)(
                    Errors.generic("Invalid HTTP status line", ErrorCode.NetworkError));
            
            immutable statusCode = parts[1].to!int;
            if (statusCode == 404)
                return Err!(ubyte[], BuildError)(
                    Errors.cache("Not found", ErrorCode.CacheNotFound));
            else if (statusCode >= 400)
                return Err!(ubyte[], BuildError)(
                    Errors.generic("HTTP error: " ~ statusCode.to!string, ErrorCode.NetworkError));
            
            // Extract body
            auto body_result = cast(ubyte[])responseData[headersEnd + 4 .. $];
            return Ok!(ubyte[], BuildError)(body_result);
        }
        catch (Exception e)
        {
            return Err!(ubyte[], BuildError)(
                Errors.generic("HTTP request failed: " ~ e.msg, ErrorCode.NetworkError));
        }
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
/// Wire format compatible with Bazel REAPI but using efficient binary encoding
struct ReapiCodec
{
    /// Serialize ExecuteRequest
    static ubyte[] serializeExecuteRequest(Action action, bool skipCacheLookup) @trusted
    {
        import std.bitmanip : write;
        
        ubyte[] buffer;
        buffer.reserve(1024);
        
        // Action digest
        buffer ~= action.digest().hash;
        buffer.write!ulong(action.digest().sizeBytes, buffer.length);
        
        // Skip cache flag
        buffer.write!ubyte(skipCacheLookup ? 1 : 0, buffer.length);
        
        // Platform properties
        buffer.write!uint(cast(uint)action.platform.properties.length, buffer.length);
        foreach (prop; action.platform.properties)
        {
            buffer.write!uint(cast(uint)prop.name.length, buffer.length);
            buffer ~= cast(ubyte[])prop.name;
            buffer.write!uint(cast(uint)prop.value.length, buffer.length);
            buffer ~= cast(ubyte[])prop.value;
        }
        
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

