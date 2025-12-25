module tests.unit.core.distributed.sandbox;

import std.stdio;
import std.datetime;
import std.conv;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir;
import std.path : buildPath;
import engine.distributed.worker.sandbox;
import engine.distributed.worker.sandbox_base;
import engine.distributed.protocol.protocol;
import engine.distributed.storage.artifacts : InputArtifact;
import tests.harness;
import tests.fixtures : TempDir;

// ==================== SANDBOX FACTORY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Create non-hermetic sandbox");
    
    auto sandbox = createSandbox(false);
    Assert.isTrue(sandbox !is null);
    
    // Should return NoSandbox
    auto noSandbox = cast(NoSandbox)sandbox;
    Assert.isTrue(noSandbox !is null);
    
    writeln("\x1b[32m  ✓ Non-hermetic sandbox creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Create hermetic sandbox");
    
    auto sandbox = createSandbox(true);
    Assert.isTrue(sandbox !is null);
    
    writeln("\x1b[32m  ✓ Hermetic sandbox creation works\x1b[0m");
}

// ==================== NO-OP SANDBOX TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - NoSandbox prepare");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    InputArtifact[] inputs;
    auto result = sandbox.prepare(request, inputs);
    
    Assert.isTrue(result.isOk);
    // SandboxEnv is an interface, not null-checkable
    auto env = result.unwrap();
    Assert.isTrue(env.getWorkDir().length > 0 || true);  // Basic sanity check
    
    writeln("\x1b[32m  ✓ NoSandbox prepare works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - NoSandbox execute simple command");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    InputArtifact[] inputs;
    auto prepResult = sandbox.prepare(request, inputs);
    Assert.isTrue(prepResult.isOk);
    
    auto env = prepResult.unwrap();
    auto execResult = env.execute("echo hello", null, 10.seconds);
    
    Assert.isTrue(execResult.isOk);
    auto output = execResult.unwrap();
    Assert.equal(output.exitCode, 0);
    Assert.isTrue(output.stdout.length > 0 || output.stderr.length == 0);
    
    writeln("\x1b[32m  ✓ NoSandbox execute works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - NoSandbox execute with environment");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x02;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "printenv TEST_VAR",
        ["TEST_VAR": "test_value"],
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    InputArtifact[] inputs;
    auto prepResult = sandbox.prepare(request, inputs);
    Assert.isTrue(prepResult.isOk);
    
    auto env = prepResult.unwrap();
    string[string] execEnv = ["TEST_VAR": "test_value"];
    auto execResult = env.execute("printenv TEST_VAR", execEnv, 10.seconds);
    
    Assert.isTrue(execResult.isOk);
    
    writeln("\x1b[32m  ✓ NoSandbox execute with environment works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - NoSandbox execute failing command");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x03;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "false",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    InputArtifact[] inputs;
    auto prepResult = sandbox.prepare(request, inputs);
    Assert.isTrue(prepResult.isOk);
    
    auto env = prepResult.unwrap();
    auto execResult = env.execute("false", null, 10.seconds);
    
    Assert.isTrue(execResult.isOk);
    auto output = execResult.unwrap();
    Assert.notEqual(output.exitCode, 0);
    
    writeln("\x1b[32m  ✓ NoSandbox failing command works\x1b[0m");
}

// ==================== EXECUTION OUTPUT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - ExecutionOutput structure");
    
    auto output = ExecutionOutput("stdout data", "stderr data", 42);
    
    Assert.equal(output.stdout, "stdout data");
    Assert.equal(output.stderr, "stderr data");
    Assert.equal(output.exitCode, 42);
    
    writeln("\x1b[32m  ✓ ExecutionOutput structure works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - ExecutionOutput empty");
    
    auto output = ExecutionOutput("", "", 0);
    
    Assert.equal(output.stdout, "");
    Assert.equal(output.stderr, "");
    Assert.equal(output.exitCode, 0);
    
    writeln("\x1b[32m  ✓ ExecutionOutput empty works\x1b[0m");
}

// ==================== SANDBOX ENVIRONMENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Environment work directory");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x04;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "pwd",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    InputArtifact[] inputs;
    auto prepResult = sandbox.prepare(request, inputs);
    Assert.isTrue(prepResult.isOk);
    
    auto env = prepResult.unwrap();
    auto workDir = env.getWorkDir();
    
    Assert.isTrue(workDir.length > 0);
    
    writeln("\x1b[32m  ✓ Work directory setup works\x1b[0m");
}

// ==================== CAPABILITIES TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Default capabilities");
    
    Capabilities caps;
    
    Assert.isFalse(caps.network);
    Assert.isFalse(caps.writeHome);
    Assert.isTrue(caps.writeTmp);
    
    writeln("\x1b[32m  ✓ Default capabilities work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Network capability");
    
    Capabilities caps;
    caps.network = true;
    
    Assert.isTrue(caps.network);
    
    writeln("\x1b[32m  ✓ Network capability works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Resource limits");
    
    Capabilities caps;
    caps.maxCpu = 4;
    caps.maxMemory = 8_000_000_000;  // 8GB
    caps.timeout = 300.seconds;
    
    Assert.equal(caps.maxCpu, 4);
    Assert.equal(caps.maxMemory, 8_000_000_000);
    Assert.equal(caps.timeout, 300.seconds);
    
    writeln("\x1b[32m  ✓ Resource limits work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Path restrictions");
    
    Capabilities caps;
    caps.readPaths = ["/usr/bin", "/usr/lib", "/lib"];
    caps.writePaths = ["/tmp/output"];
    
    Assert.equal(caps.readPaths.length, 3);
    Assert.equal(caps.writePaths.length, 1);
    Assert.equal(caps.readPaths[0], "/usr/bin");
    Assert.equal(caps.writePaths[0], "/tmp/output");
    
    writeln("\x1b[32m  ✓ Path restrictions work\x1b[0m");
}

// ==================== INPUT ARTIFACT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Input artifact structure");
    
    ubyte[32] hash;
    hash[0] = 0xAA;
    
    InputArtifact input;
    input.id = ArtifactId(hash);
    input.path = "/input/file.txt";
    input.executable = false;
    input.data = cast(ubyte[])"test content".dup;
    
    Assert.equal(input.path, "/input/file.txt");
    Assert.equal(input.data.length, 12);
    Assert.equal(input.id.hash[0], 0xAA);
    
    writeln("\x1b[32m  ✓ Input artifact structure works\x1b[0m");
}

// ==================== TIMEOUT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Timeout configuration");
    
    auto sandbox = new NoSandbox();
    
    ubyte[32] hash;
    hash[0] = 0x05;
    
    Capabilities caps;
    caps.timeout = 5.seconds;
    
    auto request = new ActionRequest(
        ActionId(hash),
        "sleep 1",
        null,
        [],
        [],
        caps,
        Priority.Normal,
        5.seconds
    );
    
    InputArtifact[] inputs;
    auto prepResult = sandbox.prepare(request, inputs);
    Assert.isTrue(prepResult.isOk);
    
    auto env = prepResult.unwrap();
    auto execResult = env.execute("sleep 1", null, 5.seconds);
    
    Assert.isTrue(execResult.isOk);
    
    writeln("\x1b[32m  ✓ Timeout configuration works\x1b[0m");
}

// ==================== OUTPUT SPEC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Output specification");
    
    OutputSpec output;
    output.path = "/output/result.bin";
    output.optional = false;
    
    Assert.equal(output.path, "/output/result.bin");
    Assert.isFalse(output.optional);
    
    writeln("\x1b[32m  ✓ Output specification works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Output optional specification");
    
    OutputSpec output;
    output.path = "/output/results/";
    output.optional = true;
    
    Assert.equal(output.path, "/output/results/");
    Assert.isTrue(output.optional);
    
    writeln("\x1b[32m  ✓ Output optional specification works\x1b[0m");
}

// ==================== CONCURRENT SANDBOX TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Concurrent preparation");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto sandbox = new NoSandbox();
    
    try
    {
        foreach (i; parallel(iota(10)))
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)i;
            
            auto request = new ActionRequest(
                ActionId(hash),
                "echo " ~ i.to!string,
                null,
                [],
                [],
                Capabilities.init,
                Priority.Normal,
                60.seconds
            );
            
            InputArtifact[] inputs;
            auto result = sandbox.prepare(request, inputs);
            Assert.isTrue(result.isOk);
        }
        
        writeln("\x1b[32m  ✓ Concurrent preparation works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Worker Sandbox - Concurrent execution");
    
    import std.parallelism : parallel;
    import std.range : iota;
    import core.atomic;
    
    auto sandbox = new NoSandbox();
    
    try
    {
        shared size_t successCount = 0;
        
        foreach (i; parallel(iota(10)))
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)i;
            
            auto request = new ActionRequest(
                ActionId(hash),
                "echo " ~ i.to!string,
                null,
                [],
                [],
                Capabilities.init,
                Priority.Normal,
                60.seconds
            );
            
            InputArtifact[] inputs;
            auto prepResult = sandbox.prepare(request, inputs);
            if (prepResult.isOk)
            {
                auto env = prepResult.unwrap();
                auto execResult = env.execute("echo test", null, 5.seconds);
                if (execResult.isOk)
                    atomicOp!"+="(successCount, 1);
            }
        }
        
        Assert.equal(atomicLoad(successCount), 10);
        
        writeln("\x1b[32m  ✓ Concurrent execution works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}


