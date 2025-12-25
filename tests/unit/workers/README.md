# Persistent Workers Unit Tests

Comprehensive unit tests for the multi-language persistent worker system.

## Test Files

### `base_test.d` - Base Worker Infrastructure
Tests for core worker types and configurations:
- `BaseWorkerConfig` defaults and custom values
- `WorkerFactoryStats` creation and metrics
- `WorkerCompilationResult` success/failure factories
- `WorkerId` creation and string representation
- `PersistentWorkerConfig` settings
- `WorkerState` enum transitions
- `WorkerStats` recording
- `WorkerCapabilities` configuration

**Test Count**: 9 unit tests

### `protocol_test.d` - Worker Protocol
Tests for Bazel-compatible protocol types:
- `WorkRequest` serialization/deserialization
- `WorkResponse` serialization/deserialization
- `InputFile` and `OutputFile` types
- Protocol roundtrip validation
- Cancel request handling
- Empty request handling
- Success/failure status checks

**Test Count**: 14 unit tests

### `language_workers_test.d` - Language-Specific Workers
Tests for each language worker factory:

**JVM Workers**:
- `JVMWorkerConfig` defaults
- `JVMWorkerFactory` type generation
- `CompilationResult` structure

**TypeScript Workers**:
- `TSWorkerConfig` defaults
- `TypeScriptWorkerFactory` type generation
- `TSCompileOptions` defaults
- `TSDiagnostic` structure

**Rust Workers**:
- `RustWorkerConfig` defaults
- `RustWorkerFactory` type generation
- `RustDiagnostic` structure

**Go Workers**:
- `GoWorkerConfig` defaults
- `GoWorkerFactory` type generation
- `GoDiagnostic` structure

**Python Workers**:
- `PythonWorkerConfig` defaults
- `PythonWorkerFactory` type generation
- `PythonDiagnostic` structure

**Cross-Language**:
- All factories implement `IWorkerFactory`
- Worker type uniqueness verification

**Test Count**: 20 unit tests

### `service_test.d` - Worker Service
Tests for the high-level service layer:
- `WorkerServiceConfig` defaults
- `WorkerServiceStatus` enum
- `LanguageMetrics` structure
- `WorkerServiceMetrics` structure
- `PersistentWorkerService` creation
- Configuration propagation
- `WorkerPoolConfig` defaults
- `RecyclingPolicy` defaults
- `MemoryThresholds` defaults
- `WarmthLevel` ordering
- Global service functions
- Service lifecycle (start/stop)
- Metrics retrieval
- Speedup factor calculation
- Pool access

**Test Count**: 16 unit tests

## Running Tests

### Run All Worker Tests

```bash
# Using dub
dub test --build=unittest -- tests.unit.workers

# Using builder
bldr test //tests/unit/workers/...
```

### Run Specific Test Module

```bash
# Base tests
dub test --build=unittest -- tests.unit.workers.base_test

# Protocol tests
dub test --build=unittest -- tests.unit.workers.protocol_test

# Language worker tests
dub test --build=unittest -- tests.unit.workers.language_workers_test

# Service tests
dub test --build=unittest -- tests.unit.workers.service_test
```

## Test Coverage

| Component | Tests | Coverage Areas |
|-----------|-------|----------------|
| Base | 9 | Config, stats, results, types |
| Protocol | 14 | Serialization, roundtrip, edge cases |
| Language Workers | 20 | All 5 languages, configs, diagnostics |
| Service | 16 | Lifecycle, metrics, pool config |
| **Total** | **59** | Comprehensive persistent worker coverage |

## Test Patterns

### Configuration Testing
All config structures tested for sensible defaults:
```d
unittest
{
    JVMWorkerConfig cfg;
    assert(cfg.compiler == JVMCompiler.Javac, "Default compiler");
    assert(cfg.maxHeapMB == 2048, "Default heap");
}
```

### Factory Testing
All factories tested for correct type generation:
```d
unittest
{
    foreach (compiler; [JVMCompiler.Javac, JVMCompiler.Kotlinc, ...])
    {
        auto factory = new JVMWorkerFactory(cfg);
        assert(factory.workerType().startsWith("jvm-"));
    }
}
```

### Protocol Testing
JSON roundtrip testing for all protocol types:
```d
unittest
{
    WorkRequest original;
    original.requestId = 123;
    
    auto json = original.toJson();
    auto restored = WorkRequest.fromJson(json);
    
    assert(restored.requestId == original.requestId);
}
```

### Lifecycle Testing
Service lifecycle tested for proper state transitions:
```d
unittest
{
    auto service = new PersistentWorkerService(cfg);
    assert(service.getStatus() == WorkerServiceStatus.Stopped);
    
    service.start();
    assert(service.getStatus() == WorkerServiceStatus.Running);
    
    service.stop();
    assert(service.getStatus() == WorkerServiceStatus.Stopped);
}
```

## Integration with CI/CD

These tests run as part of the Builder test suite:
- Executed on every commit
- Required to pass for merge
- No external dependencies (compilers not actually invoked)
- Fast execution (<1s per test file)

## Adding New Language Workers

When adding a new language worker:

1. Create worker in `source/engine/workers/<language>/`
2. Add tests in `tests/unit/workers/language_workers_test.d`
3. Test config defaults
4. Test factory type generation
5. Test diagnostic structure
6. Add to cross-language tests

Example:
```d
/// Test NewLangWorkerConfig defaults
unittest
{
    NewLangWorkerConfig cfg;
    assert(cfg.someDefault == expectedValue);
}

/// Test NewLangWorkerFactory types
unittest
{
    auto factory = new NewLangWorkerFactory();
    assert(factory.workerType().startsWith("newlang-"));
}
```


