module tests.unit.core.distributed.grpc;

import std.stdio;
import std.datetime;
import std.conv;
import std.array : Appender;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.grpc.codec;
import engine.distributed.protocol.grpc.transport;
import engine.distributed.protocol.grpc.factory;
import engine.distributed.protocol.grpc.server;
import engine.distributed.protocol.grpc.types;
import tests.harness;

// ==================== GRPC CONFIG TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcConfig insecure creation");
    
    auto config = GrpcConfig.insecure("localhost:9000");
    
    Assert.equal(config.target, "localhost:9000");
    Assert.isFalse(config.useTls);
    
    writeln("\x1b[32m  ✓ GrpcConfig insecure creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcConfig secure creation");
    
    auto config = GrpcConfig.secure("localhost:9000", "root-certs");
    
    Assert.equal(config.target, "localhost:9000");
    Assert.isTrue(config.useTls);
    Assert.equal(config.rootCerts, "root-certs");
    
    writeln("\x1b[32m  ✓ GrpcConfig secure creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcConfig default values");
    
    GrpcConfig config;
    
    Assert.isFalse(config.useTls);
    Assert.equal(config.connectTimeout, 30.seconds);
    Assert.equal(config.callTimeout, 60.seconds);
    Assert.equal(config.maxMessageSize, 4 * 1024 * 1024);
    Assert.isTrue(config.enableRetry);
    Assert.equal(config.maxRetries, 3);
    
    writeln("\x1b[32m  ✓ GrpcConfig default values correct\x1b[0m");
}

// ==================== TRANSPORT CONFIG TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig fromUrl grpc://");
    
    auto config = TransportConfig.fromUrl("grpc://coordinator:9000");
    
    Assert.equal(config.type, TransportType.Grpc);
    Assert.equal(config.endpoint, "coordinator:9000");
    Assert.isFalse(config.useTls);
    
    writeln("\x1b[32m  ✓ TransportConfig fromUrl grpc:// works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig fromUrl grpcs://");
    
    auto config = TransportConfig.fromUrl("grpcs://coordinator:9000");
    
    Assert.equal(config.type, TransportType.Grpc);
    Assert.equal(config.endpoint, "coordinator:9000");
    Assert.isTrue(config.useTls);
    
    writeln("\x1b[32m  ✓ TransportConfig fromUrl grpcs:// works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig fromUrl http://");
    
    auto config = TransportConfig.fromUrl("http://coordinator:8080");
    
    Assert.equal(config.type, TransportType.Http);
    Assert.equal(config.endpoint, "coordinator:8080");
    Assert.isFalse(config.useTls);
    
    writeln("\x1b[32m  ✓ TransportConfig fromUrl http:// works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig fromUrl https://");
    
    auto config = TransportConfig.fromUrl("https://coordinator:8080");
    
    Assert.equal(config.type, TransportType.Http);
    Assert.equal(config.endpoint, "coordinator:8080");
    Assert.isTrue(config.useTls);
    
    writeln("\x1b[32m  ✓ TransportConfig fromUrl https:// works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig grpcInsecure");
    
    auto config = TransportConfig.grpcInsecure("worker:9001");
    
    Assert.equal(config.type, TransportType.Grpc);
    Assert.equal(config.endpoint, "worker:9001");
    Assert.isFalse(config.useTls);
    
    writeln("\x1b[32m  ✓ TransportConfig grpcInsecure works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportConfig grpcSecure");
    
    auto config = TransportConfig.grpcSecure("worker:9001", "root-certs");
    
    Assert.equal(config.type, TransportType.Grpc);
    Assert.equal(config.endpoint, "worker:9001");
    Assert.isTrue(config.useTls);
    Assert.equal(config.rootCerts, "root-certs");
    
    writeln("\x1b[32m  ✓ TransportConfig grpcSecure works\x1b[0m");
}

// ==================== TRANSPORT TYPE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportType enum values");
    
    Assert.equal(cast(int)TransportType.Http, 0);
    Assert.equal(cast(int)TransportType.Grpc, 1);
    Assert.equal(cast(int)TransportType.Auto, 2);
    
    writeln("\x1b[32m  ✓ TransportType enum values correct\x1b[0m");
}

// ==================== GRPC CODEC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec creation");
    
    auto codec = new GrpcCodec();
    Assert.notNull(codec);
    
    writeln("\x1b[32m  ✓ GrpcCodec creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec encodeHeartBeat");
    
    auto codec = new GrpcCodec();
    
    HeartBeat hb;
    hb.worker = WorkerId(42);
    hb.state = WorkerState.Executing;
    hb.metrics.cpuUsage = 0.75;
    hb.metrics.memoryUsage = 0.5;
    hb.metrics.queueDepth = 10;
    hb.timestamp = Clock.currTime;
    
    auto encoded = codec.encodeHeartBeat(hb);
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ GrpcCodec encodeHeartBeat works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec encodeStealRequest");
    
    auto codec = new GrpcCodec();
    
    StealRequest req;
    req.thief = WorkerId(1);
    req.victim = WorkerId(2);
    req.minPriority = Priority.Normal;
    
    auto encoded = codec.encodeStealRequest(req);
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ GrpcCodec encodeStealRequest works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec encodeStealResponse");
    
    auto codec = new GrpcCodec();
    
    StealResponse resp;
    resp.victim = WorkerId(2);
    resp.thief = WorkerId(1);
    resp.hasWork = false;
    
    auto encoded = codec.encodeStealResponse(resp);
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ GrpcCodec encodeStealResponse works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec encodeActionRequest");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    hash[0] = 0xAB;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "gcc -o main main.c",
        ["PATH": "/usr/bin", "HOME": "/home/builder"],
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    auto encoded = codec.encodeActionRequest(request);
    
    Assert.isTrue(encoded.length > 0);
    // Should contain the hash
    Assert.equal(encoded[2], 0xAB);  // After field tag and length
    
    writeln("\x1b[32m  ✓ GrpcCodec encodeActionRequest works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec decodeActionResult empty");
    
    auto codec = new GrpcCodec();
    
    // Empty data should return empty result
    auto result = codec.decodeActionResult([]);
    
    // Should succeed with empty data (all defaults)
    Assert.isTrue(result.isOk);
    
    writeln("\x1b[32m  ✓ GrpcCodec decodeActionResult empty works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcCodec encodeRegisterWorkerRequest");
    
    auto codec = new GrpcCodec();
    
    Capabilities caps;
    caps.maxCpu = 8;
    caps.maxMemory = 16_000_000_000;
    
    auto encoded = codec.encodeRegisterWorkerRequest(
        WorkerId(123),
        "worker-1:9100",
        caps,
        16
    );
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ GrpcCodec encodeRegisterWorkerRequest works\x1b[0m");
}

// ==================== EXECUTION PROGRESS TYPE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - ExecutionProgress stages");
    
    Assert.equal(cast(int)ExecutionProgress.Stage.Queued, 0);
    Assert.equal(cast(int)ExecutionProgress.Stage.InputFetch, 1);
    Assert.equal(cast(int)ExecutionProgress.Stage.Executing, 2);
    Assert.equal(cast(int)ExecutionProgress.Stage.OutputUpload, 3);
    Assert.equal(cast(int)ExecutionProgress.Stage.Complete, 4);
    
    writeln("\x1b[32m  ✓ ExecutionProgress stages correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - ExecutionProgress creation");
    
    ubyte[32] hash;
    hash[0] = 0x01;
    
    ExecutionProgress progress;
    progress.actionId = ActionId(hash);
    progress.stage = ExecutionProgress.Stage.Executing;
    progress.progress = 0.5;
    progress.message = "Compiling...";
    
    Assert.equal(progress.actionId.hash[0], 0x01);
    Assert.equal(progress.stage, ExecutionProgress.Stage.Executing);
    Assert.equal(progress.progress, 0.5f);
    Assert.equal(progress.message, "Compiling...");
    
    writeln("\x1b[32m  ✓ ExecutionProgress creation works\x1b[0m");
}

// ==================== REGISTER WORKER RESPONSE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - RegisterWorkerResponse creation");
    
    RegisterWorkerResponse resp;
    resp.accepted = true;
    resp.message = "Worker registered successfully";
    resp.peers = [WorkerId(1), WorkerId(2), WorkerId(3)];
    
    Assert.isTrue(resp.accepted);
    Assert.equal(resp.message, "Worker registered successfully");
    Assert.equal(resp.peers.length, 3);
    Assert.equal(resp.peers[0].value, 1);
    Assert.equal(resp.peers[2].value, 3);
    
    writeln("\x1b[32m  ✓ RegisterWorkerResponse creation works\x1b[0m");
}

// ==================== COORDINATOR COMMAND TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - CoordinatorCommand types");
    
    Assert.equal(cast(int)CoordinatorCommand.Type.Shutdown, 0);
    Assert.equal(cast(int)CoordinatorCommand.Type.PushWork, 1);
    
    writeln("\x1b[32m  ✓ CoordinatorCommand types correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - CoordinatorCommand shutdown");
    
    CoordinatorCommand cmd;
    cmd.type = CoordinatorCommand.Type.Shutdown;
    cmd.shutdown.graceful = true;
    cmd.shutdown.timeout = 30.seconds;
    
    Assert.equal(cmd.type, CoordinatorCommand.Type.Shutdown);
    Assert.isTrue(cmd.shutdown.graceful);
    Assert.equal(cmd.shutdown.timeout, 30.seconds);
    
    writeln("\x1b[32m  ✓ CoordinatorCommand shutdown works\x1b[0m");
}

// ==================== GRPC SERVER CONFIG TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcServerConfig insecure");
    
    auto config = GrpcServerConfig.insecure("0.0.0.0:9000");
    
    Assert.equal(config.address, "0.0.0.0:9000");
    Assert.isFalse(config.useTls);
    
    writeln("\x1b[32m  ✓ GrpcServerConfig insecure works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcServerConfig default values");
    
    GrpcServerConfig config;
    
    Assert.isFalse(config.useTls);
    Assert.isFalse(config.requireClientAuth);
    Assert.equal(config.maxConcurrentStreams, 100);
    Assert.equal(config.keepaliveTime, 30.seconds);
    Assert.equal(config.keepaliveTimeout, 10.seconds);
    
    writeln("\x1b[32m  ✓ GrpcServerConfig default values correct\x1b[0m");
}

// ==================== GRPC SERVER TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcServer creation");
    
    auto config = GrpcServerConfig.insecure("0.0.0.0:0");
    auto server = new GrpcServer(config);
    
    Assert.notNull(server);
    Assert.isFalse(server.isRunning());
    
    writeln("\x1b[32m  ✓ GrpcServer creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcServer start/stop");
    
    auto config = GrpcServerConfig.insecure("0.0.0.0:0");
    auto server = new GrpcServer(config);
    
    Assert.isFalse(server.isRunning());
    
    auto result = server.start();
    Assert.isTrue(result.isOk);
    Assert.isTrue(server.isRunning());
    
    server.stop();
    Assert.isFalse(server.isRunning());
    
    writeln("\x1b[32m  ✓ GrpcServer start/stop works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - GrpcServer boundAddress");
    
    auto config = GrpcServerConfig.insecure("localhost:9999");
    auto server = new GrpcServer(config);
    
    Assert.equal(server.boundAddress(), "localhost:9999");
    
    writeln("\x1b[32m  ✓ GrpcServer boundAddress works\x1b[0m");
}

// ==================== TRANSPORT POOL TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportPool creation");
    
    auto pool = new TransportPool(TransportStrategy.PreferGrpc);
    Assert.notNull(pool);
    
    writeln("\x1b[32m  ✓ TransportPool creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportPool addEndpoint");
    
    auto pool = new TransportPool();
    
    pool.addEndpoint(TransportConfig.grpcInsecure("worker1:9000"));
    pool.addEndpoint(TransportConfig.grpcInsecure("worker2:9000"));
    
    // Pool should have endpoints (internal state not directly accessible)
    Assert.notNull(pool);
    
    writeln("\x1b[32m  ✓ TransportPool addEndpoint works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportPool empty getTransport");
    
    auto pool = new TransportPool();
    
    auto result = pool.getTransport();
    
    Assert.isTrue(result.isErr);  // Should fail with no endpoints
    
    writeln("\x1b[32m  ✓ TransportPool empty getTransport returns error\x1b[0m");
}

// ==================== TRANSPORT STRATEGY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - TransportStrategy enum values");
    
    Assert.equal(cast(int)TransportStrategy.PreferGrpc, 0);
    Assert.equal(cast(int)TransportStrategy.PreferHttp, 1);
    Assert.equal(cast(int)TransportStrategy.GrpcOnly, 2);
    Assert.equal(cast(int)TransportStrategy.HttpOnly, 3);
    Assert.equal(cast(int)TransportStrategy.RoundRobin, 4);
    
    writeln("\x1b[32m  ✓ TransportStrategy enum values correct\x1b[0m");
}

// ==================== VARINT ENCODING TESTS (via codec) ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec varint encoding small numbers");
    
    auto codec = new GrpcCodec();
    
    // Small number encoding via HeartBeat (worker ID uses varint)
    HeartBeat hb;
    hb.worker = WorkerId(127);  // Max single-byte varint
    
    auto encoded = codec.encodeHeartBeat(hb);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec varint small numbers work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec varint encoding large numbers");
    
    auto codec = new GrpcCodec();
    
    // Large number encoding
    HeartBeat hb;
    hb.worker = WorkerId(0xFFFFFFFFFFFFFFFF);  // Max uint64
    
    auto encoded = codec.encodeHeartBeat(hb);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec varint large numbers work\x1b[0m");
}

// ==================== CAPABILITIES ENCODING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec capabilities with paths");
    
    auto codec = new GrpcCodec();
    
    Capabilities caps;
    caps.network = true;
    caps.readPaths = ["/usr/bin", "/usr/lib", "/opt/toolchain"];
    caps.writePaths = ["/tmp", "/workspace/output"];
    caps.maxCpu = 16;
    caps.maxMemory = 32_000_000_000;
    caps.timeout = 300.seconds;
    
    auto encoded = codec.encodeRegisterWorkerRequest(
        WorkerId(1),
        "worker:9000",
        caps,
        32
    );
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec capabilities with paths works\x1b[0m");
}

// ==================== ACTION REQUEST ENCODING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec ActionRequest with inputs");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] actionHash, inputHash1, inputHash2;
    actionHash[0] = 0xAA;
    inputHash1[0] = 0xBB;
    inputHash2[0] = 0xCC;
    
    InputSpec[] inputs = [
        InputSpec(ArtifactId(inputHash1), "/src/main.c", false),
        InputSpec(ArtifactId(inputHash2), "/src/util.c", false)
    ];
    
    OutputSpec[] outputs = [
        OutputSpec("/build/main.o", false),
        OutputSpec("/build/util.o", false)
    ];
    
    auto request = new ActionRequest(
        ActionId(actionHash),
        "gcc -c main.c util.c",
        ["CC": "gcc", "CFLAGS": "-O2"],
        inputs,
        outputs,
        Capabilities.init,
        Priority.High,
        120.seconds
    );
    
    auto encoded = codec.encodeActionRequest(request);
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec ActionRequest with inputs works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec ActionRequest priority encoding");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    
    // Test different priorities
    foreach (pri; [Priority.Low, Priority.Normal, Priority.High, Priority.Critical])
    {
        auto request = new ActionRequest(
            ActionId(hash),
            "echo test",
            (string[string]).init,
            [],
            [],
            Capabilities.init,
            pri,
            60.seconds
        );
        
        auto encoded = codec.encodeActionRequest(request);
        Assert.isTrue(encoded.length > 0);
    }
    
    writeln("\x1b[32m  ✓ Codec ActionRequest priority encoding works\x1b[0m");
}

// ==================== STEAL RESPONSE WITH ACTION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec StealResponse with action");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    hash[0] = 0xDE;
    hash[1] = 0xAD;
    
    auto action = new ActionRequest(
        ActionId(hash),
        "make all",
        (string[string]).init,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    StealResponse resp;
    resp.victim = WorkerId(10);
    resp.thief = WorkerId(5);
    resp.hasWork = true;
    resp.action = action;
    
    auto encoded = codec.encodeStealResponse(resp);
    
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec StealResponse with action works\x1b[0m");
}

// ==================== EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec empty environment");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "test",
        (string[string]).init,  // Empty environment
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    auto encoded = codec.encodeActionRequest(request);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec empty environment works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec empty command");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "",  // Empty command
        (string[string]).init,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    auto encoded = codec.encodeActionRequest(request);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec empty command works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec zero timeout");
    
    auto codec = new GrpcCodec();
    
    ubyte[32] hash;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "quick-command",
        (string[string]).init,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        Duration.zero  // Zero timeout
    );
    
    auto encoded = codec.encodeActionRequest(request);
    Assert.isTrue(encoded.length > 0);
    
    writeln("\x1b[32m  ✓ Codec zero timeout works\x1b[0m");
}

// ==================== DECODE EDGE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec decodeActionResult malformed");
    
    auto codec = new GrpcCodec();
    
    // Malformed data (invalid varint)
    ubyte[] malformed = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F];
    
    auto result = codec.decodeActionResult(malformed);
    // Should handle malformed data gracefully
    // Either returns error or partial result
    
    writeln("\x1b[32m  ✓ Codec decodeActionResult malformed handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec decodeExecutionProgress empty");
    
    auto codec = new GrpcCodec();
    
    auto result = codec.decodeExecutionProgress([]);
    
    Assert.isTrue(result.isOk);  // Empty data should be valid (all defaults)
    
    writeln("\x1b[32m  ✓ Codec decodeExecutionProgress empty works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m gRPC - Codec decodeRegisterWorkerResponse empty");
    
    auto codec = new GrpcCodec();
    
    auto result = codec.decodeRegisterWorkerResponse([]);
    
    Assert.isTrue(result.isOk);  // Empty data should be valid (all defaults)
    
    auto resp = result.unwrap();
    Assert.isFalse(resp.accepted);  // Default is false
    Assert.equal(resp.peers.length, 0);  // No peers
    
    writeln("\x1b[32m  ✓ Codec decodeRegisterWorkerResponse empty works\x1b[0m");
}

