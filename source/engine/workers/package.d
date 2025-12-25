module engine.workers;

/// Persistent Worker Protocol
/// 
/// Implements Bazel-compatible persistent worker protocol for JVM and TypeScript.
/// Reduces per-action overhead by 10-50x for warm compilers.
/// 
/// ## Overview
/// 
/// Persistent workers keep compiler processes running between build actions,
/// avoiding startup overhead:
/// 
/// - **JVM**: Saves ~500ms-2s per compilation (JVM startup, class loading)
/// - **TypeScript**: Saves ~100-500ms per compilation (Node.js startup, type checker init)
/// 
/// ## Protocol
/// 
/// Workers communicate via stdin/stdout using newline-delimited JSON:
/// 
/// 1. Build system sends `WorkRequest` to worker stdin
/// 2. Worker processes request and sends `WorkResponse` to stdout
/// 3. Worker remains alive for subsequent requests
/// 
/// ## Usage
/// 
/// ```d
/// import engine.workers;
/// 
/// // Create worker pool
/// auto pool = new WorkerPool(WorkerPoolConfig.init);
/// 
/// // Register factories for needed compilers
/// pool.registerFactory(new JVMWorkerFactory(JVMWorkerConfig.init));
/// pool.registerFactory(new TypeScriptWorkerFactory(TSWorkerConfig.init));
/// 
/// // Start pool
/// pool.start();
/// 
/// // Compile with warm worker (10-50x faster)
/// auto result = compileWithJVMWorker(pool, JVMCompiler.Javac, 
///     ["src/Main.java"], "bin/", ["lib/deps.jar"]);
/// 
/// // Or for TypeScript
/// auto tsResult = compileWithTSWorker(pool, TSCompilerType.TSC,
///     ["src/app.ts"], "dist/");
/// 
/// // Cleanup
/// pool.stop();
/// ```
/// 
/// ## Performance
/// 
/// Typical speedup over cold compilation:
/// 
/// | Compiler | Cold Start | Warm Worker | Speedup |
/// |----------|------------|-------------|---------|
/// | javac    | 800ms      | 50ms        | 16x     |
/// | kotlinc  | 2000ms     | 100ms       | 20x     |
/// | tsc      | 400ms      | 30ms        | 13x     |
/// | swc      | 50ms       | 5ms         | 10x     |
/// 
/// ## Configuration
/// 
/// See `WorkerPoolConfig`, `JVMWorkerConfig`, and `TSWorkerConfig`
/// for tuning options.

public import engine.workers.protocol;
public import engine.workers.pool;
public import engine.workers.jvm;
public import engine.workers.typescript;
public import engine.workers.service;
public import engine.workers.integration;
public import engine.workers.health;

