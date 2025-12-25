module engine.distributed.protocol.reapi_v2.stream;

import std.datetime : Duration, seconds;
import std.conv : to;
import std.algorithm : min;
import engine.distributed.protocol.reapi_v2.types;
import engine.distributed.protocol.reapi_v2.codec;
import infrastructure.errors;

/**
 * ByteStream API Types and Implementation
 * 
 * Implements google.bytestream.v1 service for streaming blob I/O.
 * Used by REAPI for large blob transfers that exceed batch limits.
 * 
 * Resource names: {instance_name}/blobs/{hash}/{size}
 */

/// ByteStream read request
struct ByteStreamReadRequest {
    string resourceName;    // Resource to read: {instance}/blobs/{hash}/{size}
    long readOffset;        // Start offset (0 = beginning)
    long readLimit;         // Max bytes (0 = all)
}

/// ByteStream read response chunk
struct ByteStreamReadResponse {
    ubyte[] data;           // Chunk data
}

/// ByteStream write request chunk
struct ByteStreamWriteRequest {
    string resourceName;    // Resource to write (only first chunk)
    long writeOffset;       // Current offset
    bool finishWrite;       // Is this the final chunk?
    ubyte[] data;           // Chunk data
}

/// ByteStream write response
struct ByteStreamWriteResponse {
    long committedSize;     // Total bytes written
}

/// ByteStream query write status request
struct ByteStreamQueryWriteStatusRequest {
    string resourceName;
}

/// ByteStream query write status response
struct ByteStreamQueryWriteStatusResponse {
    long committedSize;
    bool complete;
}

/// Parse resource name into components
struct ResourceName {
    string instanceName;
    string hash;
    long size;
    
    /// Parse: {instance}/blobs/{hash}/{size}
    static Result!(ResourceName, string) parse(string resource) @trusted {
        import std.string : indexOf, split;
        import std.conv : to;
        
        auto blobsIdx = resource.indexOf("/blobs/");
        if (blobsIdx < 0)
            return Err!(ResourceName, string)("Invalid resource: missing /blobs/");
        
        ResourceName rn;
        rn.instanceName = blobsIdx > 0 ? resource[0 .. blobsIdx] : "";
        
        auto rest = resource[blobsIdx + 7 .. $];
        auto slashIdx = rest.indexOf('/');
        if (slashIdx < 0)
            return Err!(ResourceName, string)("Invalid resource: missing size");
        
        rn.hash = rest[0 .. slashIdx];
        
        try {
            rn.size = rest[slashIdx + 1 .. $].to!long;
        } catch (Exception) {
            return Err!(ResourceName, string)("Invalid resource: bad size");
        }
        
        return Ok!(ResourceName, string)(rn);
    }
    
    /// Create from digest
    static string fromDigest(string instanceName, ReapiDigest digest) @trusted =>
        (instanceName.length > 0 ? instanceName ~ "/" : "") ~
        "blobs/" ~ digest.hashString() ~ "/" ~ digest.sizeBytes.to!string;
    
    /// Convert to digest
    ReapiDigest toDigest() const @trusted =>
        ReapiDigest.fromHex(hash, size);
}

/**
 * ByteStream Codec
 * 
 * Protobuf encoding/decoding for ByteStream messages
 */
struct ByteStreamCodec {
    alias WireType = ReapiV2Codec.WireType;
    
    /// Encode ReadRequest
    static ubyte[] encodeReadRequest(ByteStreamReadRequest req) @trusted {
        ubyte[] buf;
        buf.reserve(256);
        
        // Field 1: resource_name
        if (req.resourceName.length > 0) {
            buf ~= ReapiV2Codec.makeTag(1, WireType.LengthDelimited);
            buf ~= ReapiV2Codec.encodeVarint(req.resourceName.length);
            buf ~= cast(ubyte[])req.resourceName;
        }
        
        // Field 2: read_offset
        if (req.readOffset != 0) {
            buf ~= ReapiV2Codec.makeTag(2, WireType.Varint);
            buf ~= ReapiV2Codec.encodeVarint(req.readOffset);
        }
        
        // Field 3: read_limit
        if (req.readLimit != 0) {
            buf ~= ReapiV2Codec.makeTag(3, WireType.Varint);
            buf ~= ReapiV2Codec.encodeVarint(req.readLimit);
        }
        
        return buf;
    }
    
    /// Decode ReadRequest
    static Result!(ByteStreamReadRequest, string) decodeReadRequest(const ubyte[] data) @trusted {
        ByteStreamReadRequest req;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = ReapiV2Codec.decodeTag(data[offset .. $]);
            if (tagResult.isErr) return Err!(ByteStreamReadRequest, string)(tagResult.unwrapErr());
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // resource_name
                    auto lenResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ByteStreamReadRequest, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    req.resourceName = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                case 2:  // read_offset
                    auto valResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ByteStreamReadRequest, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    req.readOffset = valResult.unwrap().value;
                    break;
                    
                case 3:  // read_limit
                    auto valResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ByteStreamReadRequest, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    req.readLimit = valResult.unwrap().value;
                    break;
                    
                default:
                    auto skipResult = ReapiV2Codec.skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) return Err!(ByteStreamReadRequest, string)(skipResult.unwrapErr());
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ByteStreamReadRequest, string)(req);
    }
    
    /// Encode ReadResponse
    static ubyte[] encodeReadResponse(ByteStreamReadResponse resp) @trusted {
        ubyte[] buf;
        buf.reserve(resp.data.length + 16);
        
        // Field 1: data
        if (resp.data.length > 0) {
            buf ~= ReapiV2Codec.makeTag(1, WireType.LengthDelimited);
            buf ~= ReapiV2Codec.encodeVarint(resp.data.length);
            buf ~= resp.data;
        }
        
        return buf;
    }
    
    /// Decode ReadResponse
    static Result!(ByteStreamReadResponse, string) decodeReadResponse(const ubyte[] data) @trusted {
        ByteStreamReadResponse resp;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = ReapiV2Codec.decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            if (tag.fieldNumber == 1) {  // data
                auto lenResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                if (lenResult.isErr) break;
                offset += lenResult.unwrap().bytesRead;
                auto len = cast(size_t)lenResult.unwrap().value;
                resp.data = data[offset .. offset + len].dup;
                offset += len;
            } else {
                auto skipResult = ReapiV2Codec.skipField(data[offset .. $], tag.wireType);
                if (skipResult.isErr) break;
                offset += skipResult.unwrap();
            }
        }
        
        return Ok!(ByteStreamReadResponse, string)(resp);
    }
    
    /// Encode WriteRequest
    static ubyte[] encodeWriteRequest(ByteStreamWriteRequest req) @trusted {
        ubyte[] buf;
        buf.reserve(req.data.length + 128);
        
        // Field 1: resource_name (only in first chunk)
        if (req.resourceName.length > 0) {
            buf ~= ReapiV2Codec.makeTag(1, WireType.LengthDelimited);
            buf ~= ReapiV2Codec.encodeVarint(req.resourceName.length);
            buf ~= cast(ubyte[])req.resourceName;
        }
        
        // Field 2: write_offset
        if (req.writeOffset != 0) {
            buf ~= ReapiV2Codec.makeTag(2, WireType.Varint);
            buf ~= ReapiV2Codec.encodeVarint(req.writeOffset);
        }
        
        // Field 3: finish_write
        if (req.finishWrite) {
            buf ~= ReapiV2Codec.makeTag(3, WireType.Varint);
            buf ~= 0x01;
        }
        
        // Field 10: data
        if (req.data.length > 0) {
            buf ~= ReapiV2Codec.makeTag(10, WireType.LengthDelimited);
            buf ~= ReapiV2Codec.encodeVarint(req.data.length);
            buf ~= req.data;
        }
        
        return buf;
    }
    
    /// Decode WriteRequest
    static Result!(ByteStreamWriteRequest, string) decodeWriteRequest(const ubyte[] data) @trusted {
        ByteStreamWriteRequest req;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = ReapiV2Codec.decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // resource_name
                    auto lenResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    req.resourceName = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                case 2:  // write_offset
                    auto valResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    req.writeOffset = valResult.unwrap().value;
                    break;
                    
                case 3:  // finish_write
                    auto valResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    req.finishWrite = valResult.unwrap().value != 0;
                    break;
                    
                case 10:  // data
                    auto lenResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    req.data = data[offset .. offset + len].dup;
                    offset += len;
                    break;
                    
                default:
                    auto skipResult = ReapiV2Codec.skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) break;
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ByteStreamWriteRequest, string)(req);
    }
    
    /// Encode WriteResponse
    static ubyte[] encodeWriteResponse(ByteStreamWriteResponse resp) @trusted {
        ubyte[] buf;
        
        // Field 1: committed_size
        buf ~= ReapiV2Codec.makeTag(1, WireType.Varint);
        buf ~= ReapiV2Codec.encodeVarint(resp.committedSize);
        
        return buf;
    }
    
    /// Decode WriteResponse
    static Result!(ByteStreamWriteResponse, string) decodeWriteResponse(const ubyte[] data) @trusted {
        ByteStreamWriteResponse resp;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = ReapiV2Codec.decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            if (tag.fieldNumber == 1) {  // committed_size
                auto valResult = ReapiV2Codec.decodeVarint(data[offset .. $]);
                if (valResult.isErr) break;
                offset += valResult.unwrap().bytesRead;
                resp.committedSize = valResult.unwrap().value;
            } else {
                auto skipResult = ReapiV2Codec.skipField(data[offset .. $], tag.wireType);
                if (skipResult.isErr) break;
                offset += skipResult.unwrap();
            }
        }
        
        return Ok!(ByteStreamWriteResponse, string)(resp);
    }
}

/// ByteStream service interface
interface IByteStreamService {
    /// Read blob (streaming response)
    Result!(ubyte[], string) read(ByteStreamReadRequest request) @safe;
    
    /// Write blob (streaming request)
    Result!(ByteStreamWriteResponse, string) write(ByteStreamWriteRequest[] chunks) @safe;
    
    /// Query write status
    Result!(ByteStreamQueryWriteStatusResponse, string) queryWriteStatus(
        ByteStreamQueryWriteStatusRequest request
    ) @safe;
}

/// Default chunk size for streaming (2MB)
enum size_t BYTESTREAM_CHUNK_SIZE = 2 * 1024 * 1024;

/**
 * ByteStream Service Implementation
 * 
 * Provides streaming blob I/O backed by CAS storage
 */
final class ByteStreamService : IByteStreamService {
    import engine.distributed.protocol.reapi_v2.services : ContentAddressableStorageService;
    
    private ContentAddressableStorageService cas;
    private size_t chunkSize;
    
    /// Pending writes (resource → accumulated data)
    private ubyte[][string] pendingWrites;
    
    this(ContentAddressableStorageService cas, size_t chunkSize = BYTESTREAM_CHUNK_SIZE) @safe {
        this.cas = cas;
        this.chunkSize = chunkSize;
    }
    
    /// Read blob with streaming
    Result!(ubyte[], string) read(ByteStreamReadRequest request) @trusted {
        auto rnResult = ResourceName.parse(request.resourceName);
        if (rnResult.isErr)
            return Err!(ubyte[], string)(rnResult.unwrapErr());
        
        auto rn = rnResult.unwrap();
        auto digest = rn.toDigest();
        
        // Get blob from CAS
        auto data = cas.getBlob(digest);
        if (data.length == 0)
            return Err!(ubyte[], string)("Blob not found: " ~ request.resourceName);
        
        // Apply offset and limit
        auto startOffset = min(cast(size_t)request.readOffset, data.length);
        auto endOffset = request.readLimit > 0 
            ? min(startOffset + cast(size_t)request.readLimit, data.length)
            : data.length;
        
        return Ok!(ubyte[], string)(data[startOffset .. endOffset]);
    }
    
    /// Write blob with streaming
    Result!(ByteStreamWriteResponse, string) write(ByteStreamWriteRequest[] chunks) @trusted {
        if (chunks.length == 0)
            return Err!(ByteStreamWriteResponse, string)("Empty write request");
        
        // First chunk must have resource name
        if (chunks[0].resourceName.length == 0)
            return Err!(ByteStreamWriteResponse, string)("First chunk missing resource name");
        
        auto resourceName = chunks[0].resourceName;
        
        // Accumulate data
        ubyte[] accumulated;
        size_t totalSize;
        foreach (chunk; chunks) {
            accumulated ~= chunk.data;
            totalSize += chunk.data.length;
        }
        
        // Verify final chunk sets finishWrite
        if (!chunks[$ - 1].finishWrite) {
            // Store for resumption
            pendingWrites[resourceName] = accumulated;
            
            ByteStreamWriteResponse resp;
            resp.committedSize = totalSize;
            return Ok!(ByteStreamWriteResponse, string)(resp);
        }
        
        // Parse resource name and store
        auto rnResult = ResourceName.parse(resourceName);
        if (rnResult.isErr)
            return Err!(ByteStreamWriteResponse, string)(rnResult.unwrapErr());
        
        auto rn = rnResult.unwrap();
        auto digest = rn.toDigest();
        
        // Verify size matches
        if (accumulated.length != rn.size)
            return Err!(ByteStreamWriteResponse, string)(
                "Size mismatch: expected " ~ rn.size.to!string ~ 
                ", got " ~ accumulated.length.to!string);
        
        // Store in CAS
        cas.putBlob(digest, accumulated);
        
        // Clear pending
        pendingWrites.remove(resourceName);
        
        ByteStreamWriteResponse resp;
        resp.committedSize = totalSize;
        return Ok!(ByteStreamWriteResponse, string)(resp);
    }
    
    /// Query write status
    Result!(ByteStreamQueryWriteStatusResponse, string) queryWriteStatus(
        ByteStreamQueryWriteStatusRequest request
    ) @trusted {
        ByteStreamQueryWriteStatusResponse resp;
        
        if (auto pending = request.resourceName in pendingWrites) {
            resp.committedSize = (*pending).length;
            resp.complete = false;
        } else {
            // Check if already complete in CAS
            auto rnResult = ResourceName.parse(request.resourceName);
            if (rnResult.isOk) {
                auto rn = rnResult.unwrap();
                if (cas.hasBlob(rn.toDigest())) {
                    resp.committedSize = rn.size;
                    resp.complete = true;
                }
            }
        }
        
        return Ok!(ByteStreamQueryWriteStatusResponse, string)(resp);
    }
    
    /// Generate read chunks for large blob
    static ByteStreamReadResponse[] generateReadChunks(
        const ubyte[] data, 
        size_t chunkSize = BYTESTREAM_CHUNK_SIZE
    ) @trusted {
        ByteStreamReadResponse[] chunks;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto end = min(offset + chunkSize, data.length);
            ByteStreamReadResponse chunk;
            chunk.data = data[offset .. end].dup;
            chunks ~= chunk;
            offset = end;
        }
        
        return chunks;
    }
    
    /// Generate write chunks for large blob
    static ByteStreamWriteRequest[] generateWriteChunks(
        string resourceName,
        const ubyte[] data,
        size_t chunkSize = BYTESTREAM_CHUNK_SIZE
    ) @trusted {
        ByteStreamWriteRequest[] chunks;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto end = min(offset + chunkSize, data.length);
            ByteStreamWriteRequest chunk;
            
            if (offset == 0)
                chunk.resourceName = resourceName;  // Only first chunk
            
            chunk.writeOffset = offset;
            chunk.data = data[offset .. end].dup;
            chunk.finishWrite = (end == data.length);
            
            chunks ~= chunk;
            offset = end;
        }
        
        return chunks;
    }
}

/**
 * ByteStream gRPC service methods
 */
struct ByteStreamServices {
    import engine.distributed.protocol.grpc.frame : GrpcMethod;
    
    static GrpcMethod read() @safe =>
        GrpcMethod("google.bytestream.ByteStream", "Read", false, true);
    
    static GrpcMethod write() @safe =>
        GrpcMethod("google.bytestream.ByteStream", "Write", true, false);
    
    static GrpcMethod queryWriteStatus() @safe =>
        GrpcMethod("google.bytestream.ByteStream", "QueryWriteStatus", false, false);
}

