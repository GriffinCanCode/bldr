module engine.workers.integration;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import core.time : Duration, seconds, msecs;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.jvm;
import engine.workers.typescript;
import engine.workers.service;
import infrastructure.errors;
import infrastructure.utils.logging.logger;
import infrastructure.utils.files.hash;

/// Integration layer for language handlers
/// 
/// Provides simple interfaces for language handlers to use persistent workers
/// without needing to manage worker lifecycle directly.

/// Check if persistent workers are available and should be used
bool shouldUsePersistentWorker(string compilerType) @safe
{
    auto service = getWorkerService();
    if (service is null || service.getStatus() != WorkerServiceStatus.Running)
        return false;
    
    // Check if worker type is registered
    // For now, always return true if service is running
    return true;
}

/// Java compilation integration
/// 
/// Drop-in replacement for direct javac invocation.
/// Returns the same result format as normal compilation.
struct JavaWorkerIntegration
{
    /// Compile Java sources with persistent worker
    /// Falls back to direct compilation if workers unavailable
    static Result!(JavaCompileResult, string) compile(
        string[] sources,
        string outputDir,
        string[] classpath = [],
        string[] options = [],
        bool usePersistentWorker = true
    ) @trusted
    {
        // Try persistent worker first
        if (usePersistentWorker && shouldUsePersistentWorker("jvm-javac"))
        {
            auto service = getWorkerService();
            auto result = service.compileJava(sources, outputDir, classpath, options);
            
            if (result.isOk)
            {
                auto r = result.unwrap();
                JavaCompileResult compResult;
                compResult.success = r.success;
                compResult.output = r.output;
                compResult.executionTimeMs = r.executionTimeMs;
                compResult.usedPersistentWorker = true;
                
                // Find output files
                compResult.outputFiles = findJavaOutputFiles(sources, outputDir);
                
                return Ok!(JavaCompileResult, string)(compResult);
            }
            
            // Log worker failure and fall back
            Logger.warning("Persistent worker failed, falling back to direct compilation: " ~ 
                          result.unwrapErr().message());
        }
        
        // Fall back to direct compilation
        return compileJavaDirect(sources, outputDir, classpath, options);
    }
    
    /// Direct javac compilation (fallback)
    private static Result!(JavaCompileResult, string) compileJavaDirect(
        string[] sources,
        string outputDir,
        string[] classpath,
        string[] options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["javac"];
        cmd ~= ["-d", outputDir];
        
        if (classpath.length > 0)
        {
            version(Windows)
                cmd ~= ["-cp", classpath.join(";")];
            else
                cmd ~= ["-cp", classpath.join(":")];
        }
        
        cmd ~= options;
        cmd ~= sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        auto execTime = (MonoTime.currTime - startTime).total!"msecs";
        
        JavaCompileResult compResult;
        compResult.success = result.status == 0;
        compResult.output = result.output;
        compResult.executionTimeMs = execTime;
        compResult.usedPersistentWorker = false;
        
        if (!compResult.success)
            return Err!(JavaCompileResult, string)("Compilation failed: " ~ result.output);
        
        compResult.outputFiles = findJavaOutputFiles(sources, outputDir);
        
        return Ok!(JavaCompileResult, string)(compResult);
    }
    
    /// Find .class files generated from sources
    private static string[] findJavaOutputFiles(string[] sources, string outputDir) @trusted
    {
        string[] outputs;
        
        foreach (src; sources)
        {
            if (!src.endsWith(".java"))
                continue;
            
            // Convert source path to expected class file path
            auto className = src.baseName.stripExtension ~ ".class";
            auto classPath = buildPath(outputDir, className);
            
            if (exists(classPath))
                outputs ~= classPath;
        }
        
        return outputs;
    }
}

/// Java compilation result
struct JavaCompileResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    
    /// Calculate speedup if persistent worker was used
    float estimatedSpeedup() const pure nothrow @safe
    {
        if (!usedPersistentWorker || executionTimeMs <= 0)
            return 1.0f;
        
        // Typical cold javac startup is ~800ms
        enum coldStartMs = 800;
        return cast(float)coldStartMs / executionTimeMs;
    }
}

/// Kotlin compilation integration
struct KotlinWorkerIntegration
{
    /// Compile Kotlin sources with persistent worker
    static Result!(KotlinCompileResult, string) compile(
        string[] sources,
        string outputDir,
        string[] classpath = [],
        string[] options = [],
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("jvm-kotlinc"))
        {
            auto service = getWorkerService();
            auto result = service.compileKotlin(sources, outputDir, classpath, options);
            
            if (result.isOk)
            {
                auto r = result.unwrap();
                KotlinCompileResult compResult;
                compResult.success = r.success;
                compResult.output = r.output;
                compResult.executionTimeMs = r.executionTimeMs;
                compResult.usedPersistentWorker = true;
                
                return Ok!(KotlinCompileResult, string)(compResult);
            }
            
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        
        return compileKotlinDirect(sources, outputDir, classpath, options);
    }
    
    private static Result!(KotlinCompileResult, string) compileKotlinDirect(
        string[] sources,
        string outputDir,
        string[] classpath,
        string[] options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["kotlinc"];
        cmd ~= ["-d", outputDir];
        
        if (classpath.length > 0)
        {
            version(Windows)
                cmd ~= ["-cp", classpath.join(";")];
            else
                cmd ~= ["-cp", classpath.join(":")];
        }
        
        cmd ~= options;
        cmd ~= sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        auto execTime = (MonoTime.currTime - startTime).total!"msecs";
        
        KotlinCompileResult compResult;
        compResult.success = result.status == 0;
        compResult.output = result.output;
        compResult.executionTimeMs = execTime;
        compResult.usedPersistentWorker = false;
        
        if (!compResult.success)
            return Err!(KotlinCompileResult, string)("Compilation failed: " ~ result.output);
        
        return Ok!(KotlinCompileResult, string)(compResult);
    }
}

/// Kotlin compilation result
struct KotlinCompileResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedPersistentWorker;
    string[] outputFiles;
    
    float estimatedSpeedup() const pure nothrow @safe
    {
        if (!usedPersistentWorker || executionTimeMs <= 0)
            return 1.0f;
        enum coldStartMs = 2000;  // Kotlin has higher startup cost
        return cast(float)coldStartMs / executionTimeMs;
    }
}

/// TypeScript compilation integration
struct TypeScriptWorkerIntegration
{
    /// Compile TypeScript sources with persistent worker
    static Result!(TSWorkerCompileResult, string) compile(
        string[] sources,
        string outDir,
        TSWorkerCompileOptions options = TSWorkerCompileOptions.init,
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("ts-tsc"))
        {
            auto service = getWorkerService();
            
            TSCompileOptions tsOpts;
            tsOpts.target = options.target;
            tsOpts.module_ = options.module_;
            tsOpts.sourceMap = options.sourceMap;
            tsOpts.declaration = options.declaration;
            tsOpts.strict = options.strict;
            tsOpts.extraArgs = options.extraArgs;
            
            auto result = service.compileTypeScript(sources, outDir, tsOpts);
            
            if (result.isOk)
            {
                auto r = result.unwrap();
                TSWorkerCompileResult compResult;
                compResult.success = r.success;
                compResult.output = r.output;
                compResult.executionTimeMs = r.executionTimeMs;
                compResult.usedPersistentWorker = true;
                compResult.diagnostics = r.diagnostics.map!(d => TSWorkerDiagnostic(
                    d.file, d.line, d.column, d.message, d.severity
                )).array;
                
                return Ok!(TSWorkerCompileResult, string)(compResult);
            }
            
            Logger.warning("Persistent worker failed, falling back: " ~ result.unwrapErr().message());
        }
        
        return compileTypeScriptDirect(sources, outDir, options);
    }
    
    /// Compile with SWC (faster, no type checking)
    static Result!(TSWorkerCompileResult, string) compileWithSWC(
        string[] sources,
        string outDir,
        TSWorkerCompileOptions options = TSWorkerCompileOptions.init,
        bool usePersistentWorker = true
    ) @trusted
    {
        if (usePersistentWorker && shouldUsePersistentWorker("ts-swc"))
        {
            auto service = getWorkerService();
            
            TSCompileOptions tsOpts;
            tsOpts.target = options.target;
            tsOpts.module_ = options.module_;
            tsOpts.sourceMap = options.sourceMap;
            tsOpts.extraArgs = options.extraArgs;
            
            auto result = service.compileTypeScriptWithSWC(sources, outDir, tsOpts);
            
            if (result.isOk)
            {
                auto r = result.unwrap();
                TSWorkerCompileResult compResult;
                compResult.success = r.success;
                compResult.output = r.output;
                compResult.executionTimeMs = r.executionTimeMs;
                compResult.usedPersistentWorker = true;
                
                return Ok!(TSWorkerCompileResult, string)(compResult);
            }
        }
        
        return compileTypeScriptDirect(sources, outDir, options);
    }
    
    private static Result!(TSWorkerCompileResult, string) compileTypeScriptDirect(
        string[] sources,
        string outDir,
        TSWorkerCompileOptions options
    ) @trusted
    {
        import std.process : execute;
        
        string[] cmd = ["npx", "tsc"];
        cmd ~= ["--outDir", outDir];
        
        if (!options.target.empty)
            cmd ~= ["--target", options.target];
        
        if (!options.module_.empty)
            cmd ~= ["--module", options.module_];
        
        if (options.sourceMap)
            cmd ~= "--sourceMap";
        
        if (options.declaration)
            cmd ~= "--declaration";
        
        if (options.strict)
            cmd ~= "--strict";
        
        cmd ~= options.extraArgs;
        cmd ~= sources;
        
        auto startTime = MonoTime.currTime;
        auto result = execute(cmd);
        auto execTime = (MonoTime.currTime - startTime).total!"msecs";
        
        TSWorkerCompileResult compResult;
        compResult.success = result.status == 0;
        compResult.output = result.output;
        compResult.executionTimeMs = execTime;
        compResult.usedPersistentWorker = false;
        
        if (!compResult.success)
            return Err!(TSWorkerCompileResult, string)("Compilation failed: " ~ result.output);
        
        return Ok!(TSWorkerCompileResult, string)(compResult);
    }
}

/// TypeScript compile options for worker integration
struct TSWorkerCompileOptions
{
    string target = "ES2020";
    string module_ = "commonjs";
    bool sourceMap = true;
    bool declaration = false;
    bool strict = true;
    string[] extraArgs;
}

/// TypeScript compilation result from worker
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
        if (!usedPersistentWorker || executionTimeMs <= 0)
            return 1.0f;
        enum coldStartMs = 400;
        return cast(float)coldStartMs / executionTimeMs;
    }
    
    bool hasErrors() const pure nothrow @safe
    {
        return diagnostics.any!(d => d.severity == "error");
    }
}

/// TypeScript diagnostic from worker
struct TSWorkerDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string severity;
}

/// Global initialization for persistent workers
/// Call this during build system startup
void initializePersistentWorkers(WorkerServiceConfig config = WorkerServiceConfig.init) @trusted
{
    initWorkerService(config);
    Logger.info("Persistent workers initialized - expect 10-50x speedup for JVM/TypeScript compilation");
}

/// Shutdown persistent workers
/// Call this during build system shutdown
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
    
    WorkerPerformanceMetrics result;
    result.totalCompilations = metrics.totalCompilations;
    result.successRate = metrics.totalCompilations > 0 
        ? cast(float)metrics.successfulCompilations / metrics.totalCompilations 
        : 0.0f;
    result.averageSpeedup = metrics.averageSpeedupFactor;
    result.estimatedTimeSavedMs = metrics.totalSavedTime.total!"msecs";
    
    return result;
}

/// Summary metrics for worker performance
struct WorkerPerformanceMetrics
{
    size_t totalCompilations;
    float successRate;
    float averageSpeedup;
    long estimatedTimeSavedMs;
    
    /// Format as human-readable string
    string toString() const pure @safe
    {
        return "Persistent Workers: " ~ totalCompilations.to!string ~ " compilations, " ~
               (successRate * 100).to!string ~ "% success, " ~
               averageSpeedup.to!string ~ "x avg speedup, " ~
               (estimatedTimeSavedMs / 1000).to!string ~ "s total saved";
    }
}

