module tests.unit.core.distributed.bytestream;

import std.stdio;
import std.datetime;
import std.conv;
import std.algorithm : map, equal;
import std.array : array;
import engine.distributed.protocol.reapi_v2.stream;
import engine.distributed.protocol.reapi_v2.types;
import engine.distributed.protocol.reapi_v2.codec;
import engine.distributed.protocol.reapi_v2.services;
import tests.harness;

// ==================== RESOURCE NAME TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Resource name parsing");
    
    auto result = ResourceName.parse("default/blobs/abc123def456/1024");
    
    Assert.isTrue(result.isOk);
    auto rn = result.unwrap();
    Assert.equal(rn.instanceName, "default");
    Assert.equal(rn.hash, "abc123def456");
    Assert.equal(rn.size, 1024);
    
    writeln("\x1b[32m  ✓ Resource name parsing works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Resource name without instance");
    
    auto result = ResourceName.parse("blobs/abc123/512");
    
    Assert.isTrue(result.isOk);
    auto rn = result.unwrap();
    Assert.equal(rn.instanceName, "");
    Assert.equal(rn.hash, "abc123");
    Assert.equal(rn.size, 512);
    
    writeln("\x1b[32m  ✓ Resource name without instance works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Resource name from digest");
    
    ReapiDigest digest;
    digest.hash = [0xAA, 0xBB, 0xCC, 0xDD];
    digest.sizeBytes = 256;
    
    auto resourceName = ResourceName.fromDigest("myinstance", digest);
    
    Assert.isTrue(resourceName.length > 0);
    Assert.isTrue(resourceName.indexOf("blobs/") >= 0);
    Assert.isTrue(resourceName.indexOf("/256") >= 0);
    
    writeln("\x1b[32m  ✓ Resource name from digest works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Invalid resource name");
    
    auto result1 = ResourceName.parse("invalid/path");
    Assert.isTrue(result1.isErr);
    
    auto result2 = ResourceName.parse("blobs/hash");  // Missing size
    Assert.isTrue(result2.isErr);
    
    writeln("\x1b[32m  ✓ Invalid resource name rejected\x1b[0m");
}

// ==================== BYTESTREAM CODEC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - ReadRequest encoding");
    
    ByteStreamReadRequest req;
    req.resourceName = "default/blobs/abc123/1024";
    req.readOffset = 100;
    req.readLimit = 500;
    
    auto encoded = ByteStreamCodec.encodeReadRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ ReadRequest encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - ReadRequest roundtrip");
    
    ByteStreamReadRequest req;
    req.resourceName = "test/blobs/hash123/2048";
    req.readOffset = 256;
    req.readLimit = 1024;
    
    auto encoded = ByteStreamCodec.encodeReadRequest(req);
    auto decoded = ByteStreamCodec.decodeReadRequest(encoded);
    
    Assert.isTrue(decoded.isOk);
    auto result = decoded.unwrap();
    Assert.equal(result.resourceName, req.resourceName);
    Assert.equal(result.readOffset, req.readOffset);
    Assert.equal(result.readLimit, req.readLimit);
    
    writeln("\x1b[32m  ✓ ReadRequest roundtrip works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - ReadResponse encoding");
    
    ByteStreamReadResponse resp;
    resp.data = cast(ubyte[])"Hello, World!".dup;
    
    auto encoded = ByteStreamCodec.encodeReadResponse(resp);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ ReadResponse encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - ReadResponse roundtrip");
    
    ByteStreamReadResponse resp;
    resp.data = cast(ubyte[])"Test data content".dup;
    
    auto encoded = ByteStreamCodec.encodeReadResponse(resp);
    auto decoded = ByteStreamCodec.decodeReadResponse(encoded);
    
    Assert.isTrue(decoded.isOk);
    Assert.equal(decoded.unwrap().data, resp.data);
    
    writeln("\x1b[32m  ✓ ReadResponse roundtrip works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - WriteRequest encoding");
    
    ByteStreamWriteRequest req;
    req.resourceName = "default/blobs/abc/100";
    req.writeOffset = 0;
    req.finishWrite = true;
    req.data = cast(ubyte[])"Chunk data".dup;
    
    auto encoded = ByteStreamCodec.encodeWriteRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ WriteRequest encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - WriteRequest roundtrip");
    
    ByteStreamWriteRequest req;
    req.resourceName = "instance/blobs/hash/512";
    req.writeOffset = 256;
    req.finishWrite = true;
    req.data = cast(ubyte[])"Final chunk".dup;
    
    auto encoded = ByteStreamCodec.encodeWriteRequest(req);
    auto decoded = ByteStreamCodec.decodeWriteRequest(encoded);
    
    Assert.isTrue(decoded.isOk);
    auto result = decoded.unwrap();
    Assert.equal(result.resourceName, req.resourceName);
    Assert.equal(result.writeOffset, req.writeOffset);
    Assert.isTrue(result.finishWrite);
    Assert.equal(result.data, req.data);
    
    writeln("\x1b[32m  ✓ WriteRequest roundtrip works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - WriteResponse encoding");
    
    ByteStreamWriteResponse resp;
    resp.committedSize = 4096;
    
    auto encoded = ByteStreamCodec.encodeWriteResponse(resp);
    Assert.isTrue(encoded.length > 0);
    
    auto decoded = ByteStreamCodec.decodeWriteResponse(encoded);
    Assert.isTrue(decoded.isOk);
    Assert.equal(decoded.unwrap().committedSize, 4096);
    
    writeln("\x1b[32m  ✓ WriteResponse encoding works\x1b[0m");
}

// ==================== CHUNK GENERATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Generate read chunks");
    
    auto data = new ubyte[5000];
    foreach (i; 0 .. data.length)
        data[i] = cast(ubyte)(i % 256);
    
    auto chunks = ByteStreamService.generateReadChunks(data, 2000);
    
    Assert.equal(chunks.length, 3);  // 2000 + 2000 + 1000
    Assert.equal(chunks[0].data.length, 2000);
    Assert.equal(chunks[1].data.length, 2000);
    Assert.equal(chunks[2].data.length, 1000);
    
    writeln("\x1b[32m  ✓ Read chunk generation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Generate write chunks");
    
    auto data = new ubyte[3500];
    foreach (i; 0 .. data.length)
        data[i] = cast(ubyte)(i % 256);
    
    auto chunks = ByteStreamService.generateWriteChunks(
        "default/blobs/test/3500",
        data,
        1500
    );
    
    Assert.equal(chunks.length, 3);  // 1500 + 1500 + 500
    
    // First chunk has resource name
    Assert.isTrue(chunks[0].resourceName.length > 0);
    Assert.equal(chunks[0].writeOffset, 0);
    
    // Middle chunk no resource name
    Assert.equal(chunks[1].resourceName.length, 0);
    Assert.equal(chunks[1].writeOffset, 1500);
    Assert.isFalse(chunks[1].finishWrite);
    
    // Last chunk has finish flag
    Assert.isTrue(chunks[2].finishWrite);
    Assert.equal(chunks[2].writeOffset, 3000);
    
    writeln("\x1b[32m  ✓ Write chunk generation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Single chunk for small data");
    
    auto data = cast(ubyte[])"Small data".dup;
    
    auto chunks = ByteStreamService.generateWriteChunks(
        "default/blobs/small/10",
        data,
        BYTESTREAM_CHUNK_SIZE
    );
    
    Assert.equal(chunks.length, 1);
    Assert.isTrue(chunks[0].resourceName.length > 0);
    Assert.isTrue(chunks[0].finishWrite);
    
    writeln("\x1b[32m  ✓ Single chunk for small data works\x1b[0m");
}

// ==================== BYTESTREAM SERVICE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Service creation");
    
    auto cas = new ContentAddressableStorageService();
    auto service = new ByteStreamService(cas);
    
    Assert.notNull(service);
    
    writeln("\x1b[32m  ✓ ByteStream service creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Service write and read");
    
    auto cas = new ContentAddressableStorageService();
    auto service = new ByteStreamService(cas);
    
    // Create test data
    auto testData = cast(ubyte[])"Test content for ByteStream".dup;
    
    // Calculate digest
    import engine.distributed.protocol.reapi_v2.hash : digestContent;
    auto digest = digestContent(testData, DigestFunction.SHA256);
    
    auto resourceName = ResourceName.fromDigest("", digest);
    
    // Create write chunks
    auto chunks = ByteStreamService.generateWriteChunks(resourceName, testData, 1024);
    
    // Write
    auto writeResult = service.write(chunks);
    Assert.isTrue(writeResult.isOk);
    Assert.equal(writeResult.unwrap().committedSize, testData.length);
    
    // Read back
    ByteStreamReadRequest readReq;
    readReq.resourceName = resourceName;
    
    auto readResult = service.read(readReq);
    Assert.isTrue(readResult.isOk);
    Assert.equal(readResult.unwrap(), testData);
    
    writeln("\x1b[32m  ✓ ByteStream write and read works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Service read with offset");
    
    auto cas = new ContentAddressableStorageService();
    auto service = new ByteStreamService(cas);
    
    // Store test data
    auto testData = cast(ubyte[])"0123456789ABCDEF".dup;
    import engine.distributed.protocol.reapi_v2.hash : digestContent;
    auto digest = digestContent(testData, DigestFunction.SHA256);
    cas.putBlob(digest, testData);
    
    auto resourceName = ResourceName.fromDigest("", digest);
    
    // Read with offset
    ByteStreamReadRequest readReq;
    readReq.resourceName = resourceName;
    readReq.readOffset = 5;
    readReq.readLimit = 5;
    
    auto readResult = service.read(readReq);
    Assert.isTrue(readResult.isOk);
    Assert.equal(cast(string)readResult.unwrap(), "56789");
    
    writeln("\x1b[32m  ✓ ByteStream read with offset works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m ByteStream - Query write status");
    
    auto cas = new ContentAddressableStorageService();
    auto service = new ByteStreamService(cas);
    
    // Store data in CAS
    auto testData = cast(ubyte[])"Complete data".dup;
    import engine.distributed.protocol.reapi_v2.hash : digestContent;
    auto digest = digestContent(testData, DigestFunction.SHA256);
    cas.putBlob(digest, testData);
    
    auto resourceName = ResourceName.fromDigest("", digest);
    
    // Query status
    ByteStreamQueryWriteStatusRequest req;
    req.resourceName = resourceName;
    
    auto result = service.queryWriteStatus(req);
    Assert.isTrue(result.isOk);
    Assert.isTrue(result.unwrap().complete);
    Assert.equal(result.unwrap().committedSize, digest.sizeBytes);
    
    writeln("\x1b[32m  ✓ Query write status works\x1b[0m");
}

// ==================== FIND MISSING BLOBS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - FindMissingBlobs request encoding");
    
    ReapiFindMissingBlobsRequest req;
    req.instanceName = "test-instance";
    req.blobDigests = [
        ReapiDigest([0x01, 0x02, 0x03], 100),
        ReapiDigest([0x04, 0x05, 0x06], 200)
    ];
    
    auto encoded = ReapiV2Codec.encodeFindMissingBlobsRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ FindMissingBlobs request encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - FindMissingBlobs request roundtrip");
    
    ReapiFindMissingBlobsRequest req;
    req.instanceName = "my-instance";
    req.blobDigests = [
        ReapiDigest([0xAA, 0xBB], 512),
        ReapiDigest([0xCC, 0xDD], 1024)
    ];
    
    auto encoded = ReapiV2Codec.encodeFindMissingBlobsRequest(req);
    auto decoded = ReapiV2Codec.decodeFindMissingBlobsRequest(encoded);
    
    Assert.isTrue(decoded.isOk);
    auto result = decoded.unwrap();
    Assert.equal(result.instanceName, "my-instance");
    Assert.equal(result.blobDigests.length, 2);
    
    writeln("\x1b[32m  ✓ FindMissingBlobs request roundtrip works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - FindMissingBlobs response encoding");
    
    ReapiFindMissingBlobsResponse resp;
    resp.missingBlobDigests = [
        ReapiDigest([0x01, 0x02], 100),
        ReapiDigest([0x03, 0x04], 200)
    ];
    
    auto encoded = ReapiV2Codec.encodeFindMissingBlobsResponse(resp);
    Assert.isTrue(encoded.length > 0);
    
    auto decoded = ReapiV2Codec.decodeFindMissingBlobsResponse(encoded);
    Assert.isTrue(decoded.isOk);
    Assert.equal(decoded.unwrap().missingBlobDigests.length, 2);
    
    writeln("\x1b[32m  ✓ FindMissingBlobs response encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - FindMissingBlobs service");
    
    auto cas = new ContentAddressableStorageService();
    
    // Add one blob
    auto existingDigest = ReapiDigest([0x01, 0x02, 0x03], 100);
    cas.putBlob(existingDigest, cast(ubyte[])"existing data".dup);
    
    // Query for missing
    auto missingDigest = ReapiDigest([0x04, 0x05, 0x06], 200);
    auto missing = cas.findMissingBlobs("", [existingDigest, missingDigest]);
    
    Assert.equal(missing.length, 1);
    Assert.equal(missing[0], missingDigest);
    
    writeln("\x1b[32m  ✓ FindMissingBlobs service works\x1b[0m");
}

// ==================== BATCH BLOBS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchUpdateBlobs request decoding");
    
    // Build a simple request manually
    ubyte[] buf;
    
    // Instance name
    buf ~= ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.LengthDelimited);
    buf ~= ReapiV2Codec.encodeVarint(4);
    buf ~= cast(ubyte[])"test";
    
    auto decoded = ReapiV2Codec.decodeBatchUpdateBlobsRequest(buf);
    Assert.isTrue(decoded.isOk);
    Assert.equal(decoded.unwrap().instanceName, "test");
    
    writeln("\x1b[32m  ✓ BatchUpdateBlobs request decoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchUpdateBlobs response encoding");
    
    ReapiBatchUpdateBlobsResponse resp;
    resp.responses = [
        ReapiBlobResponse(ReapiDigest([0x01], 10), [], Compressor.Identity, ReapiStatus.ok()),
        ReapiBlobResponse(ReapiDigest([0x02], 20), [], Compressor.Identity, ReapiStatus.ok())
    ];
    
    auto encoded = ReapiV2Codec.encodeBatchUpdateBlobsResponse(resp);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ BatchUpdateBlobs response encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchReadBlobs request decoding");
    
    ubyte[] buf;
    
    // Instance name
    buf ~= ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.LengthDelimited);
    buf ~= ReapiV2Codec.encodeVarint(7);
    buf ~= cast(ubyte[])"default";
    
    auto decoded = ReapiV2Codec.decodeBatchReadBlobsRequest(buf);
    Assert.isTrue(decoded.isOk);
    Assert.equal(decoded.unwrap().instanceName, "default");
    
    writeln("\x1b[32m  ✓ BatchReadBlobs request decoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchReadBlobs response encoding");
    
    ReapiBatchReadBlobsResponse resp;
    resp.responses = [
        ReapiBlobResponse(
            ReapiDigest([0x01], 5),
            cast(ubyte[])"hello".dup,
            Compressor.Identity,
            ReapiStatus.ok()
        )
    ];
    
    auto encoded = ReapiV2Codec.encodeBatchReadBlobsResponse(resp);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ BatchReadBlobs response encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchUpdateBlobs service");
    
    auto cas = new ContentAddressableStorageService();
    
    auto requests = [
        ReapiBlobRequest(
            ReapiDigest([0x01, 0x02], 5),
            cast(ubyte[])"data1".dup,
            Compressor.Identity
        ),
        ReapiBlobRequest(
            ReapiDigest([0x03, 0x04], 5),
            cast(ubyte[])"data2".dup,
            Compressor.Identity
        )
    ];
    
    auto responses = cas.batchUpdateBlobs("", requests);
    
    Assert.equal(responses.length, 2);
    Assert.isTrue(responses[0].status.isOk);
    Assert.isTrue(responses[1].status.isOk);
    
    // Verify stored
    Assert.isTrue(cas.hasBlob(requests[0].digest));
    Assert.isTrue(cas.hasBlob(requests[1].digest));
    
    writeln("\x1b[32m  ✓ BatchUpdateBlobs service works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - BatchReadBlobs service");
    
    auto cas = new ContentAddressableStorageService();
    
    // Store some data
    auto digest1 = ReapiDigest([0x01], 5);
    auto digest2 = ReapiDigest([0x02], 5);
    cas.putBlob(digest1, cast(ubyte[])"data1".dup);
    cas.putBlob(digest2, cast(ubyte[])"data2".dup);
    
    auto responses = cas.batchReadBlobs("", [digest1, digest2]);
    
    Assert.equal(responses.length, 2);
    Assert.isTrue(responses[0].status.isOk);
    Assert.equal(cast(string)responses[0].data, "data1");
    Assert.isTrue(responses[1].status.isOk);
    Assert.equal(cast(string)responses[1].data, "data2");
    
    writeln("\x1b[32m  ✓ BatchReadBlobs service works\x1b[0m");
}

// ==================== ACTION CACHE REQUEST TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - GetActionResultRequest encoding");
    
    ReapiGetActionResultRequest req;
    req.instanceName = "cache-instance";
    req.actionDigest = ReapiDigest([0xAB, 0xCD], 64);
    req.inlineStdout = true;
    req.inlineStderr = true;
    req.inlineOutputFiles = ["output.o", "output.log"];
    
    auto encoded = ReapiV2Codec.encodeGetActionResultRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ GetActionResultRequest encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - UpdateActionResultRequest encoding");
    
    ReapiUpdateActionResultRequest req;
    req.instanceName = "cache-instance";
    req.actionDigest = ReapiDigest([0x01, 0x02], 64);
    req.actionResult.exitCode = 0;
    req.actionResult.stdoutRaw = cast(ubyte[])"Success".dup;
    
    auto encoded = ReapiV2Codec.encodeUpdateActionResultRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ UpdateActionResultRequest encoding works\x1b[0m");
}

