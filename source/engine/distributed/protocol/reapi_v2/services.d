module engine.distributed.protocol.reapi_v2.services;

import std.datetime : Duration, SysTime, Clock, seconds, msecs;
import std.conv : to;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.reapi_v2.types;
import engine.distributed.protocol.reapi_v2.codec;
import engine.distributed.protocol.reapi_v2.adapter;
import engine.distributed.protocol.reapi_v2.hash;
import infrastructure.errors;

/**
 * REAPI v2 Service Implementations
 * 
 * Provides service-layer abstractions matching REAPI gRPC services:
 * - ExecutionService: Remote action execution
 * - ActionCacheService: Action result caching  
 * - ContentAddressableStorageService: Blob storage
 * - CapabilitiesService: Server capability reporting
 */

/// Execution service interface (matches build.bazel.remote.execution.v2.Execution)
interface IExecutionService {
    /// Execute an action remotely
    /// Returns operation name for long-running operations
    BuildResult!ReapiOperation execute(ReapiExecuteRequest request) @safe;
    
    /// Wait for operation completion
    BuildResult!ReapiOperation waitExecution(string operationName, Duration timeout) @safe;
    
    /// Cancel running operation
    VoidBuildResult cancelOperation(string operationName) @safe;
}

/// Action cache service interface (matches build.bazel.remote.execution.v2.ActionCache)
interface IActionCacheService {
    /// Get cached action result
    BuildResult!ReapiActionResult getActionResult(
        string instanceName,
        ReapiDigest actionDigest,
        bool inlineStdout = false,
        bool inlineStderr = false
    ) @safe;
    
    /// Update action cache with new result
    BuildResult!ReapiActionResult updateActionResult(
        string instanceName,
        ReapiDigest actionDigest,
        ReapiActionResult result,
        ReapiResultsCachePolicy policy
    ) @safe;
}

/// Content addressable storage interface (matches build.bazel.remote.execution.v2.ContentAddressableStorage)
interface IContentAddressableStorageService {
    /// Find which blobs are missing
    ReapiDigest[] findMissingBlobs(string instanceName, ReapiDigest[] digests) @safe;
    
    /// Batch upload blobs
    ReapiBlobResponse[] batchUpdateBlobs(string instanceName, ReapiBlobRequest[] requests) @safe;
    
    /// Batch download blobs
    ReapiBlobResponse[] batchReadBlobs(string instanceName, ReapiDigest[] digests) @safe;
    
    /// Get directory tree
    ReapiDirectory[] getTree(string instanceName, ReapiDigest rootDigest, int pageSize) @safe;
}

/// Capabilities service interface (matches build.bazel.remote.execution.v2.Capabilities)
interface ICapabilitiesService {
    /// Get server capabilities
    ReapiServerCapabilities getCapabilities(string instanceName) @safe;
}

/**
 * Execution service implementation
 * 
 * Wraps Builder's execution coordinator to provide REAPI-compatible interface
 */
final class ExecutionService : IExecutionService {
    private ReapiV2Adapter adapter;
    private ReapiOperation[string] operations;  // Active operations
    private size_t operationCounter;
    
    /// Execution delegate for actual action execution
    alias ExecuteDelegate = BuildResult!ActionResult delegate(ActionRequest) @safe;
    private ExecuteDelegate executeDelegate;
    
    this(ExecuteDelegate executeDelegate) @safe {
        this.adapter = new ReapiV2Adapter();
        this.executeDelegate = executeDelegate;
    }
    
    /// Execute an action
    BuildResult!ReapiOperation execute(ReapiExecuteRequest request) @trusted {
        // Generate operation name
        auto opName = "operations/" ~ (++operationCounter).to!string;
        
        // Create operation record
        ReapiOperation op;
        op.name = opName;
        op.done = false;
        
        // Check cache first (unless skip requested)
        if (!request.skipCacheLookup) {
            // TODO: Check action cache
        }
        
        // Convert REAPI request to Builder request
        ReapiCommand cmd;  // Would be loaded from CAS using commandDigest
        ReapiAction action;
        action.commandDigest = request.actionDigest;
        
        auto reqResult = adapter.reapiToActionRequest(action, cmd, request.actionDigest);
        if (reqResult.isErr) {
            op.done = true;
            op.error = ReapiStatus.invalidArgument(reqResult.unwrapErr());
            operations[opName] = op;
            return Ok!(ReapiOperation, BuildError)(op);
        }
        
        // Execute action
        if (executeDelegate !is null) {
            auto execResult = executeDelegate(reqResult.unwrap());
            
            if (execResult.isOk) {
                op.done = true;
                op.response.result = adapter.actionResultToReapi(execResult.unwrap());
                op.response.status = ReapiStatus.ok();
                op.response.cachedResult = false;
            } else {
                op.done = true;
                op.error = ReapiStatus.internal(execResult.unwrapErr().message());
            }
        } else {
            op.done = true;
            op.error = ReapiStatus.unimplemented("No execute delegate configured");
        }
        
        operations[opName] = op;
        return Ok!(ReapiOperation, BuildError)(op);
    }
    
    /// Wait for operation
    BuildResult!ReapiOperation waitExecution(string operationName, Duration timeout) @trusted {
        import core.time : MonoTime;
        import core.thread : Thread;
        
        auto startTime = MonoTime.currTime;
        auto deadline = timeout > Duration.zero ? startTime + timeout : MonoTime.max;
        
        while (MonoTime.currTime < deadline) {
            if (auto op = operationName in operations) {
                if (op.done)
                    return Ok!(ReapiOperation, BuildError)(*op);
            } else {
                return Err!(ReapiOperation, BuildError)(
                    DistributedErrors.protocol("Operation not found: " ~ operationName).build());
            }
            
            Thread.sleep(100.msecs);
        }
        
        return Err!(ReapiOperation, BuildError)(
            DistributedErrors.protocol("Operation timeout").build());
    }
    
    /// Cancel operation
    VoidBuildResult cancelOperation(string operationName) @trusted {
        if (auto op = operationName in operations) {
            if (!op.done) {
                op.done = true;
                op.error = ReapiStatus.cancelled();
            }
            return Ok!BuildError();
        }
        
        return VoidBuildResult.err(
            DistributedErrors.protocol("Operation not found: " ~ operationName).build());
    }
}

/**
 * Action cache service implementation
 */
final class ActionCacheService : IActionCacheService {
    private ReapiV2Adapter adapter;
    private ReapiActionResult[ReapiDigest] cache;
    
    this() @safe {
        adapter = new ReapiV2Adapter();
    }
    
    BuildResult!ReapiActionResult getActionResult(
        string instanceName,
        ReapiDigest actionDigest,
        bool inlineStdout = false,
        bool inlineStderr = false
    ) @trusted {
        if (auto result = actionDigest in cache)
            return Ok!(ReapiActionResult, BuildError)(*result);
        
        return Err!(ReapiActionResult, BuildError)(
            Errors.cache("Action not found in cache", Cache.NotFound).build());
    }
    
    BuildResult!ReapiActionResult updateActionResult(
        string instanceName,
        ReapiDigest actionDigest,
        ReapiActionResult result,
        ReapiResultsCachePolicy policy
    ) @trusted {
        cache[actionDigest] = result;
        return Ok!(ReapiActionResult, BuildError)(result);
    }
}

/**
 * Content addressable storage service implementation
 */
final class ContentAddressableStorageService : IContentAddressableStorageService {
    private ubyte[][ReapiDigest] blobs;
    private ReapiDirectory[ReapiDigest] directories;
    
    ReapiDigest[] findMissingBlobs(string instanceName, ReapiDigest[] digests) @trusted {
        ReapiDigest[] missing;
        
        foreach (digest; digests)
            if (digest !in blobs)
                missing ~= digest;
        
        return missing;
    }
    
    ReapiBlobResponse[] batchUpdateBlobs(string instanceName, ReapiBlobRequest[] requests) @trusted {
        ReapiBlobResponse[] responses;
        
        foreach (req; requests) {
            blobs[req.digest] = req.data.dup;
            
            ReapiBlobResponse resp;
            resp.digest = req.digest;
            resp.status = ReapiStatus.ok();
            responses ~= resp;
        }
        
        return responses;
    }
    
    ReapiBlobResponse[] batchReadBlobs(string instanceName, ReapiDigest[] digests) @trusted {
        ReapiBlobResponse[] responses;
        
        foreach (digest; digests) {
            ReapiBlobResponse resp;
            resp.digest = digest;
            
            if (auto data = digest in blobs) {
                resp.data = (*data).dup;
                resp.status = ReapiStatus.ok();
            } else {
                resp.status = ReapiStatus.notFound("Blob not found");
            }
            
            responses ~= resp;
        }
        
        return responses;
    }
    
    ReapiDirectory[] getTree(string instanceName, ReapiDigest rootDigest, int pageSize) @trusted {
        ReapiDirectory[] tree;
        
        if (auto dir = rootDigest in directories) {
            tree ~= *dir;
            // TODO: recursively fetch children
        }
        
        return tree;
    }
    
    /// Direct blob access for internal use
    void putBlob(ReapiDigest digest, const ubyte[] data) @trusted {
        blobs[digest] = data.dup;
    }
    
    ubyte[] getBlob(ReapiDigest digest) @trusted {
        if (auto data = digest in blobs)
            return (*data).dup;
        return [];
    }
    
    bool hasBlob(ReapiDigest digest) @trusted =>
        (digest in blobs) !is null;
}

/**
 * Capabilities service implementation
 */
final class CapabilitiesService : ICapabilitiesService {
    private ReapiV2Adapter adapter;
    
    this() @safe {
        adapter = new ReapiV2Adapter();
    }
    
    ReapiServerCapabilities getCapabilities(string instanceName) @safe =>
        adapter.buildServerCapabilities();
}

/**
 * Composite REAPI service bundle
 * 
 * Combines all REAPI services into a single interface for easy deployment
 */
final class ReapiServiceBundle {
    private ExecutionService executionService;
    private ActionCacheService actionCacheService;
    private ContentAddressableStorageService casService;
    private CapabilitiesService capabilitiesService;
    
    this(ExecutionService.ExecuteDelegate executeDelegate) @safe {
        executionService = new ExecutionService(executeDelegate);
        actionCacheService = new ActionCacheService();
        casService = new ContentAddressableStorageService();
        capabilitiesService = new CapabilitiesService();
    }
    
    /// Access individual services
    IExecutionService execution() @safe => executionService;
    IActionCacheService actionCache() @safe => actionCacheService;
    IContentAddressableStorageService cas() @safe => casService;
    ICapabilitiesService capabilities() @safe => capabilitiesService;
    
    /// Shortcut: execute action
    BuildResult!ReapiOperation execute(ReapiExecuteRequest request) @safe =>
        executionService.execute(request);
    
    /// Shortcut: get capabilities
    ReapiServerCapabilities getCapabilities() @safe =>
        capabilitiesService.getCapabilities("");
    
    /// Register content and get digests in both formats
    ReapiDigest registerContent(const ubyte[] content) @trusted {
        import engine.distributed.protocol.reapi_v2.hash : digestContent;
        
        auto digest = digestContent(content, DigestFunction.SHA256);
        casService.putBlob(digest, content);
        
        return digest;
    }
}

/**
 * REAPI request router
 * 
 * Routes incoming REAPI requests to appropriate service handlers
 */
struct ReapiRouter {
    private ReapiServiceBundle services;
    
    this(ReapiServiceBundle services) @safe {
        this.services = services;
    }
    
    /// Route request based on path and method
    Result!(ubyte[], string) route(string method, string path, const ubyte[] body_) @trusted {
        import std.string : indexOf, startsWith;
        
        // Extract instance name from path
        // Format: /v2/{instance_name}/...
        string instanceName = "";
        if (path.startsWith("/v2/")) {
            auto rest = path[4 .. $];
            auto slashIdx = rest.indexOf('/');
            if (slashIdx > 0)
                instanceName = rest[0 .. slashIdx];
        }
        
        // Capabilities
        if (path.indexOf("/capabilities") >= 0) {
            auto caps = services.getCapabilities();
            return Ok!(ubyte[], string)(ReapiV2Codec.encodeServerCapabilities(caps));
        }
        
        // Execute
        if (path.indexOf("/actions:execute") >= 0 && method == "POST") {
            return routeExecute(instanceName, body_);
        }
        
        // Action cache
        if (path.indexOf("/actionResults/") >= 0) {
            return routeActionCache(method, path, instanceName, body_);
        }
        
        // CAS - findMissing
        if (path.indexOf("/blobs:findMissing") >= 0 && method == "POST") {
            return routeFindMissing(instanceName, body_);
        }
        
        // CAS - batch update
        if (path.indexOf("/blobs:batchUpdate") >= 0 && method == "POST") {
            return routeBatchUpdate(instanceName, body_);
        }
        
        // CAS - batch read
        if (path.indexOf("/blobs:batchRead") >= 0 && method == "POST") {
            return routeBatchRead(instanceName, body_);
        }
        
        // CAS - single blob
        if (path.indexOf("/blobs/") >= 0) {
            return routeBlobAccess(method, path, instanceName, body_);
        }
        
        // Operations
        if (path.startsWith("/v2/operations/")) {
            return routeOperation(method, path, body_);
        }
        
        // ByteStream - read
        if (path.indexOf("ByteStream/Read") >= 0) {
            return routeByteStreamRead(body_);
        }
        
        // ByteStream - write
        if (path.indexOf("ByteStream/Write") >= 0) {
            return routeByteStreamWrite(body_);
        }
        
        // ByteStream - query write status
        if (path.indexOf("ByteStream/QueryWriteStatus") >= 0) {
            return routeByteStreamQueryStatus(body_);
        }
        
        return Err!(ubyte[], string)("Unknown endpoint: " ~ method ~ " " ~ path);
    }
    
    private Result!(ubyte[], string) routeByteStreamRead(const ubyte[] body_) @trusted {
        import engine.distributed.protocol.reapi_v2.stream;
        
        auto reqResult = ByteStreamCodec.decodeReadRequest(body_);
        if (reqResult.isErr)
            return Err!(ubyte[], string)("Invalid ByteStream Read request: " ~ reqResult.unwrapErr());
        
        auto request = reqResult.unwrap();
        
        // Parse resource and get blob from CAS
        auto rnResult = ResourceName.parse(request.resourceName);
        if (rnResult.isErr)
            return Err!(ubyte[], string)(rnResult.unwrapErr());
        
        auto rn = rnResult.unwrap();
        auto digest = rn.toDigest();
        
        auto data = (cast(ContentAddressableStorageService)services.cas).getBlob(digest);
        if (data.length == 0)
            return Err!(ubyte[], string)("Blob not found: " ~ request.resourceName);
        
        // Apply offset and limit
        import std.algorithm : min;
        auto startOffset = min(cast(size_t)request.readOffset, data.length);
        auto endOffset = request.readLimit > 0
            ? min(startOffset + cast(size_t)request.readLimit, data.length)
            : data.length;
        
        ByteStreamReadResponse resp;
        resp.data = data[startOffset .. endOffset];
        
        return Ok!(ubyte[], string)(ByteStreamCodec.encodeReadResponse(resp));
    }
    
    private Result!(ubyte[], string) routeByteStreamWrite(const ubyte[] body_) @trusted {
        import engine.distributed.protocol.reapi_v2.stream;
        
        auto reqResult = ByteStreamCodec.decodeWriteRequest(body_);
        if (reqResult.isErr)
            return Err!(ubyte[], string)("Invalid ByteStream Write request: " ~ reqResult.unwrapErr());
        
        auto request = reqResult.unwrap();
        
        // For single-chunk writes (simplified)
        if (request.finishWrite && request.resourceName.length > 0) {
            auto rnResult = ResourceName.parse(request.resourceName);
            if (rnResult.isErr)
                return Err!(ubyte[], string)(rnResult.unwrapErr());
            
            auto rn = rnResult.unwrap();
            (cast(ContentAddressableStorageService)services.cas).putBlob(rn.toDigest(), request.data);
        }
        
        ByteStreamWriteResponse resp;
        resp.committedSize = request.data.length;
        
        return Ok!(ubyte[], string)(ByteStreamCodec.encodeWriteResponse(resp));
    }
    
    private Result!(ubyte[], string) routeByteStreamQueryStatus(const ubyte[] body_) @trusted {
        import engine.distributed.protocol.reapi_v2.stream;
        
        // Simplified - just return not complete
        ByteStreamQueryWriteStatusResponse resp;
        resp.committedSize = 0;
        resp.complete = false;
        
        ubyte[] buf;
        buf ~= ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.Varint);
        buf ~= ReapiV2Codec.encodeVarint(resp.committedSize);
        buf ~= ReapiV2Codec.makeTag(2, ReapiV2Codec.WireType.Varint);
        buf ~= resp.complete ? 0x01 : 0x00;
        
        return Ok!(ubyte[], string)(buf);
    }
    
    private Result!(ubyte[], string) routeExecute(string instanceName, const ubyte[] body_) @trusted {
        // Decode execute request (simplified)
        ReapiExecuteRequest request;
        request.instanceName = instanceName;
        
        auto result = services.execute(request);
        
        if (result.isErr)
            return Err!(ubyte[], string)(result.unwrapErr().message());
        
        auto op = result.unwrap();
        
        // Encode operation response
        ubyte[] buf;
        buf.reserve(512);
        
        // Field 1: name
        buf ~= ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.LengthDelimited);
        buf ~= ReapiV2Codec.encodeVarint(op.name.length);
        buf ~= cast(ubyte[])op.name;
        
        // Field 2: done
        if (op.done) {
            buf ~= ReapiV2Codec.makeTag(2, ReapiV2Codec.WireType.Varint);
            buf ~= 0x01;
        }
        
        return Ok!(ubyte[], string)(buf);
    }
    
    private Result!(ubyte[], string) routeActionCache(
        string method, string path, string instanceName, const ubyte[] body_
    ) @trusted {
        // Parse digest from path
        // Format: /v2/{instance}/actionResults/{hash}/{size}
        ReapiDigest digest;
        
        if (method == "GET") {
            auto result = services.actionCache.getActionResult(instanceName, digest);
            if (result.isErr)
                return Err!(ubyte[], string)(result.unwrapErr().message());
            
            return Ok!(ubyte[], string)(
                ReapiV2Codec.encodeActionResult(result.unwrap()));
        }
        
        if (method == "PUT") {
            auto decodeResult = ReapiV2Codec.decodeActionResult(body_);
            if (decodeResult.isErr)
                return Err!(ubyte[], string)(decodeResult.unwrapErr());
            
            auto updateResult = services.actionCache.updateActionResult(
                instanceName, digest, decodeResult.unwrap(), ReapiResultsCachePolicy.init);
            
            if (updateResult.isErr)
                return Err!(ubyte[], string)(updateResult.unwrapErr().message());
            
            return Ok!(ubyte[], string)(
                ReapiV2Codec.encodeActionResult(updateResult.unwrap()));
        }
        
        return Err!(ubyte[], string)("Unsupported method: " ~ method);
    }
    
    private Result!(ubyte[], string) routeFindMissing(string instanceName, const ubyte[] body_) @trusted {
        // Decode FindMissingBlobsRequest
        auto reqResult = ReapiV2Codec.decodeFindMissingBlobsRequest(body_);
        if (reqResult.isErr)
            return Err!(ubyte[], string)("Invalid FindMissingBlobs request: " ~ reqResult.unwrapErr());
        
        auto request = reqResult.unwrap();
        
        // Find missing blobs via CAS service
        auto missing = services.cas.findMissingBlobs(
            request.instanceName.length > 0 ? request.instanceName : instanceName,
            request.blobDigests
        );
        
        // Encode response using proper protobuf format
        ReapiFindMissingBlobsResponse response;
        response.missingBlobDigests = missing;
        
        return Ok!(ubyte[], string)(ReapiV2Codec.encodeFindMissingBlobsResponse(response));
    }
    
    private Result!(ubyte[], string) routeBatchUpdate(string instanceName, const ubyte[] body_) @trusted {
        // Decode BatchUpdateBlobsRequest
        auto reqResult = ReapiV2Codec.decodeBatchUpdateBlobsRequest(body_);
        if (reqResult.isErr)
            return Err!(ubyte[], string)("Invalid BatchUpdateBlobs request: " ~ reqResult.unwrapErr());
        
        auto request = reqResult.unwrap();
        
        // Perform batch update
        auto responses = services.cas.batchUpdateBlobs(
            request.instanceName.length > 0 ? request.instanceName : instanceName,
            request.requests
        );
        
        // Encode response using proper protobuf format
        ReapiBatchUpdateBlobsResponse response;
        response.responses = responses;
        
        return Ok!(ubyte[], string)(ReapiV2Codec.encodeBatchUpdateBlobsResponse(response));
    }
    
    private Result!(ubyte[], string) routeBatchRead(string instanceName, const ubyte[] body_) @trusted {
        // Decode BatchReadBlobsRequest
        auto reqResult = ReapiV2Codec.decodeBatchReadBlobsRequest(body_);
        if (reqResult.isErr)
            return Err!(ubyte[], string)("Invalid BatchReadBlobs request: " ~ reqResult.unwrapErr());
        
        auto request = reqResult.unwrap();
        
        // Perform batch read
        auto responses = services.cas.batchReadBlobs(
            request.instanceName.length > 0 ? request.instanceName : instanceName,
            request.digests
        );
        
        // Encode response using proper protobuf format
        ReapiBatchReadBlobsResponse response;
        response.responses = responses;
        
        return Ok!(ubyte[], string)(ReapiV2Codec.encodeBatchReadBlobsResponse(response));
    }
    
    private Result!(ubyte[], string) routeBlobAccess(
        string method, string path, string instanceName, const ubyte[] body_
    ) @trusted {
        import std.string : indexOf;
        import std.conv : to;
        
        // Parse: /v2/{instance}/blobs/{hash}/{size}
        auto blobsIdx = path.indexOf("/blobs/");
        if (blobsIdx < 0)
            return Err!(ubyte[], string)("Invalid blob path");
        
        auto blobPath = path[blobsIdx + 7 .. $];
        auto slashIdx = blobPath.indexOf('/');
        if (slashIdx < 0)
            return Err!(ubyte[], string)("Invalid blob path format");
        
        auto hashStr = blobPath[0 .. slashIdx];
        auto sizeStr = blobPath[slashIdx + 1 .. $];
        
        long size;
        try { size = sizeStr.to!long; } catch (Exception) {}
        
        auto digest = ReapiDigest.fromHex(hashStr, size);
        
        if (method == "GET") {
            auto data = (cast(ContentAddressableStorageService)services.cas).getBlob(digest);
            if (data.length == 0)
                return Err!(ubyte[], string)("Blob not found");
            return Ok!(ubyte[], string)(data);
        }
        
        if (method == "PUT") {
            (cast(ContentAddressableStorageService)services.cas).putBlob(digest, body_);
            return Ok!(ubyte[], string)([]);
        }
        
        return Err!(ubyte[], string)("Unsupported method: " ~ method);
    }
    
    private Result!(ubyte[], string) routeOperation(
        string method, string path, const ubyte[] body_
    ) @trusted {
        import std.string : indexOf;
        
        // Extract operation name
        auto opStart = path.indexOf("/operations/");
        if (opStart < 0)
            return Err!(ubyte[], string)("Invalid operation path");
        
        auto opName = path[opStart + 1 .. $];  // Include "operations/"
        
        if (method == "GET") {
            auto result = services.execution.waitExecution(opName, 0.seconds);
            if (result.isErr)
                return Err!(ubyte[], string)(result.unwrapErr().message());
            
            auto op = result.unwrap();
            
            // Encode operation
            ubyte[] buf;
            buf ~= ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.LengthDelimited);
            buf ~= ReapiV2Codec.encodeVarint(op.name.length);
            buf ~= cast(ubyte[])op.name;
            
            if (op.done) {
                buf ~= ReapiV2Codec.makeTag(2, ReapiV2Codec.WireType.Varint);
                buf ~= 0x01;
            }
            
            return Ok!(ubyte[], string)(buf);
        }
        
        if (method == "DELETE") {
            auto result = services.execution.cancelOperation(opName);
            if (result.isErr)
                return Err!(ubyte[], string)(result.unwrapErr().message());
            return Ok!(ubyte[], string)([]);
        }
        
        return Err!(ubyte[], string)("Unsupported method: " ~ method);
    }
}

