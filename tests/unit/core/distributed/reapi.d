module tests.unit.core.distributed.reapi;

import std.stdio;
import std.datetime;
import std.conv;
import std.algorithm : map;
import std.array : array;
import engine.distributed.protocol.reapi_v2;
import engine.distributed.protocol.protocol;
import infrastructure.errors;
import tests.harness;

// ==================== REAPI DIGEST TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Digest creation");
    
    ReapiDigest digest;
    digest.hash = cast(ubyte[])"abc123def456".dup;
    digest.sizeBytes = 1024;
    
    Assert.equal(digest.sizeBytes, 1024);
    Assert.equal(digest.hash.length, 12);
    
    writeln("\x1b[32m  ✓ Digest creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Digest hash string");
    
    ReapiDigest digest;
    digest.hash = [0xAB, 0xCD, 0xEF];
    digest.sizeBytes = 256;
    
    auto hashStr = digest.hashString();
    Assert.isTrue(hashStr.length > 0);
    
    writeln("\x1b[32m  ✓ Digest hash string works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Digest equality");
    
    ReapiDigest d1, d2, d3;
    d1.hash = [0x01, 0x02, 0x03];
    d1.sizeBytes = 100;
    
    d2.hash = [0x01, 0x02, 0x03];
    d2.sizeBytes = 100;
    
    d3.hash = [0x01, 0x02, 0x04];
    d3.sizeBytes = 100;
    
    Assert.isTrue(d1 == d2);
    Assert.isFalse(d1 == d3);
    
    writeln("\x1b[32m  ✓ Digest equality works\x1b[0m");
}

// ==================== REAPI ADAPTER TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Adapter creation SHA256");
    
    auto adapter = new ReapiV2Adapter(DigestFunction.SHA256);
    Assert.notNull(adapter);
    
    writeln("\x1b[32m  ✓ Adapter creation SHA256 works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Adapter creation BLAKE3");
    
    auto adapter = new ReapiV2Adapter(DigestFunction.BLAKE3);
    Assert.notNull(adapter);
    
    writeln("\x1b[32m  ✓ Adapter creation BLAKE3 works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Capabilities to platform conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    Capabilities caps;
    caps.network = true;
    caps.maxCpu = 8;
    caps.maxMemory = 16_000_000_000;
    
    auto platform = adapter.capabilitiesToPlatform(caps);
    
    Assert.isTrue(platform.properties.length >= 3);
    
    // Verify properties
    bool hasNetwork, hasCpu, hasMemory;
    foreach (prop; platform.properties)
    {
        if (prop.name == "network-access" && prop.value == "true")
            hasNetwork = true;
        if (prop.name == "cpu-count" && prop.value == "8")
            hasCpu = true;
        if (prop.name == "memory-bytes")
            hasMemory = true;
    }
    
    Assert.isTrue(hasNetwork);
    Assert.isTrue(hasCpu);
    Assert.isTrue(hasMemory);
    
    writeln("\x1b[32m  ✓ Capabilities to platform conversion works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Platform to capabilities conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    ReapiPlatform platform;
    platform.properties = [
        ReapiProperty("network-access", "true"),
        ReapiProperty("cpu-count", "4"),
        ReapiProperty("memory-bytes", "8000000000"),
        ReapiProperty("timeout-seconds", "120")
    ];
    
    auto caps = adapter.platformToCapabilities(platform);
    
    Assert.isTrue(caps.network);
    Assert.equal(caps.maxCpu, 4);
    Assert.equal(caps.maxMemory, 8_000_000_000);
    Assert.equal(caps.timeout, 120.seconds);
    
    writeln("\x1b[32m  ✓ Platform to capabilities conversion works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Priority conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    // Builder to REAPI
    Assert.equal(adapter.priorityToReapi(Priority.Low), 10);
    Assert.equal(adapter.priorityToReapi(Priority.Normal), 50);
    Assert.equal(adapter.priorityToReapi(Priority.High), 100);
    Assert.equal(adapter.priorityToReapi(Priority.Critical), 200);
    
    // REAPI to Builder
    Assert.equal(adapter.reapiToPriority(5), Priority.Low);
    Assert.equal(adapter.reapiToPriority(50), Priority.Normal);
    Assert.equal(adapter.reapiToPriority(100), Priority.High);
    Assert.equal(adapter.reapiToPriority(250), Priority.Critical);
    
    writeln("\x1b[32m  ✓ Priority conversion works\x1b[0m");
}

// ==================== HASH TRANSLATOR TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Hash translator creation");
    
    auto translator = new HashTranslator(HashFormat.SHA256);
    Assert.notNull(translator);
    
    writeln("\x1b[32m  ✓ Hash translator creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - ActionId to digest conversion");
    
    auto translator = new HashTranslator(HashFormat.BLAKE3_32);
    
    ubyte[32] hash;
    hash[0] = 0xAA;
    hash[1] = 0xBB;
    hash[31] = 0xFF;
    
    auto actionId = ActionId(hash);
    auto result = translator.actionIdToDigest(actionId, 1024);
    
    Assert.isTrue(result.isOk);
    auto digest = result.unwrap();
    Assert.equal(digest.sizeBytes, 1024);
    Assert.isTrue(digest.hash.length > 0);
    
    writeln("\x1b[32m  ✓ ActionId to digest conversion works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Digest to ActionId conversion");
    
    auto translator = new HashTranslator(HashFormat.BLAKE3_32);
    
    ReapiDigest digest;
    ubyte[32] hashData;
    hashData[0] = 0x11;
    hashData[1] = 0x22;
    digest.hash = hashData[].dup;
    digest.sizeBytes = 512;
    
    auto result = translator.digestToActionId(digest);
    
    Assert.isTrue(result.isOk);
    auto actionId = result.unwrap();
    Assert.equal(actionId.hash[0], 0x11);
    Assert.equal(actionId.hash[1], 0x22);
    
    writeln("\x1b[32m  ✓ Digest to ActionId conversion works\x1b[0m");
}

// ==================== CODEC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Codec varint encoding");
    
    // Small numbers
    auto encoded1 = ReapiV2Codec.encodeVarint(1);
    Assert.equal(encoded1.length, 1);
    Assert.equal(encoded1[0], 1);
    
    // Medium numbers
    auto encoded127 = ReapiV2Codec.encodeVarint(127);
    Assert.equal(encoded127.length, 1);
    
    // Larger numbers
    auto encoded300 = ReapiV2Codec.encodeVarint(300);
    Assert.isTrue(encoded300.length > 1);
    
    writeln("\x1b[32m  ✓ Varint encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Codec digest encoding");
    
    ReapiDigest digest;
    digest.hash = [0x01, 0x02, 0x03, 0x04];
    digest.sizeBytes = 100;
    
    auto encoded = ReapiV2Codec.encodeDigest(digest);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Digest encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Codec action result encoding");
    
    ReapiActionResult result;
    result.exitCode = 0;
    result.stdoutRaw = cast(ubyte[])"hello".dup;
    result.stderrRaw = cast(ubyte[])"".dup;
    
    auto encoded = ReapiV2Codec.encodeActionResult(result);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Action result encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Codec execute response encoding");
    
    ReapiExecuteResponse response;
    response.status = ReapiStatus.ok();
    response.result.exitCode = 0;
    
    auto encoded = ReapiV2Codec.encodeExecuteResponse(response);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Execute response encoding works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Codec server capabilities encoding");
    
    ReapiServerCapabilities caps;
    caps.cacheCapabilities.actionCacheUpdateEnabled = true;
    caps.executionCapabilities.execEnabled = true;
    caps.lowApiVersion = "2.0";
    caps.highApiVersion = "2.3";
    
    auto encoded = ReapiV2Codec.encodeServerCapabilities(caps);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Server capabilities encoding works\x1b[0m");
}

// ==================== SERVER CAPABILITIES TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Build server capabilities");
    
    auto adapter = new ReapiV2Adapter();
    auto caps = adapter.buildServerCapabilities();
    
    // Check cache capabilities
    Assert.isTrue(caps.cacheCapabilities.actionCacheUpdateEnabled);
    Assert.isTrue(caps.cacheCapabilities.maxBatchTotalSizeBytes > 0);
    Assert.isTrue(caps.cacheCapabilities.digestFunctions.length > 0);
    
    // Check execution capabilities
    Assert.isTrue(caps.executionCapabilities.execEnabled);
    
    // Check API versions
    Assert.isTrue(caps.lowApiVersion.length > 0);
    Assert.isTrue(caps.highApiVersion.length > 0);
    
    writeln("\x1b[32m  ✓ Server capabilities building works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Supported digest functions");
    
    auto adapter = new ReapiV2Adapter();
    auto caps = adapter.buildServerCapabilities();
    
    // Should support both BLAKE3 and SHA256
    bool hasBLAKE3, hasSHA256;
    foreach (func; caps.cacheCapabilities.digestFunctions)
    {
        if (func == DigestFunction.BLAKE3)
            hasBLAKE3 = true;
        if (func == DigestFunction.SHA256)
            hasSHA256 = true;
    }
    
    Assert.isTrue(hasBLAKE3);
    Assert.isTrue(hasSHA256);
    
    writeln("\x1b[32m  ✓ Digest functions supported\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Supported compressors");
    
    auto adapter = new ReapiV2Adapter();
    auto caps = adapter.buildServerCapabilities();
    
    Assert.isTrue(caps.cacheCapabilities.supportedCompressors.length > 0);
    
    // Should at least support Identity (no compression)
    bool hasIdentity;
    foreach (comp; caps.cacheCapabilities.supportedCompressors)
    {
        if (comp == Compressor.Identity)
            hasIdentity = true;
    }
    
    Assert.isTrue(hasIdentity);
    
    writeln("\x1b[32m  ✓ Compressors supported\x1b[0m");
}

// ==================== STATUS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Status OK");
    
    auto status = ReapiStatus.ok();
    
    Assert.isTrue(status.isOk);
    Assert.equal(status.code, 0);
    
    writeln("\x1b[32m  ✓ Status OK works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Status error");
    
    auto status = ReapiStatus.internal("Something failed");
    
    Assert.isFalse(status.isOk);
    Assert.isTrue(status.code != 0);
    Assert.isTrue(status.message.length > 0);
    
    writeln("\x1b[32m  ✓ Status error works\x1b[0m");
}

// ==================== CLIENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Client creation");
    
    auto client = new ReapiV2Client("localhost:50051", "default", 30.seconds);
    Assert.notNull(client);
    
    writeln("\x1b[32m  ✓ Client creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Client with custom instance");
    
    auto client = new ReapiV2Client("build.example.com:443", "my-instance");
    Assert.notNull(client);
    
    writeln("\x1b[32m  ✓ Client with custom instance works\x1b[0m");
}

// ==================== SERVER TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Server creation");
    
    auto server = new ReapiV2Server("0.0.0.0", 50051);
    Assert.notNull(server);
    
    writeln("\x1b[32m  ✓ Server creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Server handler registration");
    
    auto server = new ReapiV2Server();
    
    // Register execute handler
    server.onExecute((ActionRequest req) @safe {
        ActionResult result;
        result.status = ResultStatus.Success;
        result.exitCode = 0;
        return Ok!(ActionResult, BuildError)(result);
    });
    
    Assert.notNull(server.getAdapter());
    
    writeln("\x1b[32m  ✓ Server handler registration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Server capabilities endpoint");
    
    auto server = new ReapiV2Server();
    
    auto result = server.handleRequest("/v2/default/capabilities", "GET", []);
    Assert.isTrue(result.isOk);
    
    auto responseData = result.unwrap();
    Assert.isTrue(responseData.length > 0);
    
    writeln("\x1b[32m  ✓ Server capabilities endpoint works\x1b[0m");
}

// ==================== ACTION CONVERSION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Action request to REAPI conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "gcc -c main.c -o main.o",
        ["CC": "gcc", "CFLAGS": "-O2"],
        [],
        [OutputSpec("main.o", false)],
        Capabilities.init,
        Priority.High,
        120.seconds
    );
    
    ReapiCommand cmd;
    auto action = adapter.actionRequestToReapi(request, cmd);
    
    Assert.isTrue(cmd.outputFiles.length > 0);
    Assert.equal(cmd.outputFiles[0], "main.o");
    
    writeln("\x1b[32m  ✓ Action request to REAPI conversion works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Action result to REAPI conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    ActionResult result;
    result.exitCode = 0;
    result.stdout = "Compilation successful";
    result.stderr = "";
    result.status = ResultStatus.Success;
    
    auto reapiResult = adapter.actionResultToReapi(result);
    
    Assert.equal(reapiResult.exitCode, 0);
    Assert.equal(cast(string)reapiResult.stdoutRaw, "Compilation successful");
    
    writeln("\x1b[32m  ✓ Action result to REAPI conversion works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - REAPI result to Builder conversion");
    
    auto adapter = new ReapiV2Adapter();
    
    ReapiActionResult reapiResult;
    reapiResult.exitCode = 1;
    reapiResult.stdoutRaw = cast(ubyte[])"output".dup;
    reapiResult.stderrRaw = cast(ubyte[])"error".dup;
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto result = adapter.reapiToActionResult(reapiResult, actionId);
    
    Assert.equal(result.exitCode, 1);
    Assert.equal(result.stdout, "output");
    Assert.equal(result.stderr, "error");
    Assert.equal(result.status, ResultStatus.Failure);
    
    writeln("\x1b[32m  ✓ REAPI result to Builder conversion works\x1b[0m");
}

// ==================== WIRE FORMAT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Wire format tag creation");
    
    auto tag = ReapiV2Codec.makeTag(1, ReapiV2Codec.WireType.Varint);
    Assert.equal(tag[0], 0x08);  // Field 1, wire type 0
    
    auto tag2 = ReapiV2Codec.makeTag(2, ReapiV2Codec.WireType.LengthDelimited);
    Assert.equal(tag2[0], 0x12);  // Field 2, wire type 2
    
    writeln("\x1b[32m  ✓ Wire format tag creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Execute request encoding");
    
    ReapiExecuteRequest req;
    req.instanceName = "default";
    req.skipCacheLookup = false;
    req.actionDigest.hash = [0x01, 0x02, 0x03];
    req.actionDigest.sizeBytes = 100;
    
    auto encoded = ReapiV2Codec.encodeExecuteRequest(req);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Execute request encoding works\x1b[0m");
}

// ==================== ERROR HANDLING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Handle null action request");
    
    auto adapter = new ReapiV2Adapter();
    
    ReapiCommand cmd;
    auto action = adapter.actionRequestToReapi(null, cmd);
    
    // Should return empty action, not crash
    Assert.equal(action.timeout, Duration.zero);
    
    writeln("\x1b[32m  ✓ Null action request handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Handle invalid digest size");
    
    auto translator = new HashTranslator(HashFormat.BLAKE3_32);
    
    ReapiDigest digest;
    digest.hash = [0x01];  // Too short
    digest.sizeBytes = 100;
    
    auto result = translator.digestToActionId(digest);
    // Should handle gracefully
    
    writeln("\x1b[32m  ✓ Invalid digest size handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m REAPI - Handle unknown endpoint");
    
    auto server = new ReapiV2Server();
    
    auto result = server.handleRequest("/v2/unknown/endpoint", "GET", []);
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Unknown endpoint handled\x1b[0m");
}


