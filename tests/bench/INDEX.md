# Builder Benchmark Suite - Complete Index

## 🎯 Start Here

| Document | Purpose | Time to Read |
|----------|---------|--------------|
| **[README.md](README.md)** | 📚 Complete documentation | 20 min |
| **[QUICKSTART.md](QUICKSTART.md)** | 🚀 Get started in 5 minutes | 5 min |
| **[SETUP_COMPLETE.md](SETUP_COMPLETE.md)** | ✅ Setup verification and overview | 5 min |

## 📂 File Reference

### Microbenchmarks (Critical Path Testing)

| File | Type | Purpose | Targets |
|------|------|---------|---------|
| `graph_bench.d` | D Script | Graph operations | Arena alloc, topo sort, cycle detection |
| `hashing_bench.d` | D Script | Hashing performance | Blake3 vs SHA256, tiered hashing |
| `serialization_bench.d` | D Script | Serialization | SIMD-accelerated vs JSON baseline |
| `work_stealing_bench.d` | D Script | Concurrency | Lock-free deque performance |
| `chunking_bench.d` | D Script | Chunking | Rabin fingerprinting, deduplication |

### Profiling Tools

| File | Type | Purpose |
|------|------|---------|
| `profiler.d` | D Script | Real-world build profiler with bottleneck detection |
| `realworld.d` | D Script | Enhanced real-world benchmarking |

### Large-Scale Benchmarks

| File | Type | Lines | Purpose |
|------|------|-------|---------|
| `target_generator.d` | D Module | 734 | Generate realistic test projects |
| `scale_benchmark.d` | D Script | 587 | Simulated performance benchmarks |
| `integration_bench.d` | D Script | 466 | Real Builder system tests |
| `run-scale-benchmarks.sh` | Shell Script | 245 | Automated benchmark runner |

### Supporting Files

| File | Type | Purpose |
|------|------|---------|
| `suite.d` | D Module | Test suite infrastructure |
| `utils.d` | D Module | Benchmark utilities |

### Documentation

| File | Length | Purpose |
|------|--------|---------|
| `README.md` | ~1000 lines | Complete user guide |
| `QUICKSTART.md` | ~600 lines | Quick start guide |
| `SETUP_COMPLETE.md` | ~500 lines | Setup summary |
| `benchmark_config.example.d` | ~200 lines | Configuration examples |
| `BENCHMARK_RESULTS.template.md` | ~200 lines | Results tracking template |
| `INDEX.md` | This file | Complete file reference |

## 🎓 Learning Path

### Beginner (5 minutes)

1. Run microbenchmarks: `dub run --single graph_bench.d`
2. Run profiler: `dub run --single profiler.d`
3. View results in console

### Intermediate (30 minutes)

1. Read: `README.md` (microbenchmarks section)
2. Run all microbenchmarks
3. Profile your own projects: `dub run --single profiler.d -- /path/to/project`
4. Review generated reports

### Advanced (2+ hours)

1. Read: `README.md` (complete)
2. Study: Source code of benchmark tools
3. Run large-scale tests: `./run-scale-benchmarks.sh`
4. Profile with external tools: `perf` or Instruments
5. Track historical performance

## 🔧 Common Tasks

### Run Microbenchmarks (Recommended First)

```bash
# Graph operations (arena alloc, topo sort, caching)
dub run --single tests/bench/graph_bench.d

# Hashing (Blake3, tiered, two-tier)
dub run --single tests/bench/hashing_bench.d

# Serialization (SIMD vs JSON)
dub run --single tests/bench/serialization_bench.d

# Work-stealing concurrency
dub run --single tests/bench/work_stealing_bench.d

# Content chunking
dub run --single tests/bench/chunking_bench.d
```

### Profile Real-World Builds

```bash
# Profile example projects
dub run --single tests/bench/profiler.d

# Profile specific project
dub run --single tests/bench/profiler.d -- /path/to/project

# Verbose profiling
dub run --single tests/bench/profiler.d -- --verbose /path/to/project
```

### Run Large-Scale Benchmarks

```bash
# Quick test (2 min)
./run-scale-benchmarks.sh --simulated-only

# Full test (10-30 min)
./run-scale-benchmarks.sh

# Integration only (5-20 min)
./run-scale-benchmarks.sh --integration-only

# Keep workspace for inspection
./run-scale-benchmarks.sh --keep-workspace
```

### Generate Test Projects

```bash
# Standalone generation
dub run --single target_generator.d

# With custom config
# Edit benchmark_config.example.d, then use it in your script
```

### View Results

```bash
# Text view
cat benchmark-scale-report.md
cat benchmark-integration-report.md

# Browser view
open benchmark-scale-report.md  # macOS
xdg-open benchmark-scale-report.md  # Linux
```

### Troubleshooting

```bash
# Check Builder binary
ls -lh bin/bldr

# Clean everything
rm -rf bench-workspace integration-bench-workspace benchmark-*.md

# Rebuild Builder
make clean && make

# Check disk space
df -h

# Check memory
free -h  # Linux
vm_stat  # macOS
```

## 📊 What Gets Measured

### Performance Metrics

- ⏱️ Parse time
- ⏱️ Analysis time
- ⏱️ Execution time
- ⏱️ Total time
- 🚀 Throughput (targets/second)

### Resource Metrics

- 💾 Memory usage (initial, peak, delta)
- 💾 GC statistics
- 💾 Cache size

### Build Metrics

- ✅ Success/failure rate
- 📊 Cache hit rate
- 📊 Cache miss count
- 📊 Rebuild percentage

### Scaling Metrics

- 📈 Linear scaling factor
- 📈 Time vs target count
- 📈 Memory vs target count

## 🎯 Test Scenarios

| Scenario | Targets | Description | Duration |
|----------|---------|-------------|----------|
| Clean 50K | 50,000 | Fresh build, no cache | 45-60s |
| Clean 75K | 75,000 | Mid-scale test | 60-90s |
| Clean 100K | 100,000 | Maximum scale | 90-120s |
| Null 50K | 50,000 | All cached | 5-10s |
| Null 100K | 100,000 | Large cache test | 10-20s |
| Incremental 1% | 50,000 | 500 changed | 8-12s |
| Incremental 10% | 75,000 | 7,500 changed | 15-20s |
| Incremental 30% | 100,000 | 30,000 changed | 30-40s |

## 🔍 File Details

### target_generator.d

**Purpose**: Generate realistic test projects  
**Key Classes**:
- `TargetGenerator`: Main generator class
- `GeneratorConfig`: Configuration structure
- `GeneratedTarget`: Target metadata

**Key Features**:
- Multi-language support (6 languages)
- Varied naming conventions (6 styles)
- Complex dependency graphs (cycle-free)
- Realistic source code generation
- Progress reporting

**Usage**:
```d
auto config = GeneratorConfig();
config.targetCount = 50_000;
config.outputDir = "my-project";
auto generator = new TargetGenerator(config);
generator.generate();
```

### scale_benchmark.d

**Purpose**: Simulated performance benchmarks  
**Key Classes**:
- `ScaleBenchmark`: Benchmark orchestrator
- `ScaleBenchmarkResult`: Result storage
- `Scenario`: Test scenario definition

**Key Features**:
- Multiple scenarios
- Memory profiling
- Cache simulation
- Report generation

**Usage**:
```bash
dub run --single scale_benchmark.d
```

### integration_bench.d

**Purpose**: Real Builder system testing  
**Key Classes**:
- `IntegrationBenchmark`: Test orchestrator
- `IntegrationResult`: Result storage
- `IntegrationScenario`: Test scenario

**Key Features**:
- Actual Builder execution
- Exit code capture
- Output logging
- Success tracking

**Usage**:
```bash
dub run --single integration_bench.d -- --builder=./bin/bldr
```

### run-scale-benchmarks.sh

**Purpose**: Automated benchmark runner  
**Key Features**:
- Run all or selected benchmarks
- Automatic cleanup
- Summary reporting
- Error handling

**Usage**:
```bash
./run-scale-benchmarks.sh [OPTIONS]
```

**Options**:
- `--simulated-only`: Skip integration tests
- `--integration-only`: Skip simulated tests
- `--keep-workspace`: Don't clean up
- `--builder PATH`: Custom Builder binary

## 📈 Expected Output

### Console Output

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
✓ Generated 50,000 targets

[RESULTS]
  ┌─────────────────────────────────────────────────────────────┐
  │ Targets:         50,000                                     │
  │ Total Time:      49,257 ms                                  │
  │ Throughput:      1,015 targets/sec                          │
  │ Memory Used:     2,048 MB                                   │
  └─────────────────────────────────────────────────────────────┘
```

### Report Files

- `benchmark-scale-report.md`: Simulated results
- `benchmark-integration-report.md`: Real Builder results

Both include:
- Summary tables
- Detailed metrics
- Scaling analysis
- Performance recommendations

## 🎓 Tutorials

### Tutorial 1: First Benchmark (5 min)

```bash
cd tests/bench
./run-scale-benchmarks.sh --simulated-only
cat benchmark-scale-report.md
```

### Tutorial 2: Custom Configuration (15 min)

```bash
# Create custom script
cat > my_benchmark.d << 'EOF'
#!/usr/bin/env dub
/+ dub.sdl:
    name "my-benchmark"
    dependency "builder" path="../../"
+/

import tests.bench.target_generator;

void main() {
    auto config = GeneratorConfig();
    config.targetCount = 25_000;  // Start small
    config.outputDir = "my-test";
    
    auto gen = new TargetGenerator(config);
    gen.generate();
}
EOF

dub run --single my_benchmark.d
```

### Tutorial 3: Performance Analysis (30 min)

```bash
# Run full benchmark
./run-scale-benchmarks.sh

# Compare scaling
grep "targets/sec" benchmark-scale-report.md

# Check memory usage
grep "Memory" benchmark-scale-report.md

# Analyze cache performance
grep "Cache Hit Rate" benchmark-scale-report.md
```

## 🔗 Quick Links

### Documentation
- [Complete Guide](README.md)
- [Quick Start](QUICKSTART.md)
- [Setup Summary](SETUP_COMPLETE.md)

### Configuration
- [Config Examples](benchmark_config.example.d)
- [Results Template](BENCHMARK_RESULTS.template.md)

### Source Code
- [Generator](target_generator.d)
- [Scale Bench](scale_benchmark.d)
- [Integration Bench](integration_bench.d)
- [Runner Script](run-scale-benchmarks.sh)

## 📊 Benchmark Matrix

### Microbenchmarks (Critical Paths)

| Tool | Area | Fast | Targets |
|------|------|------|---------|
| graph_bench.d | Graph algorithms | ✅ | Arena 10-100x, Cache 100x |
| hashing_bench.d | Hashing | ✅ | Blake3 2-5x, Two-tier 1000x |
| serialization_bench.d | Serialization | ✅ | SIMD 10x vs JSON |
| work_stealing_bench.d | Concurrency | ✅ | Lock-free 10x under contention |
| chunking_bench.d | Chunking | ✅ | 80%+ bandwidth savings |
| profiler.d | Real builds | ⚖️ | Bottleneck identification |

### Large-Scale Tests

| Tool | Simulated | Real Builder | Fast | Accurate | Use Case |
|------|-----------|--------------|------|----------|----------|
| scale_benchmark.d | ✅ | ❌ | ✅ | ⭐⭐⭐ | Quick testing, development |
| integration_bench.d | ❌ | ✅ | ❌ | ⭐⭐⭐⭐⭐ | Release validation, CI/CD |
| run-scale-benchmarks.sh | ✅ | ✅ | ⚖️ | ⭐⭐⭐⭐⭐ | Complete testing |

## 🎯 Success Criteria

After running benchmarks, you should see:

✅ All scenarios complete successfully  
✅ Throughput > 800 targets/second (50K clean build)  
✅ Scaling factor < 2.5x (50K → 100K)  
✅ Memory usage < 3 GB (50K targets)  
✅ Cache hit rate > 95% (null build)  
✅ Cache hit rate > 99% (1% incremental)  

## 🚀 Ready to Start?

```bash
cd tests/bench
./run-scale-benchmarks.sh
```

---

**Last Updated**: 2025-11-01  
**Version**: 1.0  
**Status**: ✅ Production Ready

