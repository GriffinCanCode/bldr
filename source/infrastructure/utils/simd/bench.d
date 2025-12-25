module infrastructure.utils.simd.bench;

import std.stdio;
import std.datetime.stopwatch;
import std.format;
import std.algorithm;
import infrastructure.utils.simd.detection;
import infrastructure.utils.simd.dispatch;
import infrastructure.utils.simd.ops;
import infrastructure.utils.simd.bloom;
import infrastructure.utils.crypto.blake3;
import infrastructure.utils.benchmarking.bench;

/// SIMD Benchmarking Suite
/// Comprehensive performance comparison of SIMD implementations
struct SIMDBench
{
    /// Benchmark all BLAKE3 SIMD implementations
    static void benchmarkBlake3Compression()
    {
        writeln("\n╔══════════════════════════════════════════════════════════════╗");
        writeln("║         BLAKE3 SIMD COMPRESSION BENCHMARK                    ║");
        writeln("╚══════════════════════════════════════════════════════════════╝");
        
        writeln("\nCurrent CPU: ", CPU.brand());
        writeln("SIMD Level:  ", CPU.simdLevelName());
        writeln();
        
        // Test data
        ubyte[64] block;
        foreach (i, ref b; block) b = cast(ubyte)i;
        
        uint[8] cv = [
            0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
            0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
        ];
        
        ubyte[64] output;
        const iterations = 1_000_000;
        
        // Benchmark active implementation
        {
            auto bench = Benchmark("Active SIMD (" ~ SIMDDispatch.compressionImpl() ~ ")", iterations);
            auto compress = blake3_get_compress_fn();
            
            bench.run(() {
                compress(cv, block, 64, 0, 0, output);
            });
            
            auto result = bench.result();
            result.print();
            writefln("Throughput: %.2f GB/s", 
                (64.0 * iterations / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024));
        }
        
        // Benchmark portable
        {
            auto bench = Benchmark("Portable (baseline)", iterations);
            bench.run(() {
                blake3_compress_portable(cv, block, 64, 0, 0, output);
            });
            bench.result().print();
        }
        
        // Benchmark specific implementations if available
        if (CPU.hasFeature(CPUFeature.AVX2)) {
            auto bench = Benchmark("AVX2", iterations);
            bench.run(() {
                blake3_compress_avx2(cv, block, 64, 0, 0, output);
            });
            bench.result().print();
        }
        
        if (CPU.hasFeature(CPUFeature.AVX512F)) {
            auto bench = Benchmark("AVX-512", iterations);
            bench.run(() {
                blake3_compress_avx512(cv, block, 64, 0, 0, output);
            });
            bench.result().print();
        }
        
        if (CPU.hasFeature(CPUFeature.NEON)) {
            auto bench = Benchmark("NEON", iterations);
            bench.run(() {
                blake3_compress_neon(cv, block, 64, 0, 0, output);
            });
            bench.result().print();
        }
    }
    
    /// Benchmark SIMD memory operations
    static void benchmarkMemoryOps()
    {
        writeln("\n╔══════════════════════════════════════════════════════════════╗");
        writeln("║          SIMD MEMORY OPERATIONS BENCHMARK                    ║");
        writeln("╚══════════════════════════════════════════════════════════════╝");
        
        enum size_t[] sizes = [256, 1024, 4096, 16_384, 65_536, 262_144, 1_048_576];
        
        foreach (size; sizes) {
            writefln("\n--- Buffer Size: %,d bytes (%.2f KB) ---", size, size / 1024.0);
            
            auto src = new ubyte[size];
            auto dest = new ubyte[size];
            foreach (i, ref b; src) b = cast(ubyte)(i & 0xFF);
            
            // Benchmark memcpy
            {
                auto bench = Benchmark("SIMD memcpy", 10_000);
                bench.run(() {
                    SIMDOps.copy(dest, src);
                });
                auto result = bench.result();
                auto bandwidth = (size * 10_000.0 / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
                writefln("  memcpy:  %s (%.2f GB/s)", 
                    BenchmarkResult.formatDuration(result.avgTime), bandwidth);
            }
            
            // Benchmark memcmp
            {
                auto bench = Benchmark("SIMD memcmp", 10_000);
                bench.run(() {
                    SIMDOps.equals(dest, src);
                });
                auto result = bench.result();
                auto bandwidth = (size * 10_000.0 / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
                writefln("  memcmp:  %s (%.2f GB/s)", 
                    BenchmarkResult.formatDuration(result.avgTime), bandwidth);
            }
            
            // Benchmark memset
            {
                auto bench = Benchmark("SIMD memset", 10_000);
                bench.run(() {
                    SIMDOps.fill(dest, 0xAB);
                });
                auto result = bench.result();
                auto bandwidth = (size * 10_000.0 / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
                writefln("  memset:  %s (%.2f GB/s)", 
                    BenchmarkResult.formatDuration(result.avgTime), bandwidth);
            }
            
            // Benchmark XOR
            {
                auto other = new ubyte[size];
                foreach (i, ref b; other) b = cast(ubyte)(~i & 0xFF);
                
                auto bench = Benchmark("SIMD XOR", 10_000);
                bench.run(() {
                    SIMDOps.xor(dest, src, other);
                });
                auto result = bench.result();
                auto bandwidth = (size * 10_000.0 / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
                writefln("  XOR:     %s (%.2f GB/s)", 
                    BenchmarkResult.formatDuration(result.avgTime), bandwidth);
            }
        }
    }
    
    /// Benchmark full BLAKE3 hashing with different sizes
    static void benchmarkHashThroughput()
    {
        writeln("\n╔══════════════════════════════════════════════════════════════╗");
        writeln("║         BLAKE3 HASH THROUGHPUT BENCHMARK                     ║");
        writeln("╚══════════════════════════════════════════════════════════════╝");
        
        enum size_t[] sizes = [1024, 10_240, 102_400, 1_024_000, 10_240_000];
        
        foreach (size; sizes) {
            auto data = new ubyte[size];
            foreach (i, ref b; data) b = cast(ubyte)(i & 0xFF);
            
            auto bench = Benchmark(format("Hash %,d bytes", size), 100);
            bench.run(() {
                auto hash = Blake3.hash(data);
            });
            
            auto result = bench.result();
            auto bandwidth = (size * 100.0 / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
            
            writefln("%12s: %10s  (%6.2f GB/s)", 
                formatSize(size), 
                BenchmarkResult.formatDuration(result.avgTime),
                bandwidth);
        }
    }
    
    /// Compare SIMD vs non-SIMD for realistic workload
    static void benchmarkRealWorld()
    {
        writeln("\n╔══════════════════════════════════════════════════════════════╗");
        writeln("║         REAL-WORLD BUILD SCENARIO BENCHMARK                  ║");
        writeln("╚══════════════════════════════════════════════════════════════╝");
        
        writeln("\nSimulating: Hash 1000 source files (avg 50KB each)");
        
        // Create synthetic files
        enum numFiles = 1000;
        enum avgSize = 50_000;
        
        auto files = new ubyte[][numFiles];
        foreach (i; 0 .. numFiles) {
            files[i] = new ubyte[avgSize];
            foreach (j, ref b; files[i]) b = cast(ubyte)((i + j) & 0xFF);
        }
        
        auto bench = Benchmark("Hash all files", 10);
        bench.run(() {
            foreach (file; files) {
                auto hash = Blake3.hash(file);
            }
        });
        
        auto result = bench.result();
        auto totalBytes = numFiles * avgSize * 10UL;
        auto bandwidth = (cast(double)totalBytes / result.avgTime.total!"nsecs") * 1e9 / (1024.0 * 1024 * 1024);
        
        result.print();
        writefln("\nTotal data: %.2f MB", totalBytes / (1024.0 * 1024));
        writefln("Bandwidth:  %.2f GB/s", bandwidth);
        writefln("Files/sec:  %,d", cast(ulong)(numFiles * 10.0 / (result.avgTime.total!"nsecs" / 1e9)));
    }
    
    /// Benchmark Bloom filter operations
    static void benchmarkBloomFilter()
    {
        writeln("\n╔══════════════════════════════════════════════════════════════╗");
        writeln("║         BLOOM FILTER SIMD BENCHMARK                          ║");
        writeln("╚══════════════════════════════════════════════════════════════╝");
        
        // Test different filter sizes
        enum size_t[] sizes = [10_000, 100_000, 1_000_000];
        
        foreach (size; sizes)
        {
            writefln("\n--- Filter for %,d items (1%% FPR) ---", size);
            
            auto filter = BloomFilter.create(size, 0.01);
            auto stats = filter.stats();
            writefln("  Memory: %,d bytes (%.2f KB)", stats.memoryBytes, stats.memoryBytes / 1024.0);
            writefln("  Hash functions: %d", stats.numHashes);
            
            // Prepare test data
            auto hashes = new ulong[1000];
            foreach (i, ref h; hashes)
                h = i * 0x9e3779b97f4a7c15UL;
            
            // Benchmark insert
            {
                auto bench = Benchmark("Insert (1K items)", 1000);
                bench.run(() {
                    foreach (h; hashes)
                        filter.insertHash(h);
                });
                auto result = bench.result();
                writefln("  Insert:     %s (%.2f M ops/s)", 
                    BenchmarkResult.formatDuration(result.avgTime),
                    1000.0 * 1000 / (result.avgTime.total!"nsecs" / 1e3));
            }
            
            // Benchmark single lookup
            {
                auto bench = Benchmark("Lookup (1K items)", 10_000);
                bench.run(() {
                    foreach (h; hashes)
                        cast(void)filter.mayContainHash(h);
                });
                auto result = bench.result();
                writefln("  Lookup:     %s (%.2f M ops/s)",
                    BenchmarkResult.formatDuration(result.avgTime),
                    1000.0 * 10_000 / (result.avgTime.total!"nsecs" / 1e3));
            }
            
            // Benchmark batch lookup (SIMD)
            {
                auto batch = hashes[0 .. 64];  // Max batch size
                auto bench = Benchmark("Batch (64 items)", 10_000);
                bench.run(() {
                    cast(void)filter.mayContainBatch(batch);
                });
                auto result = bench.result();
                writefln("  Batch (64): %s (%.2f M ops/s)",
                    BenchmarkResult.formatDuration(result.avgTime),
                    64.0 * 10_000 / (result.avgTime.total!"nsecs" / 1e3));
            }
            
            // Benchmark count matches
            {
                auto bench = Benchmark("Count (1K items)", 1000);
                bench.run(() {
                    cast(void)filter.countMatches(hashes);
                });
                auto result = bench.result();
                writefln("  Count:      %s (%.2f M ops/s)",
                    BenchmarkResult.formatDuration(result.avgTime),
                    1000.0 * 1000 / (result.avgTime.total!"nsecs" / 1e3));
            }
        }
        
        // Real-world scenario: cache lookup
        writeln("\n--- Real-World: Cache Prefilter (100K entries) ---");
        {
            auto filter = BloomFilter.create(100_000, 0.01);
            
            // Insert 100K hashes
            foreach (i; 0 .. 100_000)
                filter.insertHash(i * 0xdeadbeefUL);
            
            // Query mixed (50% hits, 50% misses)
            auto queryHashes = new ulong[10_000];
            foreach (i, ref h; queryHashes)
                h = (i % 2 == 0) ? (i / 2) * 0xdeadbeefUL : i * 0xcafebabeUL;
            
            auto bench = Benchmark("Mixed query (10K)", 100);
            size_t hits = 0;
            bench.run(() {
                hits = filter.countMatches(queryHashes);
            });
            
            auto result = bench.result();
            auto savings = (10_000 - hits) * 100.0 / 10_000;
            
            writefln("  Query time:   %s", BenchmarkResult.formatDuration(result.avgTime));
            writefln("  Potential hits: %,d / 10,000", hits);
            writefln("  Lookups avoided: %.1f%%", savings);
            writefln("  Estimated FPR: %.4f%%", filter.estimatedFPR * 100);
        }
    }
    
    /// Run all benchmarks
    static void compareAll()
    {
        writeln("\n");
        writeln("╔════════════════════════════════════════════════════════════════╗");
        writeln("║              BUILDER SIMD BENCHMARK SUITE                      ║");
        writeln("╚════════════════════════════════════════════════════════════════╝");
        
        // Show CPU info
        writeln();
        CPU.printInfo();
        
        // Run benchmarks
        benchmarkBlake3Compression();
        benchmarkMemoryOps();
        benchmarkHashThroughput();
        benchmarkBloomFilter();
        benchmarkRealWorld();
        
        writeln("\n╔════════════════════════════════════════════════════════════════╗");
        writeln("║                    BENCHMARK COMPLETE                          ║");
        writeln("╚════════════════════════════════════════════════════════════════╝\n");
    }
    
    /// Format size nicely
    private static string formatSize(size_t bytes)
    {
        if (bytes < 1024)
            return format("%d B", bytes);
        if (bytes < 1024 * 1024)
            return format("%.1f KB", bytes / 1024.0);
        if (bytes < 1024 * 1024 * 1024)
            return format("%.1f MB", bytes / (1024.0 * 1024));
        return format("%.1f GB", bytes / (1024.0 * 1024 * 1024));
    }
}

