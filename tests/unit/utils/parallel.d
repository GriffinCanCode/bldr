module tests.unit.utils.parallel;

import std.stdio;
import std.algorithm;
import std.array;
import std.range;
import std.conv;
import core.atomic;
import tests.harness;
import infrastructure.utils.concurrency.parallel;
import infrastructure.utils.concurrency.pool;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ParallelExecutor basic operations");
    
    // Test sequential execution with single item
    auto singleItem = [42];
    auto singleResult = ParallelExecutor.execute(singleItem, (int x) => cast(int)(x * 2), 1);
    Assert.equal(singleResult.length, 1);
    Assert.equal(singleResult[0], 84);
    
    // Test parallel execution with multiple items
    auto data = iota(10).array;
    auto result = ParallelExecutor.execute(data, (int x) => cast(int)(x * 2), 4);
    
    Assert.equal(result.length, 10);
    Assert.equal(result[0], 0);
    Assert.equal(result[5], 10);
    Assert.equal(result[9], 18);
    
    // Test with empty array
    int[] empty;
    auto emptyResult = ParallelExecutor.execute(empty, (int x) => cast(int)(x * 2), 4);
    Assert.equal(emptyResult.length, 0);
    
    writeln("\x1b[32m  ✓ ParallelExecutor operations\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ParallelExecutor auto parallelism");
    
    // Test automatic parallelism based on CPU count
    auto data = iota(100).array;
    auto result = ParallelExecutor.executeAuto(data, (int x) => cast(int)(x * x));
    
    Assert.equal(result.length, 100);
    Assert.equal(result[0], 0);
    Assert.equal(result[10], 100);
    Assert.equal(result[99], 9801);
    
    writeln("\x1b[32m  ✓ Auto parallelism\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ParallelExecutor sequential fallback");
    
    // Test that single-threaded execution works
    auto data = iota(10).array;
    
    auto result = ParallelExecutor.execute(
        data,
        (int x) => x + 1,
        1  // Single thread
    );
    
    Assert.equal(result.length, 10);
    foreach (i; 0 .. 10)
    {
        Assert.equal(result[i], i + 1);
    }
    
    writeln("\x1b[32m  ✓ Sequential fallback works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool creation and shutdown");
    
    // Test creation with default worker count
    auto pool = new ThreadPool();
    scope(exit) pool.shutdown();
    
    // Test simple map operation
    auto data = [1, 2, 3, 4, 5];
    auto result = pool.map(data, (int x) => cast(int)(x + 10));
    
    Assert.equal(result.length, 5);
    Assert.equal(result[0], 11);
    Assert.equal(result[4], 15);
    
    writeln("\x1b[32m  ✓ ThreadPool creation and shutdown\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool with custom worker count");
    
    // Test creation with specific worker count
    auto pool = new ThreadPool(2);
    scope(exit) pool.shutdown();
    
    auto data = iota(20).array;
    auto result = pool.map(data, (int x) => cast(int)(x * 3));
    
    Assert.equal(result.length, 20);
    Assert.equal(result[0], 0);
    Assert.equal(result[19], 57);
    
    writeln("\x1b[32m  ✓ Custom worker count\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool with single item");
    
    auto pool = new ThreadPool(4);
    scope(exit) pool.shutdown();
    
    // Test with single item (should execute directly)
    auto data = [42];
    auto result = pool.map(data, (int x) => cast(int)(x * 2));
    
    Assert.equal(result.length, 1);
    Assert.equal(result[0], 84);
    
    writeln("\x1b[32m  ✓ Single item handling\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool with empty array");
    
    auto pool = new ThreadPool(4);
    scope(exit) pool.shutdown();
    
    int[] empty;
    auto result = pool.map(empty, (int x) => cast(int)(x * 2));
    
    Assert.equal(result.length, 0);
    
    writeln("\x1b[32m  ✓ Empty array handling\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool parallel correctness");
    
    auto pool = new ThreadPool(4);
    scope(exit) pool.shutdown();
    
    // Test that all items are processed correctly in parallel
    auto data = iota(100).array;
    auto result = pool.map(data, (int x) => cast(int)(x * x));
    
    Assert.equal(result.length, 100);
    
    // Verify each result
    foreach (i, val; result)
    {
        Assert.equal(val, i * i);
    }
    
    writeln("\x1b[32m  ✓ Parallel correctness\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool with complex operations");
    
    auto pool = new ThreadPool(4);
    scope(exit) pool.shutdown();
    
    // Test with more complex operations
    auto data = ["hello", "world", "parallel", "test"];
    auto result = pool.map(data, (string s) => s.length.to!string ~ ":" ~ s);
    
    Assert.equal(result.length, 4);
    Assert.equal(result[0], "5:hello");
    Assert.equal(result[1], "5:world");
    Assert.equal(result[2], "8:parallel");
    Assert.equal(result[3], "4:test");
    
    writeln("\x1b[32m  ✓ Complex operations\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool stress test");
    
    auto pool = new ThreadPool(8);
    scope(exit) pool.shutdown();
    
    // Stress test with many items
    auto data = iota(1000).array;
    auto result = pool.map(data, (int x) => cast(int)((x * x) % 997));  // Some non-trivial computation
    
    Assert.equal(result.length, 1000);
    
    // Verify a sample of results
    Assert.equal(result[0], 0);
    Assert.equal(result[100], (100 * 100) % 997);
    Assert.equal(result[999], (999 * 999) % 997);
    
    writeln("\x1b[32m  ✓ Stress test\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m utils.parallel - ThreadPool multiple operations");
    
    auto pool = new ThreadPool(4);
    scope(exit) pool.shutdown();
    
    // Test that pool can be reused for multiple operations
    auto data1 = [1, 2, 3];
    auto result1 = pool.map(data1, (int x) => cast(int)(x * 2));
    Assert.equal(result1, [2, 4, 6]);
    
    auto data2 = [10, 20, 30];
    auto result2 = pool.map(data2, (int x) => cast(int)(x + 5));
    Assert.equal(result2, [15, 25, 35]);
    
    auto data3 = [100, 200];
    auto result3 = pool.map(data3, (int x) => cast(int)(x / 10));
    Assert.equal(result3, [10, 20]);
    
    writeln("\x1b[32m  ✓ Multiple operations\x1b[0m");
}
