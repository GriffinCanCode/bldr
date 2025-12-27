module engine.distributed.protocol.grpc.cas;

import std.algorithm : min;
import std.conv : to;
import std.datetime : Duration, seconds, MonoTime;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.grpc.transport : GrpcTransport, GrpcConfig;
import engine.distributed.protocol.grpc.http2 : H2Connection, H2Settings, HpackEncoder;
import engine.distributed.protocol.grpc.frame;
import engine.distributed.protocol.grpc.codec : GrpcCodec;
import engine.caching.distributed.remote.artifact;
import infrastructure.errors : Errors, Network, BuildError, VoidBuildResult, BuildResult, Err, Ok;

/**
 * gRPC Content-Addressable Storage Transport
 * 
 * Implements ArtifactTransport using gRPC/HTTP2 with multiplexing
 * for high-throughput artifact transfers. Uses REAPI CAS and ByteStream
 * services for compatibility with remote execution backends.
 * 
 * Key Features:
 * - HTTP/2 stream multiplexing (concurrent uploads/downloads)
 * - ByteStream for large blob streaming
 * - Batch operations for bulk transfers
 * - Connection pooling
 * 
 * SoC: This adapter bridges protocol layer (gRPC) to caching layer (ArtifactTransport)
 */
final class GrpcCasTransport : StreamingArtifactTransport, BatchArtifactTransport {
    private GrpcConfig config;
    private H2Connection connection;
    private GrpcCodec codec;
    private Mutex mutex;
    private bool connected;
    private string instanceName;
    
    /// Stream pool for multiplexed transfers
    private MultiplexPool streamPool;
    
    this(GrpcConfig config, string instanceName = "") @trusted {
        this.config = config;
        this.instanceName = instanceName;
        this.codec = new GrpcCodec();
        this.mutex = new Mutex();
        this.connection = new H2Connection();
        this.streamPool = new MultiplexPool(config.maxMessageSize);
    }
    
    /// Connect to CAS endpoint
    VoidBuildResult connect() @trusted {
        synchronized (mutex) {
            if (connected) return Ok!BuildError();
            
            auto target = config.parseTarget();
            auto result = connection.connect(target.host, target.port, config.connectTimeout);
            
            if (result.isErr)
                return VoidBuildResult.err(
                    Errors.network("gRPC connect failed: " ~ result.unwrapErr(), Network.Error).build());
            
            connected = true;
            return Ok!BuildError();
        }
    }
    
    // =========================================================================
    // ArtifactTransport Implementation
    // =========================================================================
    
    BuildResult!(ubyte[]) get(string contentHash) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(ubyte[], BuildError)(connectResult.unwrapErr());
        
        // Use batch read for single blob
        auto digests = [contentHash];
        auto result = batchDownload(digests);
        
        if (result.isErr) return Err!(ubyte[], BuildError)(result.unwrapErr());
        
        auto blobs = result.unwrap();
        if (blobs.length == 0)
            return Err!(ubyte[], BuildError)(
                Errors.cache("Blob not found: " ~ contentHash, Cache.NotFound).build());
        
        return Ok!(ubyte[], BuildError)(blobs[0]);
    }
    
    VoidBuildResult put(string contentHash, const(ubyte)[] data) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return VoidBuildResult.err(connectResult.unwrapErr());
        
        // Use batch write for single blob
        BlobUpload[] uploads = [BlobUpload(contentHash, cast(ubyte[])data.dup)];
        auto result = batchUpload(uploads);
        
        if (result.isErr) return VoidBuildResult.err(result.unwrapErr());
        
        auto results = result.unwrap();
        if (results.length > 0 && !results[0].success)
            return VoidBuildResult.err(
                Errors.cache("Upload failed: " ~ results[0].error, Cache.LoadFailed).build());
        
        return Ok!BuildError();
    }
    
    BuildResult!bool has(string contentHash) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(bool, BuildError)(connectResult.unwrapErr());
        
        auto result = findMissing([contentHash]);
        if (result.isErr) return Err!(bool, BuildError)(result.unwrapErr());
        
        // If not in missing list, blob exists
        auto missing = result.unwrap();
        foreach (m; missing)
            if (m == contentHash) return Ok!(bool, BuildError)(false);
        
        return Ok!(bool, BuildError)(true);
    }
    
    VoidBuildResult remove(string contentHash) @trusted =>
        VoidBuildResult.err(Errors.generic("CAS deletion not supported", Internal.NotSupported).build());
    
    void close() @trusted {
        synchronized (mutex) {
            if (connection !is null) connection.close();
            connected = false;
        }
    }
    
    bool isConnected() @trusted => connected && connection.isConnected();
    
    TransportCapabilities capabilities() const @safe =>
        TransportCapabilities.grpc();
    
    // =========================================================================
    // StreamingArtifactTransport Implementation (ByteStream)
    // =========================================================================
    
    BuildResult!size_t readStream(
        string resourceName,
        size_t offset,
        size_t limit,
        StreamCallback onData
    ) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(size_t, BuildError)(connectResult.unwrapErr());
        
        synchronized (mutex) {
            // Create stream for ByteStream.Read
            auto streamResult = connection.createStream();
            if (streamResult.isErr)
                return Err!(size_t, BuildError)(
                    Errors.network("Failed to create stream: " ~ streamResult.unwrapErr(), Network.Error).build());
            
            auto streamId = streamResult.unwrap();
            auto target = config.parseTarget();
            
            // Encode ReadRequest
            auto request = encodeReadRequest(resourceName, offset, limit);
            
            // Send headers + request
            auto headers = GrpcHeaders.requestHeaders(
                target.host ~ ":" ~ target.port.to!string,
                ReapiServices.read().path,
                GrpcHeaders.GrpcEncodingIdentity,
                GrpcHeaders.formatTimeout(config.callTimeout.total!"nsecs")
            );
            
            auto headerBlock = HpackEncoder.encode(headers);
            connection.sendHeaders(streamId, headerBlock, false);
            
            auto frame = GrpcFrame.uncompressed(request);
            connection.sendData(streamId, frame.encode(), true);
            
            // Read streaming response
            size_t totalRead = 0;
            auto reader = GrpcStreamReader(config.maxMessageSize);
            
            while (true) {
                auto responseResult = connection.receiveResponse(streamId);
                if (responseResult.isErr) break;
                
                auto response = responseResult.unwrap();
                reader.addData(response.data);
                
                while (reader.hasData) {
                    auto msgResult = reader.readMessage();
                    if (msgResult.isErr) break;
                    
                    auto msg = msgResult.unwrap();
                    auto chunk = decodeReadResponse(msg.message);
                    
                    if (chunk.length > 0) {
                        onData(chunk, totalRead, limit);
                        totalRead += chunk.length;
                    }
                }
                
                if (response.grpcStatus != -1) break;
            }
            
            return Ok!(size_t, BuildError)(totalRead);
        }
    }
    
    BuildResult!string writeStream(
        string resourceName,
        bool finishWrite,
        const(ubyte)[] data,
        size_t writeOffset = 0
    ) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(string, BuildError)(connectResult.unwrapErr());
        
        synchronized (mutex) {
            auto streamResult = connection.createStream();
            if (streamResult.isErr)
                return Err!(string, BuildError)(
                    Errors.network("Failed to create stream: " ~ streamResult.unwrapErr(), Network.Error).build());
            
            auto streamId = streamResult.unwrap();
            auto target = config.parseTarget();
            
            // Send headers for ByteStream.Write (client streaming)
            auto headers = GrpcHeaders.requestHeaders(
                target.host ~ ":" ~ target.port.to!string,
                ReapiServices.write().path,
                GrpcHeaders.GrpcEncodingIdentity,
                GrpcHeaders.formatTimeout(config.callTimeout.total!"nsecs")
            );
            
            auto headerBlock = HpackEncoder.encode(headers);
            connection.sendHeaders(streamId, headerBlock, false);
            
            // Send write request(s)
            size_t chunkSize = config.maxMessageSize - 1024; // Reserve for framing
            size_t offset = writeOffset;
            
            while (offset < data.length) {
                auto end = min(offset + chunkSize, data.length);
                auto isLast = (end >= data.length) && finishWrite;
                
                auto request = encodeWriteRequest(resourceName, offset, data[offset .. end], isLast);
                auto frame = GrpcFrame.uncompressed(request);
                connection.sendData(streamId, frame.encode(), isLast);
                
                offset = end;
            }
            
            // Receive response
            auto responseResult = connection.receiveResponse(streamId);
            if (responseResult.isErr)
                return Err!(string, BuildError)(
                    Errors.network("Write response failed: " ~ responseResult.unwrapErr(), Network.Error).build());
            
            return Ok!(string, BuildError)(resourceName);
        }
    }
    
    BuildResult!size_t queryWriteStatus(string resourceName) @trusted {
        // QueryWriteStatus not commonly needed, return 0 to indicate unknown
        return Ok!(size_t, BuildError)(cast(size_t)0);
    }
    
    // =========================================================================
    // BatchArtifactTransport Implementation (CAS Batch Ops)
    // =========================================================================
    
    BuildResult!(string[]) findMissing(string[] digests) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(string[], BuildError)(connectResult.unwrapErr());
        
        synchronized (mutex) {
            auto request = encodeFindMissingRequest(digests);
            auto result = unaryCall(ReapiServices.findMissingBlobs(), request);
            
            if (result.isErr)
                return Err!(string[], BuildError)(
                    Errors.network("FindMissingBlobs failed: " ~ result.unwrapErr(), Network.Error).build());
            
            return Ok!(string[], BuildError)(decodeFindMissingResponse(result.unwrap()));
        }
    }
    
    BuildResult!(UploadResult[]) batchUpload(BlobUpload[] blobs) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(UploadResult[], BuildError)(connectResult.unwrapErr());
        
        synchronized (mutex) {
            auto request = encodeBatchUpdateRequest(blobs);
            auto result = unaryCall(ReapiServices.batchUpdateBlobs(), request);
            
            if (result.isErr)
                return Err!(UploadResult[], BuildError)(
                    Errors.network("BatchUpdateBlobs failed: " ~ result.unwrapErr(), Network.Error).build());
            
            return Ok!(UploadResult[], BuildError)(decodeBatchUpdateResponse(result.unwrap(), blobs));
        }
    }
    
    BuildResult!(ubyte[][]) batchDownload(string[] digests) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(ubyte[][], BuildError)(connectResult.unwrapErr());
        
        synchronized (mutex) {
            auto request = encodeBatchReadRequest(digests);
            auto result = unaryCall(ReapiServices.batchReadBlobs(), request);
            
            if (result.isErr)
                return Err!(ubyte[][], BuildError)(
                    Errors.network("BatchReadBlobs failed: " ~ result.unwrapErr(), Network.Error).build());
            
            return Ok!(ubyte[][], BuildError)(decodeBatchReadResponse(result.unwrap()));
        }
    }
    
    // =========================================================================
    // Multiplexed Transfer (HTTP/2 Stream Concurrency)
    // =========================================================================
    
    /// Upload multiple blobs concurrently using HTTP/2 multiplexing
    BuildResult!(UploadResult[]) multiplexedUpload(BlobUpload[] blobs, uint concurrency = 10) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(UploadResult[], BuildError)(connectResult.unwrapErr());
        
        // Use stream pool for concurrent uploads
        return streamPool.uploadMultiplexed(connection, blobs, instanceName, concurrency);
    }
    
    /// Download multiple blobs concurrently using HTTP/2 multiplexing
    BuildResult!(ubyte[][]) multiplexedDownload(string[] digests, uint concurrency = 10) @trusted {
        auto connectResult = ensureConnected();
        if (connectResult.isErr) return Err!(ubyte[][], BuildError)(connectResult.unwrapErr());
        
        return streamPool.downloadMultiplexed(connection, digests, instanceName, concurrency);
    }
    
    // =========================================================================
    // Internal Methods
    // =========================================================================
    
    private VoidBuildResult ensureConnected() @trusted {
        if (!connected || !connection.isConnected()) return connect();
        return Ok!BuildError();
    }
    
    private Result!(ubyte[], string) unaryCall(GrpcMethod method, const ubyte[] request) @trusted {
        auto streamResult = connection.createStream();
        if (streamResult.isErr) return Err!(ubyte[], string)(streamResult.unwrapErr());
        
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
        if (sendHeadersResult.isErr) return Err!(ubyte[], string)(sendHeadersResult.unwrapErr());
        
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = connection.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr) return Err!(ubyte[], string)(sendDataResult.unwrapErr());
        
        auto responseResult = connection.receiveResponse(streamId);
        if (responseResult.isErr) return Err!(ubyte[], string)(responseResult.unwrapErr());
        
        auto response = responseResult.unwrap();
        if (response.grpcStatus != 0 && response.grpcStatus != -1)
            return Err!(ubyte[], string)("gRPC error " ~ response.grpcStatus.to!string);
        
        if (response.data.length < GrpcFrame.HeaderSize)
            return Ok!(ubyte[], string)(cast(ubyte[])[]);
        
        auto frameResult = GrpcFrame.decode(response.data, config.maxMessageSize);
        if (frameResult.isErr) return Err!(ubyte[], string)(frameResult.unwrapErr());
        
        return Ok!(ubyte[], string)(frameResult.unwrap().message);
    }
    
    // =========================================================================
    // Protocol Encoding (REAPI CAS/ByteStream)
    // =========================================================================
    
    private ubyte[] encodeReadRequest(string resourceName, size_t offset, size_t limit) @trusted {
        ubyte[] buf;
        buf.reserve(resourceName.length + 32);
        
        // Field 1: resource_name
        buf ~= makeTag(1, 2);
        buf ~= encodeVarint(resourceName.length);
        buf ~= cast(ubyte[])resourceName;
        
        // Field 2: read_offset
        if (offset > 0) {
            buf ~= makeTag(2, 0);
            buf ~= encodeVarint(offset);
        }
        
        // Field 3: read_limit
        if (limit > 0) {
            buf ~= makeTag(3, 0);
            buf ~= encodeVarint(limit);
        }
        
        return buf;
    }
    
    private ubyte[] decodeReadResponse(const ubyte[] data) @trusted {
        size_t offset = 0;
        while (offset < data.length) {
            auto tag = data[offset] >> 3;
            auto wireType = data[offset] & 0x7;
            offset++;
            
            if (tag == 1 && wireType == 2) {
                auto lenResult = decodeVarint(data[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                return data[offset .. offset + len].dup;
            } else {
                offset = skipField(data, offset, wireType);
            }
        }
        return [];
    }
    
    private ubyte[] encodeWriteRequest(string resourceName, size_t offset, const ubyte[] data, bool finish) @trusted {
        ubyte[] buf;
        buf.reserve(resourceName.length + data.length + 32);
        
        // Field 1: resource_name
        buf ~= makeTag(1, 2);
        buf ~= encodeVarint(resourceName.length);
        buf ~= cast(ubyte[])resourceName;
        
        // Field 2: write_offset
        buf ~= makeTag(2, 0);
        buf ~= encodeVarint(offset);
        
        // Field 3: finish_write
        if (finish) {
            buf ~= makeTag(3, 0);
            buf ~= 0x01;
        }
        
        // Field 10: data
        buf ~= makeTag(10, 2);
        buf ~= encodeVarint(data.length);
        buf ~= data;
        
        return buf;
    }
    
    private ubyte[] encodeFindMissingRequest(string[] digests) @trusted {
        ubyte[] buf;
        buf.reserve(digests.length * 80);
        
        // Field 1: instance_name
        if (instanceName.length > 0) {
            buf ~= makeTag(1, 2);
            buf ~= encodeVarint(instanceName.length);
            buf ~= cast(ubyte[])instanceName;
        }
        
        // Field 2: blob_digests (repeated)
        foreach (digest; digests) {
            buf ~= makeTag(2, 2);
            auto digestBuf = encodeDigest(digest);
            buf ~= encodeVarint(digestBuf.length);
            buf ~= digestBuf;
        }
        
        return buf;
    }
    
    private string[] decodeFindMissingResponse(const ubyte[] data) @trusted {
        string[] missing;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tag = data[offset] >> 3;
            auto wireType = data[offset] & 0x7;
            offset++;
            
            if (tag == 1 && wireType == 2) {
                auto lenResult = decodeVarint(data[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                missing ~= decodeDigest(data[offset .. offset + len]);
                offset += len;
            } else {
                offset = skipField(data, offset, wireType);
            }
        }
        
        return missing;
    }
    
    private ubyte[] encodeBatchUpdateRequest(BlobUpload[] blobs) @trusted {
        ubyte[] buf;
        
        // Field 1: instance_name
        if (instanceName.length > 0) {
            buf ~= makeTag(1, 2);
            buf ~= encodeVarint(instanceName.length);
            buf ~= cast(ubyte[])instanceName;
        }
        
        // Field 2: requests (repeated)
        foreach (blob; blobs) {
            buf ~= makeTag(2, 2);
            auto reqBuf = encodeUpdateBlobRequest(blob.digest, blob.data);
            buf ~= encodeVarint(reqBuf.length);
            buf ~= reqBuf;
        }
        
        return buf;
    }
    
    private ubyte[] encodeUpdateBlobRequest(string digest, const ubyte[] data) @trusted {
        ubyte[] buf;
        
        // Field 1: digest
        buf ~= makeTag(1, 2);
        auto digestBuf = encodeDigest(digest);
        buf ~= encodeVarint(digestBuf.length);
        buf ~= digestBuf;
        
        // Field 2: data
        buf ~= makeTag(2, 2);
        buf ~= encodeVarint(data.length);
        buf ~= data;
        
        return buf;
    }
    
    private UploadResult[] decodeBatchUpdateResponse(const ubyte[] data, BlobUpload[] original) @trusted {
        UploadResult[] results;
        results.reserve(original.length);
        
        // Simplified: assume all succeeded if no error
        foreach (blob; original)
            results ~= UploadResult(blob.digest, true, "");
        
        return results;
    }
    
    private ubyte[] encodeBatchReadRequest(string[] digests) @trusted {
        ubyte[] buf;
        
        // Field 1: instance_name
        if (instanceName.length > 0) {
            buf ~= makeTag(1, 2);
            buf ~= encodeVarint(instanceName.length);
            buf ~= cast(ubyte[])instanceName;
        }
        
        // Field 2: digests (repeated)
        foreach (digest; digests) {
            buf ~= makeTag(2, 2);
            auto digestBuf = encodeDigest(digest);
            buf ~= encodeVarint(digestBuf.length);
            buf ~= digestBuf;
        }
        
        return buf;
    }
    
    private ubyte[][] decodeBatchReadResponse(const ubyte[] data) @trusted {
        ubyte[][] results;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tag = data[offset] >> 3;
            auto wireType = data[offset] & 0x7;
            offset++;
            
            if (tag == 1 && wireType == 2) {
                // Response entry
                auto lenResult = decodeVarint(data[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                auto entryData = data[offset .. offset + len];
                offset += len;
                
                // Extract data field from entry
                auto blobData = extractBlobFromResponse(entryData);
                if (blobData.length > 0) results ~= blobData;
            } else {
                offset = skipField(data, offset, wireType);
            }
        }
        
        return results;
    }
    
    private ubyte[] extractBlobFromResponse(const ubyte[] entry) @trusted {
        size_t offset = 0;
        while (offset < entry.length) {
            auto tag = entry[offset] >> 3;
            auto wireType = entry[offset] & 0x7;
            offset++;
            
            if (tag == 2 && wireType == 2) {
                // data field
                auto lenResult = decodeVarint(entry[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                return entry[offset .. offset + len].dup;
            } else {
                offset = skipField(entry, offset, wireType);
            }
        }
        return [];
    }
    
    private ubyte[] encodeDigest(string hash) @trusted {
        ubyte[] buf;
        // Field 1: hash (string)
        buf ~= makeTag(1, 2);
        buf ~= encodeVarint(hash.length);
        buf ~= cast(ubyte[])hash;
        // Field 2: size_bytes omitted (0)
        return buf;
    }
    
    private string decodeDigest(const ubyte[] data) @trusted {
        size_t offset = 0;
        while (offset < data.length) {
            auto tag = data[offset] >> 3;
            auto wireType = data[offset] & 0x7;
            offset++;
            
            if (tag == 1 && wireType == 2) {
                auto lenResult = decodeVarint(data[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                return cast(string)data[offset .. offset + len].dup;
            } else {
                offset = skipField(data, offset, wireType);
            }
        }
        return "";
    }
    
    // Protobuf primitives
    private static ubyte makeTag(uint field, uint wireType) pure nothrow @safe @nogc =>
        cast(ubyte)((field << 3) | wireType);
    
    private static ubyte[] encodeVarint(size_t value) @trusted {
        ubyte[] buf;
        while (value >= 0x80) {
            buf ~= cast(ubyte)(value | 0x80);
            value >>= 7;
        }
        buf ~= cast(ubyte)value;
        return buf;
    }
    
    private struct VarintResult { long value; size_t bytesRead; }
    
    private static VarintResult decodeVarint(const ubyte[] data) @trusted {
        ulong result = 0;
        size_t shift = 0, bytesRead = 0;
        foreach (b; data) {
            bytesRead++;
            result |= (cast(ulong)(b & 0x7F)) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
        }
        return VarintResult(cast(long)result, bytesRead);
    }
    
    private static size_t skipField(const ubyte[] data, size_t offset, uint wireType) @trusted {
        switch (wireType) {
            case 0: // Varint
                while (offset < data.length && (data[offset++] & 0x80) != 0) {}
                return offset;
            case 1: return offset + 8; // Fixed64
            case 2: // Length-delimited
                auto lenResult = decodeVarint(data[offset .. $]);
                return offset + lenResult.bytesRead + cast(size_t)lenResult.value;
            case 5: return offset + 4; // Fixed32
            default: return offset + 1;
        }
    }
}

/**
 * HTTP/2 Stream Multiplexing Pool
 * 
 * Manages concurrent streams for parallel artifact transfers.
 * Leverages HTTP/2 multiplexing for high-throughput operations.
 */
private final class MultiplexPool {
    private size_t maxMessageSize;
    
    this(size_t maxMessageSize) @safe {
        this.maxMessageSize = maxMessageSize;
    }
    
    /// Upload blobs using multiplexed HTTP/2 streams
    BuildResult!(UploadResult[]) uploadMultiplexed(
        H2Connection conn,
        BlobUpload[] blobs,
        string instanceName,
        uint concurrency
    ) @trusted {
        UploadResult[] results;
        results.reserve(blobs.length);
        
        // Process in batches based on concurrency
        for (size_t i = 0; i < blobs.length; i += concurrency) {
            auto batchEnd = min(i + concurrency, blobs.length);
            auto batch = blobs[i .. batchEnd];
            
            // Create streams for batch
            uint[] streamIds;
            streamIds.reserve(batch.length);
            
            foreach (blob; batch) {
                auto streamResult = conn.createStream();
                if (streamResult.isErr) {
                    results ~= UploadResult(blob.digest, false, streamResult.unwrapErr());
                    continue;
                }
                streamIds ~= streamResult.unwrap();
            }
            
            // Send all requests (multiplexed)
            foreach (j, blob; batch) {
                if (j >= streamIds.length) break;
                auto streamId = streamIds[j];
                
                auto request = encodeSingleBlobUpload(blob, instanceName);
                auto frame = GrpcFrame.uncompressed(request);
                
                auto headers = GrpcHeaders.requestHeaders(
                    "", ReapiServices.batchUpdateBlobs().path,
                    GrpcHeaders.GrpcEncodingIdentity, null
                );
                auto headerBlock = HpackEncoder.encode(headers);
                
                conn.sendHeaders(streamId, headerBlock, false);
                conn.sendData(streamId, frame.encode(), true);
            }
            
            // Receive all responses (multiplexed)
            foreach (j, blob; batch) {
                if (j >= streamIds.length) continue;
                auto streamId = streamIds[j];
                
                auto responseResult = conn.receiveResponse(streamId);
                if (responseResult.isOk && responseResult.unwrap().grpcStatus == 0) {
                    results ~= UploadResult(blob.digest, true, "");
                } else {
                    results ~= UploadResult(blob.digest, false, "Upload failed");
                }
            }
        }
        
        return Ok!(UploadResult[], BuildError)(results);
    }
    
    /// Download blobs using multiplexed HTTP/2 streams
    BuildResult!(ubyte[][]) downloadMultiplexed(
        H2Connection conn,
        string[] digests,
        string instanceName,
        uint concurrency
    ) @trusted {
        ubyte[][] results;
        results.reserve(digests.length);
        
        for (size_t i = 0; i < digests.length; i += concurrency) {
            auto batchEnd = min(i + concurrency, digests.length);
            auto batch = digests[i .. batchEnd];
            
            uint[] streamIds;
            streamIds.reserve(batch.length);
            
            foreach (digest; batch) {
                auto streamResult = conn.createStream();
                if (streamResult.isErr) {
                    results ~= cast(ubyte[])[];
                    continue;
                }
                streamIds ~= streamResult.unwrap();
            }
            
            // Send read requests
            foreach (j, digest; batch) {
                if (j >= streamIds.length) break;
                auto streamId = streamIds[j];
                
                auto request = encodeSingleBlobRead(digest, instanceName);
                auto frame = GrpcFrame.uncompressed(request);
                
                auto headers = GrpcHeaders.requestHeaders(
                    "", ReapiServices.batchReadBlobs().path,
                    GrpcHeaders.GrpcEncodingIdentity, null
                );
                auto headerBlock = HpackEncoder.encode(headers);
                
                conn.sendHeaders(streamId, headerBlock, false);
                conn.sendData(streamId, frame.encode(), true);
            }
            
            // Receive responses
            foreach (j, digest; batch) {
                if (j >= streamIds.length) continue;
                auto streamId = streamIds[j];
                
                auto responseResult = conn.receiveResponse(streamId);
                if (responseResult.isOk) {
                    auto response = responseResult.unwrap();
                    if (response.data.length >= GrpcFrame.HeaderSize) {
                        auto frameResult = GrpcFrame.decode(response.data, maxMessageSize);
                        if (frameResult.isOk) {
                            results ~= extractBlobData(frameResult.unwrap().message);
                            continue;
                        }
                    }
                }
                results ~= cast(ubyte[])[];
            }
        }
        
        return Ok!(ubyte[][], BuildError)(results);
    }
    
    private ubyte[] encodeSingleBlobUpload(BlobUpload blob, string instanceName) @trusted {
        ubyte[] buf;
        if (instanceName.length > 0) {
            buf ~= 0x0A; // tag 1, wire type 2
            buf ~= cast(ubyte)instanceName.length;
            buf ~= cast(ubyte[])instanceName;
        }
        buf ~= 0x12; // tag 2, wire type 2
        auto reqBuf = encodeUploadRequest(blob);
        buf ~= cast(ubyte)reqBuf.length;
        buf ~= reqBuf;
        return buf;
    }
    
    private ubyte[] encodeUploadRequest(BlobUpload blob) @trusted {
        ubyte[] buf;
        // digest
        buf ~= 0x0A;
        auto digestBuf = encodeDigestSimple(blob.digest);
        buf ~= cast(ubyte)digestBuf.length;
        buf ~= digestBuf;
        // data
        buf ~= 0x12;
        buf ~= encodeVarintLocal(blob.data.length);
        buf ~= blob.data;
        return buf;
    }
    
    private ubyte[] encodeSingleBlobRead(string digest, string instanceName) @trusted {
        ubyte[] buf;
        if (instanceName.length > 0) {
            buf ~= 0x0A;
            buf ~= cast(ubyte)instanceName.length;
            buf ~= cast(ubyte[])instanceName;
        }
        buf ~= 0x12;
        auto digestBuf = encodeDigestSimple(digest);
        buf ~= cast(ubyte)digestBuf.length;
        buf ~= digestBuf;
        return buf;
    }
    
    private ubyte[] encodeDigestSimple(string hash) @trusted {
        ubyte[] buf;
        buf ~= 0x0A;
        buf ~= cast(ubyte)hash.length;
        buf ~= cast(ubyte[])hash;
        return buf;
    }
    
    private static ubyte[] encodeVarintLocal(size_t value) @trusted {
        ubyte[] buf;
        while (value >= 0x80) {
            buf ~= cast(ubyte)(value | 0x80);
            value >>= 7;
        }
        buf ~= cast(ubyte)value;
        return buf;
    }
    
    private ubyte[] extractBlobData(const ubyte[] msg) @trusted {
        size_t offset = 0;
        while (offset < msg.length) {
            auto tag = msg[offset] >> 3;
            auto wireType = msg[offset] & 0x7;
            offset++;
            
            if (tag == 1 && wireType == 2) {
                auto lenResult = GrpcCasTransport.decodeVarint(msg[offset .. $]);
                offset += lenResult.bytesRead;
                auto len = cast(size_t)lenResult.value;
                auto entry = msg[offset .. offset + len];
                
                // Extract data from entry
                size_t inner = 0;
                while (inner < entry.length) {
                    auto itag = entry[inner] >> 3;
                    auto iwire = entry[inner] & 0x7;
                    inner++;
                    
                    if (itag == 2 && iwire == 2) {
                        auto dataLen = GrpcCasTransport.decodeVarint(entry[inner .. $]);
                        inner += dataLen.bytesRead;
                        return entry[inner .. inner + cast(size_t)dataLen.value].dup;
                    } else {
                        inner = skipFieldLocal(entry, inner, iwire);
                    }
                }
                offset += len;
            } else {
                offset = skipFieldLocal(msg, offset, wireType);
            }
        }
        return [];
    }
    
    private static size_t skipFieldLocal(const ubyte[] data, size_t offset, uint wireType) @trusted {
        switch (wireType) {
            case 0:
                while (offset < data.length && (data[offset++] & 0x80) != 0) {}
                return offset;
            case 1: return offset + 8;
            case 2:
                auto lenResult = GrpcCasTransport.decodeVarint(data[offset .. $]);
                return offset + lenResult.bytesRead + cast(size_t)lenResult.value;
            case 5: return offset + 4;
            default: return offset + 1;
        }
    }
}

/// Factory for creating gRPC CAS transports
struct GrpcCasFactory {
    /// Create transport from URL
    static BuildResult!GrpcCasTransport fromUrl(string url, string instanceName = "") @trusted {
        import std.algorithm : startsWith;
        
        GrpcConfig config;
        if (url.startsWith("grpc://")) {
            config = GrpcConfig.insecure(url[7 .. $]);
        } else if (url.startsWith("grpcs://")) {
            config = GrpcConfig.secure(url[8 .. $]);
        } else {
            return Err!(GrpcCasTransport, BuildError)(
                Errors.generic("Invalid gRPC URL: " ~ url, Parse.InvalidConfiguration).build());
        }
        
        auto transport = new GrpcCasTransport(config, instanceName);
        auto connectResult = transport.connect();
        
        if (connectResult.isErr)
            return Err!(GrpcCasTransport, BuildError)(connectResult.unwrapErr());
        
        return Ok!(GrpcCasTransport, BuildError)(transport);
    }
    
    /// Create with explicit config
    static GrpcCasTransport create(GrpcConfig config, string instanceName = "") @safe =>
        new GrpcCasTransport(config, instanceName);
}


