module engine.workers.integration;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import core.time : Duration, MonoTime, seconds, msecs;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.jvm;
import engine.workers.typescript;
import engine.workers.rust;
import engine.workers.go;
import engine.workers.python;
import engine.workers.service;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Integration layer for language handlers
/// 
/// Provides simple interfaces for language handlers to use persistent workers
/// without needing to manage worker lifecycle directly.
/// 
/// Supports: JVM, TypeScript, Rust, Go, Python

/// Check if persistent workers are available
bool shouldUsePersistentWorker(string compilerType) @safe
{
    auto service = getWorkerService();
    return service !is null && service.getStatus() == WorkerServiceStatus.Running;
}

// ==================== JVM Integration ====================

/// Java compilation integration
struct JavaWorkerIntegration
{
    static Result!(JavaCompileResult, string) compile(
        string[] sources, string outputDir,
        string[] classpath = [], string[] options = [],
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("jvm-javac"))
        {
            auto result = getWorkerService().compileJava(sources, outputDir, classpath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(JavaCompileResult, string)(JavaCompileResult(
                    r.success, r.output, r.executionTimeMs, true,
                    findJavaOutputFiles(sources, outputDir)
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return compileJavaDirect(sources, outputDir, classpath, options);
    }
    
    private static Result!(JavaCompileResult, string) compileJavaDirect(
        string[] sources, string outputDir, string[] classpath, string[] options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["javac", "-d", outputDir];
        if (classpath.length > 0)
        {
            version(Windows) { cmd ~= ["-cp", classpath.join(";")]; }
            else { cmd ~= ["-cp", classpath.join(":")]; }
        }
        cmd ~= options ~ sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        auto execTime = (MonoTime.currTime - startTime).total!"msecs";
        
        if (result.status != 0)
            return Err!(JavaCompileResult, string)("Compilation failed: " ~ result.output);
        
        return Ok!(JavaCompileResult, string)(JavaCompileResult(
            true, result.output, execTime, false, findJavaOutputFiles(sources, outputDir)
        ));
    }
    
    private static string[] findJavaOutputFiles(string[] sources, string outputDir) @trusted
    {
        return sources.filter!(s => s.endsWith(".java"))
            .map!(s => buildPath(outputDir, s.baseName.stripExtension ~ ".class"))
            .filter!(p => exists(p))
            .array;
    }
}

struct JavaCompileResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 800.0f / executionTimeMs : 1.0f;
    }
}

/// Kotlin compilation integration
struct KotlinWorkerIntegration
{
    static Result!(KotlinCompileResult, string) compile(
        string[] sources, string outputDir,
        string[] classpath = [], string[] options = [],
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("jvm-kotlinc"))
        {
            auto result = getWorkerService().compileKotlin(sources, outputDir, classpath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(KotlinCompileResult, string)(KotlinCompileResult(
                    r.success, r.output, r.executionTimeMs, true, []
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return compileKotlinDirect(sources, outputDir, classpath, options);
    }
    
    private static Result!(KotlinCompileResult, string) compileKotlinDirect(
        string[] sources, string outputDir, string[] classpath, string[] options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["kotlinc", "-d", outputDir];
        if (classpath.length > 0)
        {
            version(Windows) { cmd ~= ["-cp", classpath.join(";")]; }
            else { cmd ~= ["-cp", classpath.join(":")]; }
        }
        cmd ~= options ~ sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        
        if (result.status != 0)
            return Err!(KotlinCompileResult, string)("Compilation failed: " ~ result.output);
        
        return Ok!(KotlinCompileResult, string)(KotlinCompileResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, []
        ));
    }
}

struct KotlinCompileResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 2000.0f / executionTimeMs : 1.0f;
    }
}

// ==================== TypeScript Integration ====================

/// TypeScript compilation integration
struct TypeScriptWorkerIntegration
{
    static Result!(TSWorkerCompileResult, string) compile(
        string[] sources, string outDir,
        TSWorkerCompileOptions options = TSWorkerCompileOptions.init,
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("ts-tsc"))
        {
            TSCompileOptions tsOpts;
            tsOpts.target = options.target;
            tsOpts.module_ = options.module_;
            tsOpts.sourceMap = options.sourceMap;
            tsOpts.declaration = options.declaration;
            tsOpts.strict = options.strict;
            tsOpts.extraArgs = options.extraArgs;
            
            auto result = getWorkerService().compileTypeScript(sources, outDir, tsOpts);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(TSWorkerCompileResult, string)(TSWorkerCompileResult(
                    r.success, r.output, r.executionTimeMs, true, [],
                    r.diagnostics.map!(d => TSWorkerDiagnostic(d.file, d.line, d.column, d.message, d.severity)).array
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return compileTypeScriptDirect(sources, outDir, options);
    }
    
    static Result!(TSWorkerCompileResult, string) compileWithSWC(
        string[] sources, string outDir,
        TSWorkerCompileOptions options = TSWorkerCompileOptions.init,
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("ts-swc"))
        {
            TSCompileOptions tsOpts;
            tsOpts.target = options.target;
            tsOpts.module_ = options.module_;
            tsOpts.sourceMap = options.sourceMap;
            tsOpts.extraArgs = options.extraArgs;
            
            auto result = getWorkerService().compileWithSWC(sources, outDir, tsOpts);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(TSWorkerCompileResult, string)(TSWorkerCompileResult(
                    r.success, r.output, r.executionTimeMs, true, [], []
                ));
            }
        }
        return compileTypeScriptDirect(sources, outDir, options);
    }
    
    private static Result!(TSWorkerCompileResult, string) compileTypeScriptDirect(
        string[] sources, string outDir, TSWorkerCompileOptions options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["npx", "tsc", "--outDir", outDir];
        if (!options.target.empty) cmd ~= ["--target", options.target];
        if (!options.module_.empty) cmd ~= ["--module", options.module_];
        if (options.sourceMap) cmd ~= "--sourceMap";
        if (options.declaration) cmd ~= "--declaration";
        if (options.strict) cmd ~= "--strict";
        cmd ~= options.extraArgs ~ sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        
        if (result.status != 0)
            return Err!(TSWorkerCompileResult, string)("Compilation failed: " ~ result.output);
        
        return Ok!(TSWorkerCompileResult, string)(TSWorkerCompileResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
}

struct TSWorkerCompileOptions
{
    string target = "ES2020";
    string module_ = "commonjs";
    bool sourceMap = true;
    bool declaration = false;
    bool strict = true;
    string[] extraArgs;
}

struct TSWorkerCompileResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    TSWorkerDiagnostic[] diagnostics;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 400.0f / executionTimeMs : 1.0f;
    }
    
    bool hasErrors() const @safe
    {
        return diagnostics.any!(d => d.severity == "error");
    }
}

struct TSWorkerDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string severity;
}

// ==================== Rust Integration ====================

/// Rust compilation integration
struct RustWorkerIntegration
{
    static Result!(RustWorkerResult, string) build(
        string manifestPath, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("rust-cargo"))
        {
            auto result = getWorkerService().buildRust(manifestPath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(RustWorkerResult, string)(RustWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, r.outputFiles,
                    r.diagnostics.map!(d => RustWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return buildRustDirect(manifestPath, options);
    }
    
    static Result!(RustWorkerResult, string) check(
        string manifestPath, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("rust-cargo-check"))
        {
            auto result = getWorkerService().checkRust(manifestPath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(RustWorkerResult, string)(RustWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, [],
                    r.diagnostics.map!(d => RustWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
        }
        return checkRustDirect(manifestPath, options);
    }
    
    static Result!(RustWorkerResult, string) clippy(
        string manifestPath, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("rust-clippy"))
        {
            auto result = getWorkerService().lintRust(manifestPath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(RustWorkerResult, string)(RustWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, [],
                    r.diagnostics.map!(d => RustWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
        }
        return clippyRustDirect(manifestPath, options);
    }
    
    private static Result!(RustWorkerResult, string) buildRustDirect(string manifestPath, string[] options) @trusted
    {
        import std.process : execute;
        string[] cmd = ["cargo", "build"];
        if (!manifestPath.empty) cmd ~= ["--manifest-path", manifestPath];
        cmd ~= options;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        if (result.status != 0)
            return Err!(RustWorkerResult, string)("Build failed: " ~ result.output);
        
        return Ok!(RustWorkerResult, string)(RustWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
    
    private static Result!(RustWorkerResult, string) checkRustDirect(string manifestPath, string[] options) @trusted
    {
        import std.process : execute;
        string[] cmd = ["cargo", "check"];
        if (!manifestPath.empty) cmd ~= ["--manifest-path", manifestPath];
        cmd ~= options;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        if (result.status != 0)
            return Err!(RustWorkerResult, string)("Check failed: " ~ result.output);
        
        return Ok!(RustWorkerResult, string)(RustWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
    
    private static Result!(RustWorkerResult, string) clippyRustDirect(string manifestPath, string[] options) @trusted
    {
        import std.process : execute;
        string[] cmd = ["cargo", "clippy"];
        if (!manifestPath.empty) cmd ~= ["--manifest-path", manifestPath];
        cmd ~= options;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        if (result.status != 0)
            return Err!(RustWorkerResult, string)("Clippy failed: " ~ result.output);
        
        return Ok!(RustWorkerResult, string)(RustWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
}

struct RustWorkerResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    RustWorkerDiagnostic[] diagnostics;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 800.0f / executionTimeMs : 1.0f;
    }
}

struct RustWorkerDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string level;
}

// ==================== Go Integration ====================

/// Go compilation integration
struct GoWorkerIntegration
{
    static Result!(GoWorkerResult, string) build(
        string[] packages, string outputPath = "", string[] options = [],
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("go-build"))
        {
            auto result = getWorkerService().buildGo(packages, outputPath, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(GoWorkerResult, string)(GoWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, r.outputFiles,
                    r.diagnostics.map!(d => GoWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return buildGoDirect(packages, outputPath, options);
    }
    
    static Result!(GoWorkerResult, string) test(
        string[] packages, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("go-test"))
        {
            auto result = getWorkerService().testGo(packages, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(GoWorkerResult, string)(GoWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, [],
                    r.diagnostics.map!(d => GoWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
        }
        return testGoDirect(packages, options);
    }
    
    static Result!(GoWorkerResult, string) vet(
        string[] packages, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("go-vet"))
        {
            auto result = getWorkerService().vetGo(packages, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(GoWorkerResult, string)(GoWorkerResult(
                    r.success, r.output, r.executionTimeMs, true, [],
                    r.diagnostics.map!(d => GoWorkerDiagnostic(d.file, d.line, d.column, d.message, d.level)).array
                ));
            }
        }
        return vetGoDirect(packages, options);
    }
    
    private static Result!(GoWorkerResult, string) buildGoDirect(
        string[] packages, string outputPath, string[] options
    ) @trusted
    {
        import std.process : execute;
        string[] cmd = ["go", "build"];
        if (!outputPath.empty) cmd ~= ["-o", outputPath];
        cmd ~= options ~ packages;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        if (result.status != 0)
            return Err!(GoWorkerResult, string)("Build failed: " ~ result.output);
        
        return Ok!(GoWorkerResult, string)(GoWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false,
            outputPath.empty ? [] : [outputPath], []
        ));
    }
    
    private static Result!(GoWorkerResult, string) testGoDirect(string[] packages, string[] options) @trusted
    {
        import std.process : execute;
        auto startTime = MonoTime.currTime;
        auto result = execute(["go", "test"] ~ options ~ packages);
        if (result.status != 0)
            return Err!(GoWorkerResult, string)("Test failed: " ~ result.output);
        
        return Ok!(GoWorkerResult, string)(GoWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
    
    private static Result!(GoWorkerResult, string) vetGoDirect(string[] packages, string[] options) @trusted
    {
        import std.process : execute;
        auto startTime = MonoTime.currTime;
        auto result = execute(["go", "vet"] ~ options ~ packages);
        if (result.status != 0)
            return Err!(GoWorkerResult, string)("Vet failed: " ~ result.output);
        
        return Ok!(GoWorkerResult, string)(GoWorkerResult(
            true, result.output, (MonoTime.currTime - startTime).total!"msecs", false, [], []
        ));
    }
}

struct GoWorkerResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    GoWorkerDiagnostic[] diagnostics;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 100.0f / executionTimeMs : 1.0f;
    }
}

struct GoWorkerDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string level;
}

// ==================== Python Integration ====================

/// Python tooling integration
struct PythonWorkerIntegration
{
    static Result!(PythonWorkerResult, string) typecheck(
        string[] paths, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("python-mypy"))
        {
            auto result = getWorkerService().typecheckPython(paths, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
                    r.success, r.output, r.executionTimeMs, true,
                    r.diagnostics.map!(d => PythonWorkerDiagnostic(d.file, d.line, d.column, d.message, d.code, d.level)).array
                ));
            }
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        return typecheckPythonDirect(paths, options);
    }
    
    static Result!(PythonWorkerResult, string) lint(
        string[] paths, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("python-ruff"))
        {
            auto result = getWorkerService().lintPython(paths, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
                    r.success, r.output, r.executionTimeMs, true,
                    r.diagnostics.map!(d => PythonWorkerDiagnostic(d.file, d.line, d.column, d.message, d.code, d.level)).array
                ));
            }
        }
        return lintPythonDirect(paths, options);
    }
    
    static Result!(PythonWorkerResult, string) test(
        string[] paths, string[] options = [], bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("python-pytest"))
        {
            auto result = getWorkerService().testPython(paths, options);
            if (result.isOk)
            {
                auto r = result.unwrap();
                return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
                    r.success, r.output, r.executionTimeMs, true,
                    r.diagnostics.map!(d => PythonWorkerDiagnostic(d.file, d.line, d.column, d.message, d.code, d.level)).array
                ));
            }
        }
        return testPythonDirect(paths, options);
    }
    
    private static Result!(PythonWorkerResult, string) typecheckPythonDirect(string[] paths, string[] options) @trusted
    {
        import std.process : execute;
        auto startTime = MonoTime.currTime;
        auto result = execute(["python3", "-m", "mypy"] ~ options ~ paths);
        
        return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
            result.status == 0, result.output, (MonoTime.currTime - startTime).total!"msecs", false, []
        ));
    }
    
    private static Result!(PythonWorkerResult, string) lintPythonDirect(string[] paths, string[] options) @trusted
    {
        import std.process : execute;
        auto startTime = MonoTime.currTime;
        auto result = execute(["ruff", "check"] ~ options ~ paths);
        
        return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
            result.status == 0, result.output, (MonoTime.currTime - startTime).total!"msecs", false, []
        ));
    }
    
    private static Result!(PythonWorkerResult, string) testPythonDirect(string[] paths, string[] options) @trusted
    {
        import std.process : execute;
        auto startTime = MonoTime.currTime;
        auto result = execute(["pytest"] ~ options ~ paths);
        
        return Ok!(PythonWorkerResult, string)(PythonWorkerResult(
            result.status == 0, result.output, (MonoTime.currTime - startTime).total!"msecs", false, []
        ));
    }
}

struct PythonWorkerResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    PythonWorkerDiagnostic[] diagnostics;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        return usedPersistentWorker && executionTimeMs > 0 ? 1500.0f / executionTimeMs : 1.0f;
    }
}

struct PythonWorkerDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string code;
    string level;
}

// ==================== Global Functions ====================

/// Initialize persistent workers - call at build system startup
void initializePersistentWorkers(WorkerServiceConfig config = WorkerServiceConfig.init) @trusted
{
    initWorkerService(config);
    Logger.info("Persistent workers initialized - expect 3-50x speedup for multi-language compilation");
}

/// Shutdown persistent workers - call at build system shutdown
void shutdownPersistentWorkers() @trusted
{
    shutdownWorkerService();
}

/// Get metrics about worker performance
WorkerPerformanceMetrics getWorkerPerformanceMetrics() @trusted
{
    auto service = getWorkerService();
    if (service is null)
        return WorkerPerformanceMetrics.init;
    
    auto metrics = service.getMetrics();
    
    return WorkerPerformanceMetrics(
        metrics.totalCompilations,
        metrics.totalCompilations > 0 
            ? cast(float)metrics.successfulCompilations / metrics.totalCompilations 
            : 0.0f,
        metrics.averageSpeedupFactor,
        metrics.totalSavedTime.total!"msecs"
    );
}

/// Summary metrics for worker performance
struct WorkerPerformanceMetrics
{
    size_t totalCompilations;
    float successRate;
    float averageSpeedup;
    long estimatedTimeSavedMs;
    
    string toString() const pure @safe
    {
        return "Persistent Workers: " ~ totalCompilations.to!string ~ " compilations, " ~
               (successRate * 100).to!string ~ "% success, " ~
               averageSpeedup.to!string ~ "x avg speedup, " ~
               (estimatedTimeSavedMs / 1000).to!string ~ "s total saved";
    }
}

