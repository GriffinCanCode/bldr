module tests.unit.utils.mmap;

import infrastructure.utils.memory.mmap;
import std.file : tempDir, write, read, remove, exists, mkdirRecurse, rmdirRecurse;
import std.path : buildPath;
import std.conv : to;
import std.algorithm : all, map;
import std.range : iota;

/// Test basic memory mapping
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_unit_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create test file
    ubyte[4096] testData;
    foreach (i, ref b; testData)
        b = cast(ubyte)(i & 0xFF);
    
    write(testPath, testData);
    
    // Map read-only
    auto region = MmapRegion.map(testPath, MapMode.ReadOnly);
    assert(region !is null, "Failed to map file");
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.valid, "Region should be valid");
    assert(region.length == 4096, "Length mismatch");
    assert(region.mode == MapMode.ReadOnly, "Mode mismatch");
    
    auto data = region[];
    assert(data.length == 4096);
    assert(data[0] == 0);
    assert(data[255] == 255);
    assert(data[256] == 0);
}

/// Test partial mapping with offset
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_partial_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create larger test file
    ubyte[] testData = new ubyte[16384];
    foreach (i, ref b; testData)
        b = cast(ubyte)(i & 0xFF);
    
    write(testPath, testData);
    
    // Map with offset
    auto region = MmapRegion.map(testPath, MapMode.ReadOnly, 4096, 4096);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.length == 4096);
    
    auto data = region[];
    assert(data[0] == 0);  // 4096 & 0xFF = 0
    assert(data[255] == 255);
}

/// Test slicing operations
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_slice_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[1024] testData;
    foreach (i, ref b; testData)
        b = cast(ubyte)i;
    
    write(testPath, testData);
    
    auto region = MmapRegion.map(testPath);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    // Test slice with bounds
    auto slice = region[100 .. 200];
    assert(slice.length == 100);
    assert(slice[0] == 100);
    assert(slice[99] == 199);
    
    // Test index access
    assert(region[50] == 50);
    assert(region[255] == 255);
}

/// Test anonymous mapping
@system unittest
{
    auto region = MmapRegion.anonymous(8192);
    assert(region !is null, "Failed to create anonymous mapping");
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.valid);
    assert(region.length == 8192);
    assert(region.mode == MapMode.Private);
    
    // Should be zero-initialized
    auto data = region[];
    assert(data.all!(b => b == 0), "Anonymous memory should be zero-initialized");
    
    // Write to anonymous memory
    auto mutableSlice = region.mutableSlice();
    assert(mutableSlice !is null);
    mutableSlice[0] = 42;
    mutableSlice[1000] = 123;
    
    assert(region[0] == 42);
    assert(region[1000] == 123);
}

/// Test page size and alignment
@system unittest
{
    auto ps = pageSize();
    assert(ps > 0, "Page size should be positive");
    assert((ps & (ps - 1)) == 0, "Page size should be power of 2");
    
    // Common page sizes
    assert(ps == 4096 || ps == 8192 || ps == 16384 || ps == 65536,
           "Unexpected page size: " ~ ps.to!string);
    
    // Test alignment
    assert(pageAlign(1) == ps);
    assert(pageAlign(ps) == ps);
    assert(pageAlign(ps + 1) == ps * 2);
    assert(pageAlign(ps - 1) == ps);
}

/// Test mmap advice
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_advice_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[65536] testData;
    write(testPath, testData);
    
    auto region = MmapRegion.map(testPath);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    // These should not throw
    region.advise(MapAdvice.Sequential);
    region.advise(MapAdvice.Random);
    region.advise(MapAdvice.WillNeed);
    region.advise(MapAdvice.DontNeed);
    region.advise(MapAdvice.Normal);
}

/// Test statistics tracking
@system unittest
{
    resetMmapStats();
    
    immutable testPath = buildPath(tempDir(), "mmap_stats_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[4096] testData;
    write(testPath, testData);
    
    // Map and access
    auto region = MmapRegion.map(testPath);
    assert(region !is null);
    
    // Access data to trigger stats update
    auto data = region[];
    assert(data.length == 4096);
    
    auto stats = mmapStats();
    assert(stats.mappingsCreated >= 1);
    assert(stats.totalBytesMapped >= 4096);
    
    region.unmap();
    
    stats = mmapStats();
    assert(stats.mappingsClosed >= 1);
}

/// Test error handling - non-existent file
@system unittest
{
    auto region = MmapRegion.map("/nonexistent/path/file.bin");
    assert(region is null, "Should fail for non-existent file");
}

/// Test error handling - empty file
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_empty_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create empty file
    write(testPath, cast(ubyte[])[]);
    
    auto region = MmapRegion.map(testPath);
    assert(region is null, "Should fail for empty file");
}

/// Test error handling - invalid offset
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_offset_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[1024] testData;
    write(testPath, testData);
    
    // Offset beyond file size
    auto region = MmapRegion.map(testPath, MapMode.ReadOnly, 2048, 1024);
    assert(region is null, "Should fail for offset beyond file");
}

/// Test multiple simultaneous mappings
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_multi_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[8192] testData;
    foreach (i, ref b; testData)
        b = cast(ubyte)(i & 0xFF);
    
    write(testPath, testData);
    
    // Create multiple mappings
    MmapRegion[] regions;
    scope(exit) foreach (r; regions) if (r !is null) r.unmap();
    
    foreach (i; 0 .. 4)
    {
        auto region = MmapRegion.map(testPath, MapMode.ReadOnly, i * 2048, 2048);
        assert(region !is null);
        regions ~= region;
    }
    
    // All should be valid
    foreach (r; regions)
        assert(r.valid);
    
    // Data should be consistent
    foreach (i, r; regions)
    {
        auto data = r[];
        assert(data.length == 2048);
        assert(data[0] == cast(ubyte)((i * 2048) & 0xFF));
    }
}

/// Test lock/unlock (may require privileges)
@system unittest
{
    auto region = MmapRegion.anonymous(pageSize());
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    // Lock might fail without privileges, but should not crash
    bool locked = region.lock();
    if (locked)
    {
        bool unlocked = region.unlock();
        // May succeed or fail depending on system state
    }
}

/// Test read-write mapping with sync
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_rw_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create initial file
    ubyte[4096] testData;
    write(testPath, testData);
    
    // Map read-write
    auto region = MmapRegion.map(testPath, MapMode.ReadWrite);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.mode == MapMode.ReadWrite);
    
    // Write through mapping
    auto mutableSlice = region.mutableSlice();
    assert(mutableSlice !is null);
    
    mutableSlice[0] = 0xDE;
    mutableSlice[1] = 0xAD;
    mutableSlice[2] = 0xBE;
    mutableSlice[3] = 0xEF;
    
    // Sync to disk
    bool synced = region.sync(false);  // Synchronous
    
    region.unmap();
    
    // Verify persistence
    auto fileData = cast(ubyte[])read(testPath);
    assert(fileData[0] == 0xDE);
    assert(fileData[1] == 0xAD);
    assert(fileData[2] == 0xBE);
    assert(fileData[3] == 0xEF);
}

/// Test private (copy-on-write) mapping
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_cow_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create initial file with known content
    ubyte[4096] testData;
    testData[0 .. 4] = [1, 2, 3, 4];
    write(testPath, testData);
    
    // Map private (copy-on-write)
    auto region = MmapRegion.map(testPath, MapMode.Private);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.mode == MapMode.Private);
    
    // Initial read
    assert(region[0] == 1);
    assert(region[1] == 2);
    
    // Write through COW mapping
    auto mutableSlice = region.mutableSlice();
    assert(mutableSlice !is null);
    
    mutableSlice[0] = 99;
    
    // Local change visible
    assert(region[0] == 99);
    
    region.unmap();
    
    // File should be unchanged
    auto fileData = cast(ubyte[])read(testPath);
    assert(fileData[0] == 1, "COW should not modify original file");
}

/// Test large file mapping
@system unittest
{
    immutable testPath = buildPath(tempDir(), "mmap_large_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    // Create 1MB file
    immutable size = 1024 * 1024;
    ubyte[] testData = new ubyte[size];
    foreach (i, ref b; testData)
        b = cast(ubyte)(i & 0xFF);
    
    write(testPath, testData);
    
    auto region = MmapRegion.map(testPath);
    assert(region !is null);
    scope(exit) if (region !is null) region.unmap();
    
    assert(region.length == size);
    
    // Spot check data
    auto data = region[];
    assert(data[0] == 0);
    assert(data[255] == 255);
    assert(data[65536] == 0);  // 65536 & 0xFF = 0
    assert(data[size - 1] == ((size - 1) & 0xFF));
}

/// Test error message capture
@system unittest
{
    string error;
    auto region = MmapRegion.map("/nonexistent/file.bin", MapMode.ReadOnly, 0, 0, &error);
    assert(region is null);
    assert(error.length > 0, "Error message should be set");
}
