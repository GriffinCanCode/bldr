# Builder Benchmark & Profiling Suite

Comprehensive benchmarking and profiling infrastructure for testing Builder's performance at scale. Includes microbenchmarks for critical paths, large-scale tests with 50K-100K targets, and real-world build profiling.

## Quick Start

```bash
# Build Builder first
make

# Run microbenchmarks
dub run --single tests/bench/graph_bench.d      # Graph operations
dub run --single tests/bench/hashing_bench.d    # Hashing performance
dub run --single tests/bench/serialization_bench.d
dub run --single tests/bench/work_stealing_bench.d
dub run --single tests/bench/chunking_bench.d

# Run profiler on real projects
dub run --single tests/bench/profiler.d
dub run --single tests/bench/profiler.d -- /path/to/project

# Run large-scale tests
dub run --single tests/bench/scale_benchmark.d
dub run --single tests/bench/realworld.d
```

## Overview

This benchmark suite tests:
- **Microbenchmarks**: Critical path operations (graph, hashing, serialization)
- **Large-scale tests**: 50K-100K target builds
- **Real-world profiling**: Identify bottlenecks in actual builds

---

## Microbenchmarks

### Graph Operations (`graph_bench.d`)

Tests critical graph algorithms and data structures:

| Benchmark | Description | Target |
|-----------|-------------|--------|
| Node Creation | Arena vs GC allocation | 10-100x less GC pressure |
| Graph Construction | Immediate vs deferred validation | < 100ms for 5K nodes |
| Topological Sort | Full vs incremental (cached) | O(1) cache hit |
| Cycle Detection | Validation performance | < 10ms for 1K nodes |
| Critical Path | Cost calculation | < 50ms for 5K nodes |
| Depth Calculation | Memoized traversal | O(V+E) total |
| Serialization | Round-trip performance | < 100ms serialize |

**Key Metrics:**
- Arena allocation reduces GC allocations by 10-100x
- Deferred validation 2-5x faster than immediate
- Incremental topo sort cache provides 100x+ speedup

### Hashing Performance (`hashing_bench.d`)

Tests hashing operations critical to build caching:

| Benchmark | Description | Target |
|-----------|-------------|--------|
| Blake3 vs SHA256 | Raw algorithm comparison | 2-5x faster |
| String Hashing | Target path throughput | > 1M hashes/sec |
| Tiered Hashing | Adaptive file hashing | 100+ MB/s |
| Two-Tier Hashing | Metadata + content | 1000x faster (cached) |
| Parallel Hashing | Multiple files | Near-linear scaling |
| Incremental Hashing | Streaming mode | < 10% overhead |

**Key Metrics:**
- Blake3 is 2-5x faster than SHA256 for all sizes
- Two-tier hashing: 1000x faster when metadata unchanged
- Tiered approach handles files from 1KB to 100MB+ efficiently

### Serialization (`serialization_bench.d`)

Tests SIMD-accelerated serialization:

| Benchmark | Description | Target |
|-----------|-------------|--------|
| Small Structs | 10K cache entries | 10x faster than JSON |
| Large Graphs | 50K nodes | < 500ms serialize |
| SIMD Arrays | 1M integers | 5-8x speedup |
| Nested Structures | Complex AST-like | 8x faster than JSON |

### Work-Stealing (`work_stealing_bench.d`)

Tests lock-free work-stealing deque:

| Benchmark | Description | Target |
|-----------|-------------|--------|
| Single-Thread | Push/pop baseline | 2-5x faster than mutex |
| Contention | 4 threads competing | 10x faster under load |
| Steal Operations | Steal latency | < 100ns per steal |
| Load Balancing | 8 workers, uneven load | < 10% imbalance |

### Content Chunking (`chunking_bench.d`)

Tests content-defined chunking (Rabin fingerprinting):

| Benchmark | Description | Target |
|-----------|-------------|--------|
| Chunking Speed | 100MB file | < 50ms |
| Deduplication | 30% duplicate content | 90%+ detection |
| Incremental | 1% file change | < 5% chunks changed |
| Network Transfer | 10% modified | 80%+ bandwidth savings |

---

## Build Profiler (`profiler.d`)

Comprehensive profiler for real-world builds:

```bash
# Profile example projects
dub run --single tests/bench/profiler.d

# Profile specific project
dub run --single tests/bench/profiler.d -- /path/to/project

# Verbose output
dub run --single tests/bench/profiler.d -- --verbose /path/to/project
```

**Features:**
- Phase timing breakdown (parse, analyze, execute, finalize)
- Cache hit/miss analysis
- Memory usage tracking
- Hot path identification
- Automatic bottleneck recommendations

**Output:**
- Detailed text report to console
- Markdown report (`build-profile-report.md`)
- Flame graph compatible data (folded stacks)

**Sample Output:**
```
╔════════════════════════════════════════════════════════════════╗
║              BUILD PROFILE REPORT                              ║
╚════════════════════════════════════════════════════════════════╝

TIMING BREAKDOWN
  Parse            123 ms ( 12.3%) ██████
  Analysis         234 ms ( 23.4%) ███████████
  Execution        600 ms ( 60.0%) ██████████████████████████████
  Finalization      43 ms (  4.3%) ██
  ────────────────────────────────────────
  TOTAL           1000 ms (100.0%)

TARGET STATISTICS
  Total Targets:       150
  Cached:               75 (50.0%)
  Built:                75
  Throughput:       150.0 targets/sec

RECOMMENDATIONS
  • Execution-bound build - focus on parallelism
```

---

## Large-Scale Benchmarks

### 1. Target Generator (`target_generator.d`)

Generates realistic project structures with:
- **50K-100K targets** with configurable parameters
- **Multi-language support**: TypeScript (40%), Python (25%), Rust (15%), Go (10%), C++ (5%), Java (5%)
- **Varied naming conventions**: CamelCase, snake_case, kebab-case, etc.
- **Complex dependency graphs**: Layered architecture preventing cycles
- **Realistic file structures**: Multiple source files per target
- **Project types**: Monorepo, Microservices, Library, Application

**Key Features:**
- Configurable target count (50K-100K)
- Realistic dependency distribution (~3.5 deps/target average)
- Prevents circular dependencies using layered architecture
- Generates actual source files with imports/dependencies

### 2. Scale Benchmark (`scale_benchmark.d`)

Simulated benchmarks for rapid testing without full builds:

**Test Scenarios:**
- **Clean Build**: All targets built from scratch (0% cache hit)
- **Null Build**: All targets cached (100% cache hit)
- **Incremental Builds**: 
  - Small (1% changed)
  - Medium (10% changed)
  - Large (30% changed)

**Measures:**
- Parse time
- Analysis time
- Execution time
- Total time
- Memory usage
- Cache hit rates
- Throughput (targets/second)

### 3. Integration Benchmark (`integration_bench.d`)

Tests the **actual Builder system** with generated projects:

**Features:**
- Runs real `builder` binary
- Generates full project files
- Tests clean vs cached builds
- Captures exit codes and output
- Reports success/failure rates

**Requirements:**
- Built Builder binary at `./bin/builder`
- Sufficient disk space for generated files

### 4. Serialization Benchmark (`serialization_bench.d`)

Performance benchmarks for SIMD-accelerated serialization:

**Test Scenarios:**
- Small cache entries (10K items)
- Large build graphs (50K nodes)
- SIMD array operations (1M integers)
- Nested structures (complex AST-like nodes)

**Baselines:**
- JSON serialization (target: 10x faster)
- Standard binary format (target: 2.5x faster)

**Measures:**
- Serialize/deserialize speed
- Data size compression
- Throughput (ops/sec)
- Statistical analysis across runs

### 5. Work-Stealing Benchmark (`work_stealing_bench.d`)

Lock-free work-stealing deque performance tests:

**Test Scenarios:**
- Single-threaded push/pop operations
- Multi-threaded contention (4 workers)
- Steal operation latency
- Load balancing efficiency (8 workers)

**Baselines:**
- Mutex-protected queue (target: 10x faster under contention)

**Measures:**
- Push/pop throughput
- Steal latency (< 100ns target)
- Load imbalance percentage
- Per-worker statistics

### 6. Chunking Benchmark (`chunking_bench.d`)

Content-defined chunking (Rabin fingerprinting) benchmarks:

**Test Scenarios:**
- Chunking speed (100MB files)
- Deduplication efficiency
- Incremental updates (1% change)
- Network transfer simulation (10% modified)

**Baselines:**
- Fixed-size chunking

**Measures:**
- Chunking throughput (MB/sec)
- Bandwidth savings (target: 40-90%)
- Changed chunk ratio
- Transfer efficiency

## Usage

### Quick Start

```bash
# 1. Build Builder first
make

# 2. Run simulated benchmarks (fast)
cd tests/bench
dub run --single scale_benchmark.d

# 3. Run integration benchmarks (tests real system)
dub run --single integration_bench.d

# 4. Run performance benchmarks
dub run --single serialization_bench.d
dub run --single work_stealing_bench.d
dub run --single chunking_bench.d

# 5. Run target generator standalone
dub run --single target_generator.d
```

### Advanced Usage

#### Custom Scale Benchmark

```d
import tests.bench.target_generator;
import tests.bench.scale_benchmark;

auto bench = new ScaleBenchmark("my-workspace");
bench.runAll();
```

#### Custom Target Generation

```d
import tests.bench.target_generator;

auto config = GeneratorConfig();
config.targetCount = 75_000;
config.projectType = ProjectType.Monorepo;
config.avgDepsPerTarget = 4.0;
config.libToExecRatio = 0.8;
config.outputDir = "my-test-project";

auto generator = new TargetGenerator(config);
auto targets = generator.generate();
```

#### Custom Integration Test

```bash
# Test with specific Builder binary
dub run --single integration_bench.d -- --builder=/path/to/bldr

# Use custom workspace
dub run --single integration_bench.d -- --workspace=/tmp/bench
```

## Configuration Options

### GeneratorConfig

```d
struct GeneratorConfig
{
    size_t targetCount;              // Total targets (50K-100K)
    ProjectType projectType;          // Monorepo, Microservices, etc.
    LanguageDistribution languages;   // Language percentages
    double avgDepsPerTarget = 3.5;    // Average dependencies
    size_t maxDepth = 20;             // Max dependency depth
    double libToExecRatio = 0.7;      // Library vs executable ratio
    bool generateSources = true;      // Write actual source files
    string outputDir;                 // Output directory
}
```

### Project Types

- **Monorepo**: Large monorepo with many packages (`packages/pkg-00001`)
- **Microservices**: Service-oriented architecture (`services/svc-00001`)
- **Library**: Library with many modules (`modules/mod-00001`)
- **Application**: Large application with components (`components/comp-00001`)
- **Mixed**: Combination of all types

## Output

### Reports

Both benchmark tools generate detailed Markdown reports:

- `benchmark-scale-report.md`: Simulated benchmark results
- `benchmark-integration-report.md`: Real Builder test results

### Report Contents

- Summary table with all scenarios
- Detailed timing breakdown
- Memory usage statistics
- Cache hit rates
- Scaling analysis (50K vs 100K)
- Performance recommendations

## Example Results

### Scale Benchmark Output

```
╔════════════════════════════════════════════════════════════════╗
║           BUILDER LARGE-SCALE BENCHMARK SUITE                  ║
║              Testing 50K - 100K Targets                        ║
╚════════════════════════════════════════════════════════════════╝

SCENARIO 1/8: Clean build - 50K targets
================================================================
[GENERATOR] Generating 50,000 targets...
  Phase 1/3: Generating target metadata...
  Phase 2/3: Generating dependency graph...
  Phase 3/3: Writing project files...

[RESULTS]
  ┌─────────────────────────────────────────────────────────────┐
  │ Targets:         50,000                                     │
  │ Parse Time:      1,234 ms                                   │
  │ Analysis Time:   2,345 ms                                   │
  │ Execution Time:  45,678 ms                                  │
  │ Total Time:      49,257 ms                                  │
  │ Throughput:      1,015 targets/sec                          │
  │ Memory Used:     2,048 MB                                   │
  │ Cache Hit Rate:  0 %                                        │
  └─────────────────────────────────────────────────────────────┘
```

### Integration Benchmark Output

```
╔════════════════════════════════════════════════════════════════╗
║      BUILDER INTEGRATION BENCHMARK - REAL SYSTEM TESTS        ║
║         Testing actual Builder with 50K-100K targets          ║
╚════════════════════════════════════════════════════════════════╝

✓ Using Builder binary: ./bin/bldr

SCENARIO 1/4: Real build - 50K targets (clean)
================================================================
[PHASE 1] Generating Test Project
  Generated 50,000 targets in 5,432 ms

[PHASE 2] Cleaning (forcing fresh build)
  ✓ Cleaned cache directory

[PHASE 3] Running Builder System
  Executing: ./bin/bldr build
  ✓ Build succeeded
  Build time: 67,890 ms

[RESULT]
  ┌─────────────────────────────────────────────────────────────┐
  │ Status:          PASSED                                     │
  │ Targets:         50,000                                     │
  │ Generation Time: 5,432 ms                                   │
  │ Build Time:      67,890 ms                                  │
  │ Total Time:      73,322 ms                                  │
  │ Throughput:      736 targets/sec                            │
  └─────────────────────────────────────────────────────────────┘
```

## Performance Expectations

### Target Metrics (50K targets)

- **Clean Build**: 45-60 seconds
- **Null Build**: 5-10 seconds (pure cache hits)
- **Incremental (1%)**: 8-12 seconds
- **Memory**: 1.5-3 GB peak
- **Throughput**: 800-1200 targets/second

### Scaling (50K → 100K)

- **Ideal**: 2.0x time increase (linear scaling)
- **Good**: 2.0x - 2.5x (near-linear)
- **Needs Optimization**: >2.8x (sub-linear)

### Serialization Benchmarks

- **vs JSON**: 10-23x faster, 3-4x smaller
- **vs Binary**: 2.5-4x faster
- **50K nodes**: < 500ms serialize, < 250ms deserialize
- **Arrays**: 5-8x speedup with SIMD

### Work-Stealing Benchmarks

- **Single-thread**: 2-5x faster than mutex
- **Contention**: 5-15x faster under load
- **Steal latency**: < 100ns per operation
- **Load balance**: < 10% imbalance

### Chunking Benchmarks

- **Chunking speed**: < 50ms for 100MB
- **Dedup efficiency**: 25-40% savings
- **Incremental**: < 5% re-transfer for 1% change
- **Network savings**: 40-90% bandwidth reduction

## Generated Project Structure

```
bench-workspace/
├── Builderspace              # Workspace configuration
├── Builderfile               # All target definitions (large file)
├── packages/                 # Or services/, modules/, components/
│   ├── pkg-00000/
│   │   └── src/
│   │       ├── index.ts      # Generated source
│   │       ├── module_1.ts
│   │       └── module_2.ts
│   ├── pkg-00001/
│   │   └── src/
│   │       └── index.py
│   └── ...                   # Up to 100K targets
└── .builder-cache/           # Created during build
```

## Troubleshooting

### Out of Memory

If you encounter OOM errors:
1. Reduce `targetCount` to 50K or 75K
2. Disable source generation: `config.generateSources = false`
3. Increase system swap space
4. Use cleanup between scenarios

### Disk Space

Generating 100K targets with sources can use 5-10 GB:
- Each target: ~50-100 KB
- Builderfile: ~10-20 MB
- Cache: ~500 MB - 2 GB

### Slow Generation

Target generation is I/O bound:
- 50K targets: ~5-10 seconds
- 100K targets: ~15-30 seconds
- Use SSD for better performance
- Consider disabling source generation for quick tests

### Builder Binary Not Found

```bash
# Build Builder first
make

# Or specify path
dub run --single integration_bench.d -- --builder=/path/to/bldr
```

## Integration with CI/CD

### Example GitHub Actions

```yaml
name: Scale Benchmark

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install D compiler
        uses: dlang-community/setup-dlang@v1
        
      - name: Build Builder
        run: make
        
      - name: Run Scale Benchmark
        run: dub run --single tests/bench/scale_benchmark.d
        
      - name: Run Integration Benchmark
        run: dub run --single tests/bench/integration_bench.d
        
      - name: Upload Results
        uses: actions/upload-artifact@v3
        with:
          name: benchmark-reports
          path: benchmark-*.md
```

## Development

### Adding New Scenarios

Edit `scale_benchmark.d`:

```d
scenarios ~= Scenario(
    ScenarioType.YourNewType,
    50_000,
    "Description of scenario",
    skipSourceGen
);
```

### Adding New Languages

Edit `target_generator.d`:

```d
struct LanguageDistribution
{
    // Add your language
    double yourLanguage = 0.05;
}

// Add generator method
private void writeYourLanguageSource(File f, in GeneratedTarget target)
{
    // Generate source
}
```

### Custom Metrics

Extend `ScaleBenchmarkResult`:

```d
struct ScaleBenchmarkResult
{
    // Add custom fields
    size_t yourMetric;
}
```

## Best Practices

1. **Start Small**: Test with 10K targets first
2. **Clean Between Runs**: Ensure consistent results
3. **Multiple Runs**: Average 3-5 runs for stability
4. **Monitor Resources**: Watch CPU, memory, and disk I/O
5. **Profile**: Use `perf` or `valgrind` for bottlenecks
6. **Compare**: Track results over time (regression detection)

## Future Enhancements

- [ ] Parallel target generation
- [ ] Database storage for historical results
- [ ] Automatic regression detection
- [ ] Visual performance graphs
- [ ] Network I/O simulation (remote dependencies)
- [ ] More languages (Kotlin, Swift, Elixir, etc.)
- [ ] Custom build phases (test execution, packaging)
- [ ] Distributed build simulation

## License

Same as Builder project.

