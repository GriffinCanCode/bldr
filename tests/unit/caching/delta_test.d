module tests.unit.caching.delta_test;

import engine.caching.distributed.remote.delta;
import std.conv : to;
import std.file : exists, rmdirRecurse, mkdirRecurse;
import std.path : buildPath;

/// Test RollingChecksum basic operations
@("RollingChecksum: init and digest")
unittest
{
    auto data = cast(ubyte[])[1, 2, 3, 4, 5, 6, 7, 8];
    auto rc = RollingChecksum.create(4);
    
    rc.init(data[0 .. 4]);
    auto hash1 = rc.digest();
    
    // Rolling forward should produce different hash
    rc.roll(data[0], data[4]);
    auto hash2 = rc.digest();
    
    assert(hash1 != hash2, "Rolling should change checksum");
    
    // Full checksum should match init
    auto fullHash = RollingChecksum.full(data[0 .. 4]);
    
    // Reinit and compare
    auto rc2 = RollingChecksum.create(4);
    rc2.init(data[0 .. 4]);
    assert(rc2.digest() == fullHash);
}

@("RollingChecksum: deterministic results")
unittest
{
    auto data = cast(ubyte[])"hello world test data for rolling checksum";
    
    auto hash1 = RollingChecksum.full(data);
    auto hash2 = RollingChecksum.full(data);
    
    assert(hash1 == hash2, "Same data should produce same hash");
}

@("RollingChecksum: different data produces different hash")
unittest
{
    auto data1 = cast(ubyte[])"hello";
    auto data2 = cast(ubyte[])"world";
    
    assert(RollingChecksum.full(data1) != RollingChecksum.full(data2));
}

/// Test BlockSignature serialization
@("BlockSignature: serialize and deserialize")
unittest
{
    BlockSignature sig;
    sig.offset = 12345;
    sig.weakHash = 0xDEADBEEF;
    sig.strongHash[] = 0xAB;
    
    auto serialized = sig.serialize();
    auto deserialized = BlockSignature.deserialize(serialized);
    
    assert(deserialized.offset == sig.offset);
    assert(deserialized.weakHash == sig.weakHash);
    assert(deserialized.strongHash == sig.strongHash);
}

/// Test RsyncDelta signature generation
@("RsyncDelta: signature generation")
unittest
{
    auto rsync = new RsyncDelta(16);  // Small block size for testing
    
    auto data = cast(ubyte[])"0123456789ABCDEF" ~ // Block 1
                cast(ubyte[])"GHIJKLMNOPQRSTUV" ~ // Block 2
                cast(ubyte[])"WXYZ";              // Partial block
    
    auto sigs = rsync.generateSignatures(data);
    
    assert(sigs.length == 3);  // 2 full blocks + 1 partial
    assert(sigs[0].offset == 0);
    assert(sigs[1].offset == 16);
    assert(sigs[2].offset == 32);
}

/// Test RsyncDelta delta computation with identical data
@("RsyncDelta: identical data produces copy-only delta")
unittest
{
    auto rsync = new RsyncDelta(16);
    
    auto data = cast(ubyte[])"0123456789ABCDEFGHIJKLMNOPQRSTUV";
    
    auto sigs = rsync.generateSignatures(data);
    auto delta = rsync.computeDelta(data, sigs);
    
    // All blocks should be copy operations
    foreach (inst; delta)
        assert(inst.op == DeltaOp.Copy, "Identical data should produce only copy ops");
}

/// Test RsyncDelta delta computation with modifications
@("RsyncDelta: modified data produces mixed delta")
unittest
{
    auto rsync = new RsyncDelta(16);
    
    auto oldData = cast(ubyte[])"0123456789ABCDEFGHIJKLMNOPQRSTUV";
    auto newData = cast(ubyte[])"0123456789ABCDEF" ~ // Same first block
                   cast(ubyte[])"MODIFIED_BLOCK__" ~ // Changed second block
                   cast(ubyte[])"NEW_DATA";          // New data
    
    auto sigs = rsync.generateSignatures(oldData);
    auto delta = rsync.computeDelta(newData, sigs);
    
    // Should have mix of copy and insert
    bool hasCopy, hasInsert;
    foreach (inst; delta)
    {
        if (inst.op == DeltaOp.Copy) hasCopy = true;
        if (inst.op == DeltaOp.Insert) hasInsert = true;
    }
    
    assert(hasCopy, "Should have copy operations for unchanged blocks");
    assert(hasInsert, "Should have insert operations for new/changed data");
}

/// Test RsyncDelta apply delta
@("RsyncDelta: apply delta reconstructs data")
unittest
{
    auto rsync = new RsyncDelta(16);
    
    auto oldData = cast(ubyte[])"0123456789ABCDEFGHIJKLMNOPQRSTUV";
    auto newData = cast(ubyte[])"0123456789ABCDEFNEW_DATA_HERE__X";
    
    auto sigs = rsync.generateSignatures(oldData);
    auto delta = rsync.computeDelta(newData, sigs);
    
    auto result = rsync.applyDelta(oldData, delta);
    assert(result.isOk);
    assert(result.unwrap() == newData);
}

/// Test RsyncDelta serialization
@("RsyncDelta: delta serialization roundtrip")
unittest
{
    auto rsync = new RsyncDelta(16);
    
    auto oldData = cast(ubyte[])"AAAABBBBCCCCDDDD";
    auto newData = cast(ubyte[])"AAAABBBBEEEEXXXX";
    
    auto sigs = rsync.generateSignatures(oldData);
    auto delta = rsync.computeDelta(newData, sigs);
    
    auto serialized = RsyncDelta.serializeDelta(delta);
    auto deserResult = RsyncDelta.deserializeDelta(serialized);
    
    assert(deserResult.isOk);
    auto deserialized = deserResult.unwrap();
    
    assert(deserialized.length == delta.length);
    
    foreach (i, inst; deserialized)
    {
        assert(inst.op == delta[i].op);
        assert(inst.offset == delta[i].offset);
        assert(inst.length == delta[i].length);
        if (inst.op == DeltaOp.Insert)
            assert(inst.data == delta[i].data);
    }
}

/// Test DeltaTransfer size threshold
@("DeltaTransfer: size threshold check")
unittest
{
    // Small data should not use delta
    assert(!DeltaTransfer.shouldUseDelta(50 * 1024 * 1024));  // 50MB
    
    // Large data should use delta  
    assert(DeltaTransfer.shouldUseDelta(100 * 1024 * 1024));  // 100MB
    assert(DeltaTransfer.shouldUseDelta(200 * 1024 * 1024));  // 200MB
}

/// Test TransferResult statistics
@("TransferResult: statistics calculations")
unittest
{
    TransferResult r;
    r.totalSize = 1000;
    r.bytesTransferred = 200;
    r.bytesSaved = 800;
    r.chunksTotal = 10;
    r.chunksTransferred = 2;
    
    assert(r.savingsPercent() == 80.0);  // 800/1000 * 100
    assert(r.efficiency() == 80.0);      // (10-2)/10 * 100
}

/// Test aggregateResults
@("aggregateResults: combines multiple transfers")
unittest
{
    TransferResult[] results;
    
    TransferResult r1;
    r1.totalSize = 1000;
    r1.bytesTransferred = 200;
    r1.bytesSaved = 800;
    r1.chunksTotal = 10;
    r1.chunksTransferred = 2;
    results ~= r1;
    
    TransferResult r2;
    r2.totalSize = 500;
    r2.bytesTransferred = 100;
    r2.bytesSaved = 400;
    r2.chunksTotal = 5;
    r2.chunksTransferred = 1;
    results ~= r2;
    
    auto agg = aggregateResults(results);
    
    assert(agg.totalSize == 1500);
    assert(agg.bytesTransferred == 300);
    assert(agg.bytesSaved == 1200);
    assert(agg.chunksTotal == 15);
    assert(agg.chunksTransferred == 3);
}

/// Test DeltaPackage statistics
@("DeltaPackage: savings calculation")
unittest
{
    DeltaPackage pkg;
    pkg.originalNewSize = 1000;
    pkg.deltaSize = 100;
    
    assert(pkg.savingsPercent() == 90.0);  // (1000-100)/1000 * 100
}

/// Test DeltaCompressionStats
@("DeltaCompressionStats: compression ratio")
unittest
{
    DeltaCompressionStats stats;
    stats.deltasCreated = 5;
    stats.totalOriginalBytes = 10000;
    stats.totalDeltaBytes = 2000;
    
    assert(stats.compressionRatio() == 0.2);  // 2000/10000
    assert(stats.bytesSaved() == 8000);
}

/// Test empty data handling
@("RollingChecksum: empty data handling")
unittest
{
    ubyte[] empty;
    auto hash = RollingChecksum.full(empty);
    assert(hash == 0);  // Empty data should produce zero hash
}

/// Test large block delta
@("RsyncDelta: large data delta computation")
unittest
{
    auto rsync = new RsyncDelta(1024);  // 1KB blocks
    
    // Create 10KB of test data
    ubyte[] oldData;
    foreach (i; 0 .. 10 * 1024)
        oldData ~= cast(ubyte)(i % 256);
    
    // Modify only the middle
    auto newData = oldData.dup;
    newData[5 * 1024 .. 6 * 1024] = 0xFF;  // Change one block
    
    auto sigs = rsync.generateSignatures(oldData);
    auto delta = rsync.computeDelta(newData, sigs);
    
    // Most blocks should be copied
    size_t copyCount, insertCount;
    foreach (inst; delta)
    {
        if (inst.op == DeltaOp.Copy) copyCount++;
        else insertCount++;
    }
    
    // Should have 9 copies (unchanged) and some inserts (changed block)
    assert(copyCount >= 9, "Most blocks should be copied");
    
    // Verify reconstruction
    auto result = rsync.applyDelta(oldData, delta);
    assert(result.isOk);
    assert(result.unwrap() == newData);
}


