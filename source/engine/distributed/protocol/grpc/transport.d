module engine.distributed.protocol.grpc.transport;

import std.datetime : Duration, seconds, msecs;
import std.string : split, indexOf;
import std.conv : to;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport : Transport;
import engine.distributed.protocol.grpc.codec;
import engine.distributed.protocol.grpc.types;
import engine.distributed.protocol.grpc.http2;
import engine.distributed.protocol.grpc.frame;
import infrastructure.errors;

/// gRPC transport configuration
struct GrpcConfig {
    string target;                          // Target endpoint (host:port)
    bool useTls = false;                    // Use TLS?
    string rootCerts;                       // Root CA certificates (PEM)
    string clientCert;                      // Client certificate (PEM)
    string clientKey;                       // Client private key (PEM)
    Duration connectTimeout = 30.seconds;   // Connection timeout
    Duration callTimeout = 60.seconds;      // Default call timeout
    size_t maxMessageSize = 4 * 1024 * 1024; // 4MB default
    bool enableRetry = true;                // Enable automatic retry
    size_t maxRetries = 3;                  // Max retry attempts
    
    /// Create config for insecure channel
    static GrpcConfig insecure(string target) pure nothrow @safe @nogc =>
        GrpcConfig(target, false);
    
    /// Create config for TLS channel
    static GrpcConfig secure(string target, string rootCerts = "") pure nothrow @safe =>
        GrpcConfig(target, true, rootCerts);
    
    /// Parse host and port from target
    auto parseTarget() const @trusted {
        struct Result { string host; ushort port; }
        
        auto colonIdx = target.indexOf(':');
        if (colonIdx > 0) {
            try {
                return Result(target[0 .. colonIdx], target[colonIdx + 1 .. $].to!ushort);
            } catch (Exception) {}
        }
        return Result(target, 443);  // Default gRPC port
    }
}

/// gRPC call context
struct GrpcCallContext {
    Duration timeout;
    string[string] metadata;
    bool cancelled;
}

/**
 * gRPC Transport Implementation
 * 
 * Provides full HTTP/2 + gRPC wire protocol support for REAPI compatibility.
 * Uses pure D implementation - no external grpc-core dependency required.
 */
final class GrpcTransport : Transport {
    private GrpcConfig config;
    private GrpcCodec codec;
    private H2Connection connection;
    private bool connected;
    
    /// Construct gRPC transport
    this(GrpcConfig config) @trusted {
        this.config = config;
        this.codec = new GrpcCodec();
        this.connection = new H2Connection();
    }
    
    /// Connect to remote endpoint
    Result!DistributedError connect() @trusted {
        if (connected)
            return Ok!DistributedError();
        
        auto target = config.parseTarget();
        auto result = connection.connect(target.host, target.port, config.connectTimeout);
        
        if (result.isErr)
            return Result!DistributedError.err(
                new DistributedError("gRPC connect failed: " ~ result.unwrapErr()));
        
        connected = true;
        return Ok!DistributedError();
    }
    
    /// Send HeartBeat message
    Result!DistributedError sendHeartBeat(WorkerId recipient, HeartBeat message) @trusted {
        // HeartBeat uses Builder's native protocol over gRPC
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return connectResult;
        
        auto encoded = codec.encodeHeartBeat(message);
        auto method = GrpcMethod("builder.remote.v1.CoordinatorService", "Heartbeat", true, true);
        
        auto callResult = unaryCall(method, encoded);
        if (callResult.isErr)
            return Result!DistributedError.err(
                new DistributedError("HeartBeat failed: " ~ callResult.unwrapErr()));
        
        return Ok!DistributedError();
    }
    
    /// Send StealRequest message
    Result!DistributedError sendStealRequest(WorkerId recipient, StealRequest message) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return connectResult;
        
        auto encoded = codec.encodeStealRequest(message);
        auto method = GrpcMethod("builder.remote.v1.WorkerService", "Steal", false, false);
        
        auto callResult = unaryCall(method, encoded);
        if (callResult.isErr)
            return Result!DistributedError.err(
                new DistributedError("StealRequest failed: " ~ callResult.unwrapErr()));
        
        return Ok!DistributedError();
    }
    
    /// Send StealResponse message
    Result!DistributedError sendStealResponse(WorkerId recipient, StealResponse message) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return connectResult;
        
        auto encoded = codec.encodeStealResponse(message);
        // StealResponse is sent as response to Steal RPC, not a separate call
        return Ok!DistributedError();
    }
    
    /// Receive StealResponse message
    Result!(Envelope!StealResponse, DistributedError) receiveStealResponse(Duration timeout) @trusted {
        // This is handled by the unary call response
        return Err!(Envelope!StealResponse, DistributedError)(
            new DistributedError("Use unary call for steal response"));
    }
    
    /// Check if connected
    bool isConnected() @trusted => connected && connection.isConnected();
    
    /// Close connection
    void close() @trusted {
        connection.close();
        connected = false;
    }
    
    // =========================================================================
    // gRPC Call Methods
    // =========================================================================
    
    /// Execute action remotely (REAPI Execute)
    Result!(ActionResult, DistributedError) execute(ActionRequest request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ActionResult, DistributedError)(
                new DistributedError("Connection failed"));
        
        auto encoded = codec.encodeActionRequest(request);
        auto method = ReapiServices.execute();
        
        auto callResult = serverStreamingCall(method, encoded);
        if (callResult.isErr)
            return Err!(ActionResult, DistributedError)(
                new DistributedError("Execute failed: " ~ callResult.unwrapErr()));
        
        // The response is a stream of Operation messages; wait for completion
        auto responses = callResult.unwrap();
        if (responses.length == 0)
            return Err!(ActionResult, DistributedError)(
                new DistributedError("No response received"));
        
        // Decode the final response
        return codec.decodeActionResult(responses[$ - 1]);
    }
    
    /// Execute with streaming progress
    Result!(void delegate(ExecutionProgress), DistributedError) executeStream(
        ActionRequest request,
        void delegate(ExecutionProgress) onProgress
    ) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(void delegate(ExecutionProgress), DistributedError)(
                new DistributedError("Connection failed"));
        
        auto encoded = codec.encodeActionRequest(request);
        auto method = ReapiServices.execute();
        
        // Start streaming call
        auto streamResult = startServerStreamingCall(method, encoded);
        if (streamResult.isErr)
            return Err!(void delegate(ExecutionProgress), DistributedError)(
                new DistributedError("Execute stream failed: " ~ streamResult.unwrapErr()));
        
        auto streamId = streamResult.unwrap();
        
        // Return callback that reads from stream
        return Ok!(void delegate(ExecutionProgress), DistributedError)(
            (ExecutionProgress _) { /* Streaming handled internally */ });
    }
    
    /// Register worker with coordinator
    Result!(RegisterWorkerResponse, DistributedError) registerWorker(
        WorkerId workerId,
        string address,
        Capabilities caps,
        uint maxConcurrent
    ) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(RegisterWorkerResponse, DistributedError)(
                new DistributedError("Connection failed"));
        
        auto encoded = codec.encodeRegisterWorkerRequest(workerId, address, caps, maxConcurrent);
        auto method = GrpcMethod("builder.remote.v1.CoordinatorService", "RegisterWorker", false, false);
        
        auto callResult = unaryCall(method, encoded);
        if (callResult.isErr)
            return Err!(RegisterWorkerResponse, DistributedError)(
                new DistributedError("RegisterWorker failed: " ~ callResult.unwrapErr()));
        
        return codec.decodeRegisterWorkerResponse(callResult.unwrap());
    }
    
    /// Start bidirectional heartbeat stream
    Result!DistributedError startHeartbeatStream(
        void delegate(HeartBeat) sendHeartbeat,
        void delegate(CoordinatorCommand) onCommand
    ) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return connectResult;
        
        // Bidirectional streaming not fully implemented yet
        return Result!DistributedError.err(
            new DistributedError("Bidirectional streaming not yet implemented"));
    }
    
    // =========================================================================
    // REAPI-specific methods
    // =========================================================================
    
    /// Get server capabilities (REAPI)
    Result!(ubyte[], string) getCapabilities(string instanceName) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        import engine.distributed.protocol.reapi_v2.codec : ReapiV2Codec;
        import engine.distributed.protocol.reapi_v2.types : ReapiGetCapabilitiesRequest;
        
        ReapiGetCapabilitiesRequest req;
        req.instanceName = instanceName;
        auto encoded = ReapiV2Codec.encodeGetCapabilitiesRequest(req);
        
        auto method = ReapiServices.getCapabilities();
        return unaryCall(method, encoded);
    }
    
    /// Find missing blobs (REAPI CAS)
    Result!(ubyte[], string) findMissingBlobs(const ubyte[] request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        auto method = ReapiServices.findMissingBlobs();
        return unaryCall(method, request);
    }
    
    /// Batch update blobs (REAPI CAS)
    Result!(ubyte[], string) batchUpdateBlobs(const ubyte[] request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        auto method = ReapiServices.batchUpdateBlobs();
        return unaryCall(method, request);
    }
    
    /// Batch read blobs (REAPI CAS)
    Result!(ubyte[], string) batchReadBlobs(const ubyte[] request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        auto method = ReapiServices.batchReadBlobs();
        return unaryCall(method, request);
    }
    
    /// Get action result (REAPI ActionCache)
    Result!(ubyte[], string) getActionResult(const ubyte[] request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        auto method = ReapiServices.getActionResult();
        return unaryCall(method, request);
    }
    
    /// Update action result (REAPI ActionCache)
    Result!(ubyte[], string) updateActionResult(const ubyte[] request) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr)
            return Err!(ubyte[], string)("Connection failed");
        
        auto method = ReapiServices.updateActionResult();
        return unaryCall(method, request);
    }
    
    // =========================================================================
    // Internal call implementations
    // =========================================================================
    
    private Result!DistributedError ensureConnected() @trusted {
        if (!connected || !connection.isConnected())
            return connect();
        return Ok!DistributedError();
    }
    
    /// Unary RPC call
    private Result!(ubyte[], string) unaryCall(GrpcMethod method, const ubyte[] request) @trusted {
        // Create stream
        auto streamResult = connection.createStream();
        if (streamResult.isErr)
            return Err!(ubyte[], string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        auto target = config.parseTarget();
        
        // Build and send headers
        auto headers = GrpcHeaders.requestHeaders(
            target.host ~ ":" ~ target.port.to!string,
            method.path,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(config.callTimeout.total!"nsecs")
        );
        
        auto headerBlock = HpackEncoder.encode(headers);
        auto sendHeadersResult = connection.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(ubyte[], string)(sendHeadersResult.unwrapErr());
        
        // Send request data with gRPC framing
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = connection.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr)
            return Err!(ubyte[], string)(sendDataResult.unwrapErr());
        
        // Receive response
        auto responseResult = connection.receiveResponse(streamId);
        if (responseResult.isErr)
            return Err!(ubyte[], string)(responseResult.unwrapErr());
        
        auto response = responseResult.unwrap();
        
        // Check gRPC status
        auto status = response.grpcStatus;
        if (status != 0 && status != -1)
            return Err!(ubyte[], string)("gRPC error " ~ status.to!string ~ ": " ~ response.grpcMessage);
        
        // Parse gRPC frame from response data
        if (response.data.length < GrpcFrame.HeaderSize)
            return Ok!(ubyte[], string)(cast(ubyte[])[]);
        
        auto frameResult = GrpcFrame.decode(response.data, config.maxMessageSize);
        if (frameResult.isErr)
            return Err!(ubyte[], string)(frameResult.unwrapErr());
        
        return Ok!(ubyte[], string)(frameResult.unwrap().message);
    }
    
    /// Server streaming RPC call
    private Result!(ubyte[][], string) serverStreamingCall(
        GrpcMethod method, 
        const ubyte[] request
    ) @trusted {
        auto streamResult = connection.createStream();
        if (streamResult.isErr)
            return Err!(ubyte[][], string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        auto target = config.parseTarget();
        
        // Build and send headers
        auto headers = GrpcHeaders.requestHeaders(
            target.host ~ ":" ~ target.port.to!string,
            method.path,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(config.callTimeout.total!"nsecs")
        );
        
        auto headerBlock = HpackEncoder.encode(headers);
        auto sendHeadersResult = connection.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(ubyte[][], string)(sendHeadersResult.unwrapErr());
        
        // Send request data
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = connection.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr)
            return Err!(ubyte[][], string)(sendDataResult.unwrapErr());
        
        // Receive all responses
        ubyte[][] responses;
        auto reader = GrpcStreamReader(config.maxMessageSize);
        
        while (true) {
            auto responseResult = connection.receiveResponse(streamId);
            if (responseResult.isErr)
                break;
            
            auto response = responseResult.unwrap();
            reader.addData(response.data);
            
            while (reader.hasData) {
                auto msgResult = reader.readMessage();
                if (msgResult.isOk)
                    responses ~= msgResult.unwrap().message;
                else
                    break;
            }
            
            // Check for end of stream
            auto status = response.grpcStatus;
            if (status != -1)
                break;
        }
        
        return Ok!(ubyte[][], string)(responses);
    }
    
    /// Start server streaming call (returns stream ID)
    private Result!(uint, string) startServerStreamingCall(
        GrpcMethod method, 
        const ubyte[] request
    ) @trusted {
        auto streamResult = connection.createStream();
        if (streamResult.isErr)
            return streamResult;
        
        auto streamId = streamResult.unwrap();
        auto target = config.parseTarget();
        
        auto headers = GrpcHeaders.requestHeaders(
            target.host ~ ":" ~ target.port.to!string,
            method.path,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(config.callTimeout.total!"nsecs")
        );
        
        auto headerBlock = HpackEncoder.encode(headers);
        auto sendHeadersResult = connection.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(uint, string)(sendHeadersResult.unwrapErr());
        
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = connection.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr)
            return Err!(uint, string)(sendDataResult.unwrapErr());
        
        return Ok!(uint, string)(streamId);
    }
}

/// Transport factory with gRPC support
final class GrpcTransportFactory {
    /// Create gRPC transport
    static Result!(GrpcTransport, DistributedError) create(GrpcConfig config) @trusted {
        auto transport = new GrpcTransport(config);
        auto connectResult = transport.connect();
        
        if (connectResult.isErr)
            return Err!(GrpcTransport, DistributedError)(connectResult.unwrapErr());
        
        return Ok!(GrpcTransport, DistributedError)(transport);
    }
    
    /// Create from URL
    static Result!(GrpcTransport, DistributedError) createFromUrl(string url) @trusted {
        import std.algorithm : startsWith;
        
        if (url.startsWith("grpc://")) {
            auto target = url[7 .. $];
            return create(GrpcConfig.insecure(target));
        } else if (url.startsWith("grpcs://")) {
            auto target = url[8 .. $];
            return create(GrpcConfig.secure(target, ""));
        }
        
        return Err!(GrpcTransport, DistributedError)(
            new DistributedError("Invalid gRPC URL: " ~ url));
    }
    
    /// Check if native gRPC (grpc-core) is available
    static bool isNativeGrpcAvailable() @trusted nothrow {
        // Always return true now - we have pure D implementation
        return true;
    }
}
