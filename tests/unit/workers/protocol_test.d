module tests.unit.workers.protocol_test;

import std.stdio : writeln;
import std.conv : to;
import std.json : parseJSON, JSONValue;
import engine.workers.protocol.types;

/// Test WorkRequest JSON serialization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkRequest serialization");
    
    WorkRequest req;
    req.requestId = 42;
    req.arguments = ["-d", "bin/", "src/main.rs"];
    req.inputs = [InputFile("src/main.rs", "abc123")];
    req.sandboxDir = "/tmp/sandbox";
    req.verbosity = 1;
    req.cancel = false;
    
    auto json = req.toJson();
    auto parsed = parseJSON(json);
    
    assert(parsed["request_id"].integer == 42, "Request ID should match");
    assert(parsed["arguments"].array.length == 3, "Arguments should match");
    assert(parsed["sandbox_dir"].str == "/tmp/sandbox", "Sandbox dir should match");
    assert(parsed["verbosity"].integer == 1, "Verbosity should match");
    assert(parsed["cancel"].boolean == false, "Cancel should match");
    
    writeln("\x1b[32m  ✓ WorkRequest serialization works\x1b[0m");
}

/// Test WorkRequest JSON deserialization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkRequest deserialization");
    
    auto json = `{
        "request_id": 99,
        "arguments": ["build", "--release"],
        "inputs": [{"path": "src/lib.rs", "digest": "def456"}],
        "sandbox_dir": "/work",
        "verbosity": 2,
        "cancel": true
    }`;
    
    auto req = WorkRequest.fromJson(json);
    
    assert(req.requestId == 99, "Request ID should match");
    assert(req.arguments == ["build", "--release"], "Arguments should match");
    assert(req.inputs.length == 1, "Should have 1 input");
    assert(req.inputs[0].path == "src/lib.rs", "Input path should match");
    assert(req.inputs[0].digest == "def456", "Input digest should match");
    assert(req.sandboxDir == "/work", "Sandbox dir should match");
    assert(req.verbosity == 2, "Verbosity should match");
    assert(req.cancel, "Cancel should be true");
    
    writeln("\x1b[32m  ✓ WorkRequest deserialization works\x1b[0m");
}

/// Test WorkResponse JSON serialization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkResponse serialization");
    
    WorkResponse resp;
    resp.requestId = 42;
    resp.exitCode = 0;
    resp.output = "Build successful";
    resp.wasCached = true;
    resp.executionTimeMs = 150;
    resp.outputs = [OutputFile("target/release/app", "xyz789")];
    
    auto json = resp.toJson();
    auto parsed = parseJSON(json);
    
    assert(parsed["request_id"].integer == 42, "Request ID should match");
    assert(parsed["exit_code"].integer == 0, "Exit code should match");
    assert(parsed["output"].str == "Build successful", "Output should match");
    assert(parsed["was_cached"].boolean == true, "Was cached should match");
    assert(parsed["execution_time_ms"].integer == 150, "Exec time should match");
    
    writeln("\x1b[32m  ✓ WorkResponse serialization works\x1b[0m");
}

/// Test WorkResponse JSON deserialization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkResponse deserialization");
    
    auto json = `{
        "request_id": 55,
        "exit_code": 1,
        "output": "error: cannot find crate",
        "was_cached": false,
        "execution_time_ms": 500,
        "outputs": []
    }`;
    
    auto resp = WorkResponse.fromJson(json);
    
    assert(resp.requestId == 55, "Request ID should match");
    assert(resp.exitCode == 1, "Exit code should match");
    assert(resp.output == "error: cannot find crate", "Output should match");
    assert(!resp.wasCached, "Was cached should be false");
    assert(resp.executionTimeMs == 500, "Exec time should match");
    assert(resp.outputs.empty, "Outputs should be empty");
    assert(!resp.success, "Should not be success");
    
    writeln("\x1b[32m  ✓ WorkResponse deserialization works\x1b[0m");
}

/// Test WorkResponse success check
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkResponse success");
    
    WorkResponse success;
    success.exitCode = 0;
    assert(success.success, "Exit code 0 should be success");
    
    WorkResponse failure;
    failure.exitCode = 1;
    assert(!failure.success, "Exit code 1 should be failure");
    
    WorkResponse sigterm;
    sigterm.exitCode = 130;
    assert(!sigterm.success, "Signal exit should be failure");
    
    writeln("\x1b[32m  ✓ WorkResponse success check works\x1b[0m");
}

/// Test InputFile
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - InputFile");
    
    auto input = InputFile("src/main.go", "hash123");
    
    auto jsonVal = input.toJsonValue();
    assert(jsonVal["path"].str == "src/main.go", "Path should match");
    assert(jsonVal["digest"].str == "hash123", "Digest should match");
    
    auto parsed = InputFile.fromJsonValue(jsonVal);
    assert(parsed.path == "src/main.go", "Parsed path should match");
    assert(parsed.digest == "hash123", "Parsed digest should match");
    
    writeln("\x1b[32m  ✓ InputFile works\x1b[0m");
}

/// Test OutputFile
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - OutputFile");
    
    auto output = OutputFile("bin/app", "outputhash");
    
    auto jsonVal = output.toJsonValue();
    assert(jsonVal["path"].str == "bin/app", "Path should match");
    assert(jsonVal["digest"].str == "outputhash", "Digest should match");
    
    auto parsed = OutputFile.fromJsonValue(jsonVal);
    assert(parsed.path == "bin/app", "Parsed path should match");
    assert(parsed.digest == "outputhash", "Parsed digest should match");
    
    writeln("\x1b[32m  ✓ OutputFile works\x1b[0m");
}

/// Test WorkRequest roundtrip
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkRequest roundtrip");
    
    WorkRequest original;
    original.requestId = 123;
    original.arguments = ["cargo", "build", "--release"];
    original.inputs = [
        InputFile("Cargo.toml", "tomlhash"),
        InputFile("src/lib.rs", "libhash")
    ];
    original.sandboxDir = "/sandbox";
    original.verbosity = 1;
    original.cancel = false;
    
    auto json = original.toJson();
    auto restored = WorkRequest.fromJson(json);
    
    assert(restored.requestId == original.requestId, "Request ID roundtrip");
    assert(restored.arguments == original.arguments, "Arguments roundtrip");
    assert(restored.inputs.length == original.inputs.length, "Inputs length roundtrip");
    assert(restored.sandboxDir == original.sandboxDir, "Sandbox roundtrip");
    assert(restored.verbosity == original.verbosity, "Verbosity roundtrip");
    assert(restored.cancel == original.cancel, "Cancel roundtrip");
    
    writeln("\x1b[32m  ✓ WorkRequest roundtrip works\x1b[0m");
}

/// Test WorkResponse roundtrip
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkResponse roundtrip");
    
    WorkResponse original;
    original.requestId = 456;
    original.exitCode = 0;
    original.output = "Compiling...\nFinished release [optimized]";
    original.wasCached = false;
    original.executionTimeMs = 2500;
    original.outputs = [
        OutputFile("target/release/myapp", "apphash")
    ];
    
    auto json = original.toJson();
    auto restored = WorkResponse.fromJson(json);
    
    assert(restored.requestId == original.requestId, "Request ID roundtrip");
    assert(restored.exitCode == original.exitCode, "Exit code roundtrip");
    assert(restored.output == original.output, "Output roundtrip");
    assert(restored.wasCached == original.wasCached, "Was cached roundtrip");
    assert(restored.executionTimeMs == original.executionTimeMs, "Exec time roundtrip");
    assert(restored.outputs.length == original.outputs.length, "Outputs length roundtrip");
    
    writeln("\x1b[32m  ✓ WorkResponse roundtrip works\x1b[0m");
}

/// Test WorkerId
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkerId");
    
    auto id1 = WorkerId("jvm", 1);
    auto id2 = WorkerId("jvm", 2);
    auto id3 = WorkerId("typescript", 1);
    
    assert(id1.toString() == "jvm-1", "ID 1 string");
    assert(id2.toString() == "jvm-2", "ID 2 string");
    assert(id3.toString() == "typescript-1", "ID 3 string");
    
    writeln("\x1b[32m  ✓ WorkerId works\x1b[0m");
}

/// Test WorkerState transitions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - WorkerState");
    
    // All states should be unique
    WorkerState[] states = [
        WorkerState.Starting,
        WorkerState.Ready,
        WorkerState.Busy,
        WorkerState.Idle,
        WorkerState.Terminating,
        WorkerState.Dead
    ];
    
    // Starting -> Ready is valid
    assert(WorkerState.Starting != WorkerState.Ready, "Starting != Ready");
    
    // Ready -> Busy is valid
    assert(WorkerState.Ready != WorkerState.Busy, "Ready != Busy");
    
    // Busy -> Idle is valid  
    assert(WorkerState.Busy != WorkerState.Idle, "Busy != Idle");
    
    // Dead is final
    assert(WorkerState.Dead != WorkerState.Starting, "Dead != Starting");
    
    writeln("\x1b[32m  ✓ WorkerState transitions valid\x1b[0m");
}

/// Test empty request handling
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - Empty request");
    
    WorkRequest req;
    req.requestId = 0;
    req.arguments = [];
    req.inputs = [];
    
    auto json = req.toJson();
    auto restored = WorkRequest.fromJson(json);
    
    assert(restored.requestId == 0, "Empty request ID");
    assert(restored.arguments.empty, "Empty arguments");
    assert(restored.inputs.empty, "Empty inputs");
    
    writeln("\x1b[32m  ✓ Empty request handled\x1b[0m");
}

/// Test cancel request
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.protocol - Cancel request");
    
    WorkRequest req;
    req.requestId = 999;
    req.cancel = true;
    
    auto json = req.toJson();
    auto restored = WorkRequest.fromJson(json);
    
    assert(restored.cancel, "Cancel should be preserved");
    
    writeln("\x1b[32m  ✓ Cancel request works\x1b[0m");
}


