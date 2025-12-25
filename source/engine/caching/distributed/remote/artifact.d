module engine.caching.distributed.remote.artifact;

import std.datetime : Duration;
import infrastructure.errors;

/**
 * Artifact Transport Interface
 * 
 * Unified interface for artifact storage operations supporting both
 * HTTP/1.1 and gRPC/HTTP2 transports. Enables transport-agnostic
 * artifact caching with optimal performance characteristics.
 */
interface ArtifactTransport {
    /// Fetch artifact by content hash
    BuildResult!(ubyte[]) get(string contentHash) @trusted;
    
    /// Store artifact with content hash
    VoidBuildResult put(string contentHash, const(ubyte)[] data) @trusted;
    
    /// Check artifact existence
    BuildResult!bool has(string contentHash) @trusted;
    
    /// Delete artifact (if supported)
    VoidBuildResult remove(string contentHash) @trusted;
    
    /// Close transport and release resources
    void close() @trusted;
    
    /// Check connection status
    bool isConnected() @trusted;
    
    /// Get transport capabilities
    TransportCapabilities capabilities() const @safe;
}

/// Transport capability flags
struct TransportCapabilities {
    bool supportsStreaming;       // ByteStream for large blobs
    bool supportsMultiplexing;    // HTTP/2 stream multiplexing
    bool supportsCompression;     // Wire-level compression
    bool supportsBatchOps;        // Batch read/write operations
    size_t maxMessageSize;        // Maximum single message size
    uint maxConcurrentStreams;    // HTTP/2 concurrent streams
    
    /// Default HTTP/1.1 capabilities
    static TransportCapabilities http() @safe => TransportCapabilities(
        false, false, true, false, 100 * 1024 * 1024, 1
    );
    
    /// gRPC/HTTP2 capabilities
    static TransportCapabilities grpc() @safe => TransportCapabilities(
        true, true, true, true, 4 * 1024 * 1024, 100
    );
}

/// Streaming upload/download callback
alias StreamCallback = void delegate(const ubyte[] chunk, size_t offset, size_t total) @safe;

/**
 * Extended Artifact Transport with Streaming Support
 * 
 * For gRPC transports supporting ByteStream service,
 * enables efficient large blob transfers via HTTP/2 streams.
 */
interface StreamingArtifactTransport : ArtifactTransport {
    /// Read blob via streaming (for large artifacts)
    BuildResult!size_t readStream(
        string resourceName,
        size_t offset,
        size_t limit,
        StreamCallback onData
    ) @trusted;
    
    /// Write blob via streaming (for large artifacts)
    BuildResult!string writeStream(
        string resourceName,
        bool finishWrite,
        const(ubyte)[] data,
        size_t writeOffset = 0
    ) @trusted;
    
    /// Query write status
    BuildResult!size_t queryWriteStatus(string resourceName) @trusted;
}

/**
 * Batch Operations Interface
 * 
 * For REAPI CAS batch operations, enables efficient
 * bulk artifact transfer with single round-trip.
 */
interface BatchArtifactTransport : ArtifactTransport {
    /// Find missing blobs (digests not in CAS)
    BuildResult!(string[]) findMissing(string[] digests) @trusted;
    
    /// Batch upload multiple blobs
    BuildResult!(UploadResult[]) batchUpload(BlobUpload[] blobs) @trusted;
    
    /// Batch download multiple blobs
    BuildResult!(ubyte[][]) batchDownload(string[] digests) @trusted;
}

/// Single blob upload request
struct BlobUpload {
    string digest;
    ubyte[] data;
}

/// Upload result for batch operations
struct UploadResult {
    string digest;
    bool success;
    string error;
}

/// Transfer statistics for monitoring
struct TransferStats {
    size_t bytesTransferred;
    size_t chunksTransferred;
    size_t totalChunks;
    size_t bytesSaved;       // Deduplication savings
    Duration duration;
    
    /// Compute savings percentage
    double savingsPercent() const pure @safe =>
        (totalChunks > 0) ? (100.0 * bytesSaved / (bytesTransferred + bytesSaved)) : 0.0;
    
    /// Compute throughput (bytes/sec)
    double throughput() const @trusted =>
        duration.total!"msecs" > 0 ? (bytesTransferred * 1000.0 / duration.total!"msecs") : 0.0;
}


