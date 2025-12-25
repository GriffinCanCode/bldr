module engine.workers;

/// Persistent Worker Protocol
/// 
/// Multi-language persistent worker system that keeps compilers warm across builds.
/// Reduces per-action overhead by 3-50x depending on language.
/// 
/// ## Supported Languages
/// 
/// | Language   | Tools                          | Speedup   |
/// |------------|--------------------------------|-----------|
/// | JVM        | javac, kotlinc, scalac, groovyc| 10-50x    |
/// | TypeScript | tsc, swc, esbuild, bun         | 5-20x     |
/// | Rust       | cargo, rustc, clippy           | 3-15x     |
/// | Go         | go build/test/vet/fmt          | 2-5x      |
/// | Python     | mypy, ruff, pylint, black      | 3-20x     |
/// 
/// ## Protocol
/// 
/// Workers communicate via stdin/stdout using newline-delimited JSON:
/// 
/// 1. Build system sends `WorkRequest` to worker stdin
/// 2. Worker processes request and sends `WorkResponse` to stdout
/// 3. Worker remains alive for subsequent requests
/// 
/// ## Features
/// 
/// - **Warmth Tracking**: Cold → Warming → Warm → Hot progression
/// - **Memory Monitoring**: OOM detection with proactive restart
/// - **Metrics Collection**: Per-language speedup tracking
/// - **Auto Recovery**: Failed workers automatically restarted
/// 
/// ## Usage
/// 
/// ```d
/// import engine.workers;
/// 
/// // Create and start service
/// auto service = new PersistentWorkerService(WorkerServiceConfig.init);
/// service.start();
/// 
/// // Compile with warm workers
/// auto javaResult = service.compileJava(["src/Main.java"], "bin/");
/// auto rustResult = service.buildRust("Cargo.toml");
/// auto goResult = service.buildGo(["./..."]);
/// auto pyResult = service.typecheckPython(["src/"]);
/// 
/// // Get metrics
/// auto metrics = service.getMetrics();
/// writeln("Speedup: ", metrics.averageSpeedupFactor, "x");
/// writeln("Time saved: ", metrics.totalSavedTime.total!"seconds", "s");
/// 
/// service.stop();
/// ```
/// 
/// ## Performance
/// 
/// Typical speedup over cold compilation:
/// 
/// | Compiler     | Cold Start | Warm Worker | Hot Worker | Speedup |
/// |--------------|------------|-------------|------------|---------|
/// | javac        | 800ms      | 50ms        | 15ms       | 16-53x  |
/// | kotlinc      | 2000ms     | 100ms       | 30ms       | 20-67x  |
/// | tsc          | 400ms      | 30ms        | 10ms       | 13-40x  |
/// | cargo check  | 400ms      | 80ms        | 30ms       | 5-13x   |
/// | go build     | 100ms      | 40ms        | 20ms       | 2-5x    |
/// | mypy         | 1500ms     | 100ms       | 30ms       | 15-50x  |
/// | ruff         | 50ms       | 10ms        | 5ms        | 5-10x   |

// Core protocol and types
public import engine.workers.protocol;

// Pool management (includes PersistentWorkerPool)
public import engine.workers.pool;

// Base factory
public import engine.workers.base;

// Service layer
public import engine.workers.service;

// Health monitoring
public import engine.workers.health;

// Integration helpers
public import engine.workers.integration;

// Language-specific workers
public import engine.workers.jvm;
public import engine.workers.typescript;
public import engine.workers.rust;
public import engine.workers.go;
public import engine.workers.python;

// Tracing integration
public import engine.workers.tracing;

// Re-export key types for convenience
public import engine.workers.pool.persistent : 
    PersistentWorkerPool,
    PersistentPoolConfig,
    WorkerExecutionResult,
    WorkerLanguage,
    WorkerEconomics,
    getPersistentPool,
    initPersistentPool,
    shutdownPersistentPool,
    supportsPersistentWorker,
    estimatedColdStartMs;

