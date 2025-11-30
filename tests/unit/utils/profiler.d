module tests.unit.utils.profiler;

import std.stdio;
import std.datetime : dur;
import std.conv : to;
import std.algorithm : canFind;
import core.memory;
import infrastructure.utils.memory.profiler;

unittest
{
    writeln("TEST: MemorySnapshot basic functionality");
    
    auto snap1 = MemorySnapshot.take("initial");
    assert(snap1.label == "initial");
    assert(snap1.heapUsed > 0, "Heap should have some memory used");
    assert(snap1.heapTotal >= snap1.heapUsed, "Total should be >= used");
    assert(snap1.heapTotal == snap1.heapUsed + snap1.heapFree, "Total = used + free");
    
    // Test formatting
    assert(snap1.formatSize(1024) == "1.00 KB");
    assert(snap1.formatSize(1024 * 1024) == "1.00 MB");
    assert(snap1.formatSize(1024 * 1024 * 1024) == "1.00 GB");
    assert(snap1.formatSize(512) == "512 B");
    
    // Test utilization
    auto util = snap1.heapUtilization();
    assert(util >= 0.0 && util <= 100.0, "Utilization should be 0-100%");
    
    // Test toString
    auto str = snap1.toString();
    assert(str.length > 0);
    
    writeln("  ✓ MemorySnapshot works correctly");
}

unittest
{
    writeln("TEST: MemoryDelta calculation");
    
    GC.collect();
    auto before = MemorySnapshot.take("before");
    
    // Allocate 1MB
    auto data = new ubyte[1024 * 1024];
    
    auto after = MemorySnapshot.take("after");
    
    auto delta = MemoryDelta.between(before, after);
    assert(delta.heapUsedDelta >= 0, "Memory should have grown");
    assert(delta.fromLabel == "before");
    assert(delta.toLabel == "after");
    assert(delta.elapsed.total!"msecs" >= 0);
    
    // Test toString
    auto str = delta.toString();
    assert(str.length > 0);
    assert(str.canFind("before"));
    assert(str.canFind("after"));
    
    writeln("  ✓ MemoryDelta calculation works");
}

unittest
{
    writeln("TEST: MemoryProfiler full workflow");
    
    MemoryProfiler profiler;
    profiler.start("initialization");
    
    assert(profiler.isRunning());
    
    // Take snapshots at different points
    profiler.snapshot("checkpoint1");
    
    auto data1 = new ubyte[256 * 1024]; // 256KB
    
    profiler.snapshot("checkpoint2");
    
    auto data2 = new ubyte[256 * 1024]; // Another 256KB
    
    profiler.snapshot("checkpoint3");
    
    auto lastSnapshot = profiler.stop("finalization");
    assert(!profiler.isRunning());
    
    // Should have: start + 3 checkpoints + stop = 5 snapshots
    auto snapshots = profiler.getSnapshots();
    assert(snapshots.length == 5, "Should have 5 snapshots, got " ~ snapshots.length.to!string);
    
    // Test snapshot retrieval by label
    auto checkpoint1 = profiler.getSnapshot("checkpoint1");
    assert(checkpoint1.label == "checkpoint1");
    
    // Test delta calculation
    auto delta12 = profiler.delta("checkpoint1", "checkpoint2");
    assert(delta12.heapUsedDelta >= 0);
    
    auto totalDelta = profiler.totalDelta();
    assert(totalDelta.heapUsedDelta >= 0);
    
    // Test statistics
    auto peakUsed = profiler.peakHeapUsed();
    assert(peakUsed > 0);
    
    auto peakTotal = profiler.peakHeapTotal();
    assert(peakTotal >= peakUsed);
    
    auto gcRuns = profiler.totalGCCollections();
    assert(gcRuns >= 0);
    
    // Test report generation
    auto report = profiler.report();
    assert(report.length > 0);
    assert(report.canFind("Memory Profile Report"));
    assert(report.canFind("checkpoint1"));
    assert(report.canFind("Statistics"));
    
    writeln("  ✓ MemoryProfiler full workflow works");
}

unittest
{
    writeln("TEST: trackMemory helper function");
    
    // Test with void function
    auto delta1 = trackMemory({
        auto data = new ubyte[512 * 1024]; // 512KB
    }, "allocation");
    
    // Note: heap delta can be negative if GC collects during test
    assert(delta1.fromLabel.canFind("allocation"));
    
    // Test with returning function
    auto delta2 = trackMemory(() {
        auto data = new int[1000];
        return data.length;
    }, "int allocation");
    
    assert(delta2.heapUsedDelta >= 0);
    
    writeln("  ✓ trackMemory helper works");
}

unittest
{
    writeln("TEST: MemoryProfiler peak tracking");
    
    MemoryProfiler profiler;
    profiler.start();
    
    // Create increasing allocations
    profiler.snapshot("10KB");
    auto data1 = new ubyte[10 * 1024];
    
    profiler.snapshot("100KB");
    auto data2 = new ubyte[100 * 1024];
    
    profiler.snapshot("1MB");
    auto data3 = new ubyte[1024 * 1024];
    
    profiler.stop();
    
    // Peak should be at least 1MB
    auto peak = profiler.peakHeapUsed();
    assert(peak >= 1024 * 1024, "Peak should include the 1MB allocation");
    
    writeln("  ✓ Peak memory tracking works");
}

unittest
{
    writeln("TEST: MemorySnapshot formatting edge cases");
    
    auto snap = MemorySnapshot.init;
    
    // Test small sizes
    assert(snap.formatSize(0) == "0 B");
    assert(snap.formatSize(1) == "1 B");
    assert(snap.formatSize(999) == "999 B");
    
    // Test KB boundary
    assert(snap.formatSize(1024).canFind("KB"));
    
    // Test MB boundary
    assert(snap.formatSize(1024 * 1024).canFind("MB"));
    
    // Test GB boundary
    assert(snap.formatSize(1024UL * 1024 * 1024).canFind("GB"));
    
    // Test utilization edge cases
    snap.heapTotal = 0;
    snap.heapUsed = 0;
    assert(snap.heapUtilization() == 0.0);
    
    snap.heapTotal = 1000;
    snap.heapUsed = 500;
    assert(snap.heapUtilization() == 50.0);
    
    snap.heapUsed = 1000;
    assert(snap.heapUtilization() == 100.0);
    
    writeln("  ✓ Formatting edge cases handled");
}

unittest
{
    writeln("TEST: MemoryProfiler empty state");
    
    MemoryProfiler profiler;
    
    // Before start
    assert(!profiler.isRunning());
    assert(profiler.getSnapshots().length == 0);
    assert(profiler.peakHeapUsed() == 0);
    assert(profiler.totalGCCollections() == 0);
    
    // Report on empty profiler
    auto report = profiler.report();
    assert(report.canFind("No memory snapshots"));
    
    writeln("  ✓ Empty profiler state handled");
}

unittest
{
    writeln("TEST: MemoryDelta with negative growth (GC freed memory)");
    
    MemorySnapshot before;
    before.heapUsed = 1000;
    before.heapFree = 500;
    before.heapTotal = 1500;
    before.gcCollections = 5;
    before.label = "before";
    
    MemorySnapshot after;
    after.heapUsed = 800;  // Less used (GC collected)
    after.heapFree = 700;  // More free
    after.heapTotal = 1500;
    after.gcCollections = 6;
    after.label = "after";
    
    auto delta = MemoryDelta.between(before, after);
    assert(delta.heapUsedDelta < 0, "Used memory decreased");
    assert(delta.heapFreeDelta > 0, "Free memory increased");
    assert(delta.gcCollectionsDelta == 1);
    
    // Formatting should handle negative deltas
    auto str = delta.toString();
    assert(str.length > 0);
    
    writeln("  ✓ Negative memory growth handled");
}

unittest
{
    writeln("TEST: Multiple profiler instances");
    
    MemoryProfiler profiler1;
    MemoryProfiler profiler2;
    
    profiler1.start("profiler1-start");
    profiler2.start("profiler2-start");
    
    assert(profiler1.isRunning());
    assert(profiler2.isRunning());
    
    profiler1.snapshot("p1-checkpoint");
    profiler2.snapshot("p2-checkpoint");
    
    profiler1.stop("p1-end");
    profiler2.stop("p2-end");
    
    // Each should have independent snapshots
    auto snaps1 = profiler1.getSnapshots();
    auto snaps2 = profiler2.getSnapshots();
    
    assert(snaps1.length == 3); // start + checkpoint + stop
    assert(snaps2.length == 3);
    
    assert(snaps1[0].label == "profiler1-start");
    assert(snaps2[0].label == "profiler2-start");
    
    writeln("  ✓ Multiple profiler instances work independently");
}

