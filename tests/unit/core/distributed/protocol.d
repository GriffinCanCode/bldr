module tests.unit.core.distributed.protocol;

import std.stdio;
import std.datetime;
import std.conv;
import std.digest : toHexString;
import engine.distributed.protocol.protocol;
import tests.harness;

// ==================== MESSAGE ID TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - MessageId generation");
    
    auto msg1 = MessageId.generate();
    auto msg2 = MessageId.generate();
    
    // IDs should be unique
    Assert.notEqual(msg1.value, msg2.value);
    
    // Should be able to convert to string
    auto str = msg1.toString();
    Assert.isTrue(str.length > 0);
    
    writeln("\x1b[32m  ✓ MessageId generation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - MessageId equality");
    
    auto msg1 = MessageId(12345);
    auto msg2 = MessageId(12345);
    auto msg3 = MessageId(54321);
    
    Assert.equal(msg1.value, msg2.value);
    Assert.notEqual(msg1.value, msg3.value);
    
    writeln("\x1b[32m  ✓ MessageId equality works\x1b[0m");
}

// ==================== WORKER ID TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - WorkerId creation");
    
    auto worker1 = WorkerId(1);
    auto worker2 = WorkerId(2);
    
    Assert.equal(worker1.value, 1);
    Assert.equal(worker2.value, 2);
    Assert.notEqual(worker1.value, worker2.value);
    
    writeln("\x1b[32m  ✓ WorkerId creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - WorkerId broadcast");
    
    auto broadcast = WorkerId.broadcast();
    
    Assert.equal(broadcast.value, 0);
    Assert.isTrue(broadcast.isBroadcast());
    
    auto normalWorker = WorkerId(5);
    Assert.isFalse(normalWorker.isBroadcast());
    
    writeln("\x1b[32m  ✓ WorkerId broadcast works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - WorkerId toString");
    
    auto worker = WorkerId(42);
    auto str = worker.toString();
    
    Assert.equal(str, "42");
    
    writeln("\x1b[32m  ✓ WorkerId toString works\x1b[0m");
}

// ==================== ACTION ID TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - ActionId creation");
    
    ubyte[32] hash1;
    hash1[0] = 0xAA;
    hash1[1] = 0xBB;
    hash1[31] = 0xFF;
    
    auto action1 = ActionId(hash1);
    
    Assert.equal(action1.hash[0], 0xAA);
    Assert.equal(action1.hash[1], 0xBB);
    Assert.equal(action1.hash[31], 0xFF);
    
    writeln("\x1b[32m  ✓ ActionId creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - ActionId equality");
    
    ubyte[32] hash1;
    hash1[0] = 0x01;
    
    ubyte[32] hash2;
    hash2[0] = 0x01;
    
    ubyte[32] hash3;
    hash3[0] = 0x02;
    
    auto action1 = ActionId(hash1);
    auto action2 = ActionId(hash2);
    auto action3 = ActionId(hash3);
    
    Assert.isTrue(action1 == action2);
    Assert.isFalse(action1 == action3);
    
    writeln("\x1b[32m  ✓ ActionId equality works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - ActionId toString");
    
    ubyte[32] hash;
    hash[0] = 0xAB;
    hash[1] = 0xCD;
    hash[2] = 0xEF;
    
    auto action = ActionId(hash);
    auto str = action.toString();
    
    // Should be hex string (lowercase)
    Assert.isTrue(str.length > 0);
    Assert.isTrue(str[0..2] == "ab");
    Assert.isTrue(str[2..4] == "cd");
    Assert.isTrue(str[4..6] == "ef");
    
    writeln("\x1b[32m  ✓ ActionId toString works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - ActionId hashing");
    
    ubyte[32] hash1;
    hash1[0] = 0x01;
    
    ubyte[32] hash2;
    hash2[0] = 0x02;
    
    auto action1 = ActionId(hash1);
    auto action2 = ActionId(hash2);
    
    // Hash function should produce different values for different actions
    Assert.notEqual(action1.toHash(), action2.toHash());
    
    // Same action should have same hash
    auto action1copy = ActionId(hash1);
    Assert.equal(action1.toHash(), action1copy.toHash());
    
    writeln("\x1b[32m  ✓ ActionId hashing works\x1b[0m");
}

// ==================== WORKER STATE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - WorkerState enum values");
    
    Assert.equal(cast(ubyte)WorkerState.Idle, 0);
    Assert.equal(cast(ubyte)WorkerState.Executing, 1);
    Assert.equal(cast(ubyte)WorkerState.Stealing, 2);
    Assert.equal(cast(ubyte)WorkerState.Uploading, 3);
    Assert.equal(cast(ubyte)WorkerState.Failed, 4);
    Assert.equal(cast(ubyte)WorkerState.Draining, 5);
    
    writeln("\x1b[32m  ✓ WorkerState enum values correct\x1b[0m");
}

// ==================== RESULT STATUS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - ResultStatus enum values");
    
    Assert.equal(cast(ubyte)ResultStatus.Success, 0);
    Assert.equal(cast(ubyte)ResultStatus.Failure, 1);
    Assert.equal(cast(ubyte)ResultStatus.Timeout, 2);
    Assert.equal(cast(ubyte)ResultStatus.Cancelled, 3);
    Assert.equal(cast(ubyte)ResultStatus.Error, 4);
    
    writeln("\x1b[32m  ✓ ResultStatus enum values correct\x1b[0m");
}

// ==================== PRIORITY TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Priority enum values");
    
    Assert.equal(cast(ubyte)Priority.Low, 0);
    Assert.equal(cast(ubyte)Priority.Normal, 50);
    Assert.equal(cast(ubyte)Priority.High, 100);
    Assert.equal(cast(ubyte)Priority.Critical, 200);
    
    // Priorities should be ordered
    Assert.isTrue(Priority.Low < Priority.Normal);
    Assert.isTrue(Priority.Normal < Priority.High);
    Assert.isTrue(Priority.High < Priority.Critical);
    
    writeln("\x1b[32m  ✓ Priority enum values correct\x1b[0m");
}

// ==================== CAPABILITIES TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Capabilities default values");
    
    Capabilities caps;
    
    Assert.isFalse(caps.network);
    Assert.isFalse(caps.writeHome);
    Assert.isTrue(caps.writeTmp);
    Assert.equal(caps.readPaths.length, 0);
    Assert.equal(caps.writePaths.length, 0);
    Assert.equal(caps.maxCpu, 0);
    Assert.equal(caps.maxMemory, 0);
    Assert.equal(caps.timeout, 1.seconds);
    
    writeln("\x1b[32m  ✓ Capabilities default values correct\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Capabilities custom values");
    
    Capabilities caps;
    caps.network = true;
    caps.writeHome = true;
    caps.writeTmp = false;
    caps.readPaths = ["/usr/bin", "/usr/lib"];
    caps.writePaths = ["/tmp/output"];
    caps.maxCpu = 4;
    caps.maxMemory = 8_000_000_000;
    caps.timeout = 600.seconds;
    
    Assert.isTrue(caps.network);
    Assert.isTrue(caps.writeHome);
    Assert.isFalse(caps.writeTmp);
    Assert.equal(caps.readPaths.length, 2);
    Assert.equal(caps.writePaths.length, 1);
    Assert.equal(caps.maxCpu, 4);
    Assert.equal(caps.maxMemory, 8_000_000_000);
    Assert.equal(caps.timeout, 600.seconds);
    
    writeln("\x1b[32m  ✓ Capabilities custom values work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Capabilities serialization");
    
    Capabilities caps;
    caps.network = true;
    caps.writeHome = false;
    caps.writeTmp = true;
    caps.readPaths = ["/usr/bin"];
    caps.writePaths = ["/tmp"];
    caps.maxCpu = 8;
    caps.maxMemory = 16_000_000_000;
    caps.timeout = 300.seconds;
    
    // Serialize
    auto serialized = caps.serialize();
    Assert.isTrue(serialized.length > 0);
    
    // Deserialize
    auto parseResult = Capabilities.deserialize(serialized);
    Assert.isTrue(parseResult.isOk);
    
    auto parsed = parseResult.unwrap();
    Assert.equal(parsed.network, caps.network);
    Assert.equal(parsed.writeHome, caps.writeHome);
    Assert.equal(parsed.writeTmp, caps.writeTmp);
    Assert.equal(parsed.maxCpu, caps.maxCpu);
    Assert.equal(parsed.maxMemory, caps.maxMemory);
    
    writeln("\x1b[32m  ✓ Capabilities serialization works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Capabilities empty serialization");
    
    Capabilities caps;  // All defaults
    
    auto serialized = caps.serialize();
    Assert.isTrue(serialized.length > 0);
    
    auto parseResult = Capabilities.deserialize(serialized);
    Assert.isTrue(parseResult.isOk);
    
    auto parsed = parseResult.unwrap();
    Assert.equal(parsed.network, false);
    Assert.equal(parsed.writeHome, false);
    Assert.equal(parsed.writeTmp, true);
    
    writeln("\x1b[32m  ✓ Capabilities empty serialization works\x1b[0m");
}

// ==================== COMPRESSION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Protocol - Compression enum values");
    
    Assert.equal(cast(ubyte)Compression.None, 0);
    Assert.equal(cast(ubyte)Compression.Zstd, 1);
    Assert.equal(cast(ubyte)Compression.Lz4, 2);
    
    writeln("\x1b[32m  ✓ Compression enum values correct\x1b[0m");
}

