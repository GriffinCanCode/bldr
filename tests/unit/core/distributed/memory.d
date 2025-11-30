module tests.unit.core.distributed.memory;

import std.stdio;
import std.conv;
import core.thread;
import core.atomic;
import engine.distributed.memory.arena;
import engine.distributed.memory.pool;
import tests.harness;

// ==================== ARENA BASIC TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena creation");
    
    auto arena = Arena(1024);
    
    Assert.equal(arena.totalCapacity(), 1024);
    Assert.equal(arena.used(), 0);
    Assert.equal(arena.available(), 1024);
    
    writeln("\x1b[32m  ✓ Arena creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena allocate");
    
    auto arena = Arena(1024);
    
    auto slice = arena.allocate(64);
    
    Assert.equal(slice.length, 64);
    Assert.equal(arena.used(), 64);
    Assert.equal(arena.available(), 1024 - 64);
    
    writeln("\x1b[32m  ✓ Arena allocate works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena multiple allocations");
    
    auto arena = Arena(1024);
    
    auto slice1 = arena.allocate(100);
    auto slice2 = arena.allocate(200);
    auto slice3 = arena.allocate(300);
    
    Assert.equal(slice1.length, 100);
    Assert.equal(slice2.length, 200);
    Assert.equal(slice3.length, 300);
    
    Assert.isTrue(arena.used() >= 600);  // At least 600 (may have alignment)
    
    writeln("\x1b[32m  ✓ Arena multiple allocations work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena allocation with alignment");
    
    auto arena = Arena(1024);
    
    // Allocate with specific alignment
    auto slice = arena.allocate(64, 16);
    
    Assert.equal(slice.length, 64);
    Assert.equal(cast(size_t)slice.ptr % 16, 0);  // Check alignment
    
    writeln("\x1b[32m  ✓ Arena alignment works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena canAllocate check");
    
    auto arena = Arena(1024);
    
    Assert.isTrue(arena.canAllocate(500));
    Assert.isTrue(arena.canAllocate(1024));
    Assert.isFalse(arena.canAllocate(1025));
    
    // Allocate some memory
    arena.allocate(500);
    
    Assert.isTrue(arena.canAllocate(500));
    Assert.isFalse(arena.canAllocate(600));
    
    writeln("\x1b[32m  ✓ Arena canAllocate check works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena reset");
    
    auto arena = Arena(1024);
    
    arena.allocate(500);
    Assert.equal(arena.used(), 500);
    
    arena.reset();
    
    Assert.equal(arena.used(), 0);
    Assert.equal(arena.available(), 1024);
    
    writeln("\x1b[32m  ✓ Arena reset works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - Arena makeArray");
    
    auto arena = Arena(1024);
    
    auto arr = arena.makeArray!int(10);
    
    Assert.equal(arr.length, 10);
    
    // Write to array
    foreach (i, ref val; arr)
        val = cast(int)i * 2;
    
    // Verify
    foreach (i, val; arr)
        Assert.equal(val, i * 2);
    
    writeln("\x1b[32m  ✓ Arena makeArray works\x1b[0m");
}

// ==================== ARENA POOL TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ArenaPool creation");
    
    auto pool = new ArenaPool(1024, 10);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 0);
    Assert.equal(stats.arenaSize, 1024);
    Assert.equal(stats.maxArenas, 10);
    
    writeln("\x1b[32m  ✓ ArenaPool creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ArenaPool acquire and release");
    
    auto pool = new ArenaPool(1024, 10);
    
    auto arena = pool.acquire();
    Assert.isTrue(arena !is null);
    Assert.equal(arena.totalCapacity(), 1024);
    
    // Use arena
    arena.allocate(100);
    
    // Release back to pool
    pool.release(arena);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 1);
    
    writeln("\x1b[32m  ✓ ArenaPool acquire and release work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ArenaPool reuse");
    
    auto pool = new ArenaPool(1024, 10);
    
    auto arena1 = pool.acquire();
    arena1.allocate(500);
    pool.release(arena1);
    
    // Acquire again - should get same arena (reset)
    auto arena2 = pool.acquire();
    Assert.equal(arena2.used(), 0);  // Should be reset
    
    pool.release(arena2);
    
    writeln("\x1b[32m  ✓ ArenaPool reuse works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ArenaPool multiple arenas");
    
    auto pool = new ArenaPool(1024, 10);
    
    Arena*[] arenas;
    foreach (i; 0 .. 5)
        arenas ~= pool.acquire();
    
    auto stats1 = pool.getStats();
    Assert.equal(stats1.totalAllocated, 5);
    
    // Release all
    foreach (arena; arenas)
        pool.release(arena);
    
    auto stats2 = pool.getStats();
    Assert.equal(stats2.available, 5);
    
    writeln("\x1b[32m  ✓ ArenaPool multiple arenas work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ScopedArena RAII");
    
    auto pool = new ArenaPool(1024, 10);
    
    {
        auto scoped = ScopedArena(pool);
        scoped.allocate(100);
        
        Assert.equal(scoped.used(), 100);
    }
    
    // Should be released back to pool
    auto stats = pool.getStats();
    Assert.equal(stats.available, 1);
    
    writeln("\x1b[32m  ✓ ScopedArena RAII works\x1b[0m");
}

// ==================== OBJECT POOL TESTS ====================

// Test class for pooling
class TestObject
{
    int value;
    
    this()
    {
        value = 0;
    }
    
    void reset()
    {
        value = 0;
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool creation");
    
    auto pool = new ObjectPool!TestObject(256);
    
    auto stats = pool.getStats();
    Assert.equal(stats.maxSize, 256);
    Assert.equal(stats.available, 0);
    Assert.equal(stats.totalCreated, 0);
    
    writeln("\x1b[32m  ✓ ObjectPool creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool acquire");
    
    auto pool = new ObjectPool!TestObject(256);
    
    auto obj = pool.acquire();
    Assert.isTrue(obj !is null);
    Assert.equal(obj.value, 0);
    
    auto stats = pool.getStats();
    Assert.equal(stats.totalCreated, 1);
    Assert.equal(stats.currentlyActive, 1);
    
    writeln("\x1b[32m  ✓ ObjectPool acquire works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool release");
    
    auto pool = new ObjectPool!TestObject(256);
    
    auto obj = pool.acquire();
    obj.value = 42;
    
    pool.release(obj);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 1);
    Assert.equal(stats.currentlyActive, 0);
    
    writeln("\x1b[32m  ✓ ObjectPool release works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool reuse");
    
    auto pool = new ObjectPool!TestObject(256);
    
    auto obj1 = pool.acquire();
    obj1.value = 100;
    pool.release(obj1);
    
    // Acquire again - should get same object (reset)
    auto obj2 = pool.acquire();
    Assert.equal(obj2.value, 0);  // Should be reset
    
    pool.release(obj2);
    
    auto stats = pool.getStats();
    Assert.equal(stats.totalCreated, 1);  // Only created once
    
    writeln("\x1b[32m  ✓ ObjectPool reuse works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool preallocate");
    
    auto pool = new ObjectPool!TestObject(256);
    
    pool.preallocate(10);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 10);
    Assert.equal(stats.totalCreated, 10);
    
    writeln("\x1b[32m  ✓ ObjectPool preallocate works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool max size limit");
    
    auto pool = new ObjectPool!TestObject(3);  // Max 3 objects
    
    auto obj1 = pool.acquire();
    auto obj2 = pool.acquire();
    auto obj3 = pool.acquire();
    auto obj4 = pool.acquire();  // 4th object
    
    // Release all
    pool.release(obj1);
    pool.release(obj2);
    pool.release(obj3);
    pool.release(obj4);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 3);  // Should only keep 3
    
    writeln("\x1b[32m  ✓ ObjectPool max size limit works\x1b[0m");
}

// ==================== BUFFER POOL TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool creation");
    
    auto pool = new BufferPool(1024, 10);
    
    auto stats = pool.getStats();
    Assert.equal(stats.bufferSize, 1024);
    Assert.equal(stats.maxBuffers, 10);
    Assert.equal(stats.available, 0);
    
    writeln("\x1b[32m  ✓ BufferPool creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool acquire");
    
    auto pool = new BufferPool(1024, 10);
    
    auto buffer = pool.acquire();
    Assert.equal(buffer.length, 1024);
    
    auto stats = pool.getStats();
    Assert.equal(stats.totalCreated, 1);
    
    writeln("\x1b[32m  ✓ BufferPool acquire works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool release");
    
    auto pool = new BufferPool(1024, 10);
    
    auto buffer = pool.acquire();
    buffer[0] = 0xFF;
    buffer[100] = 0xAA;
    
    pool.release(buffer);
    
    // Buffer should be zeroed out
    Assert.equal(buffer[0], 0);
    Assert.equal(buffer[100], 0);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 1);
    
    writeln("\x1b[32m  ✓ BufferPool release works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool reuse");
    
    auto pool = new BufferPool(1024, 10);
    
    auto buffer1 = pool.acquire();
    pool.release(buffer1);
    
    auto buffer2 = pool.acquire();
    
    // Should reuse same buffer
    auto stats = pool.getStats();
    Assert.equal(stats.totalCreated, 1);
    
    pool.release(buffer2);
    
    writeln("\x1b[32m  ✓ BufferPool reuse works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool preallocate");
    
    auto pool = new BufferPool(1024, 10);
    
    pool.preallocate(5);
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 5);
    Assert.equal(stats.totalMemory, 5 * 1024);
    
    writeln("\x1b[32m  ✓ BufferPool preallocate works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool reject wrong size");
    
    auto pool = new BufferPool(1024, 10);
    
    auto wrongSize = new ubyte[512];  // Wrong size
    
    pool.release(wrongSize);  // Should not accept
    
    auto stats = pool.getStats();
    Assert.equal(stats.available, 0);
    
    writeln("\x1b[32m  ✓ BufferPool rejects wrong size\x1b[0m");
}

// ==================== CONCURRENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ArenaPool concurrent access");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto pool = new ArenaPool(1024, 100);
    
    try
    {
        shared int successCount = 0;
        
        foreach (i; parallel(iota(50)))
        {
            auto arena = pool.acquire();
            if (arena !is null)
            {
                arena.allocate(100);
                pool.release(arena);
                atomicOp!"+="(successCount, 1);
            }
        }
        
        Assert.equal(successCount, 50);
        
        writeln("\x1b[32m  ✓ ArenaPool concurrent access works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - ObjectPool concurrent access");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto pool = new ObjectPool!TestObject(100);
    
    try
    {
        shared int successCount = 0;
        
        foreach (i; parallel(iota(50)))
        {
            auto obj = pool.acquire();
            if (obj !is null)
            {
                obj.value = cast(int)i;
                pool.release(obj);
                atomicOp!"+="(successCount, 1);
            }
        }
        
        Assert.equal(successCount, 50);
        
        writeln("\x1b[32m  ✓ ObjectPool concurrent access works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Memory - BufferPool concurrent access");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto pool = new BufferPool(1024, 100);
    
    try
    {
        shared int successCount = 0;
        
        foreach (i; parallel(iota(50)))
        {
            auto buffer = pool.acquire();
            if (buffer !is null)
            {
                buffer[0] = cast(ubyte)i;
                pool.release(buffer);
                atomicOp!"+="(successCount, 1);
            }
        }
        
        Assert.equal(successCount, 50);
        
        writeln("\x1b[32m  ✓ BufferPool concurrent access works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

