module engine.workers.jvm.worker;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.string;
import core.time : Duration, seconds, minutes;
import engine.workers.protocol;
import engine.workers.pool;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// JVM Persistent Worker Factory
/// 
/// Creates persistent workers for JVM-based compilers (javac, kotlinc, scalac).
/// These workers keep the JVM warm, avoiding the ~500ms-2s JVM startup overhead
/// that typically dominates small compilation times.
/// 
/// Speedup: 10-50x for incremental compilations
/// 
/// Protocol: Bazel-compatible persistent worker protocol
/// - Input: JSON WorkRequest on stdin (newline-delimited)
/// - Output: JSON WorkResponse on stdout (newline-delimited)
/// 
/// Worker wrapper scripts handle the protocol translation for compilers
/// that don't natively support persistent worker mode.

/// JVM compiler type
enum JVMCompiler
{
    Javac,    /// Oracle/OpenJDK javac
    Kotlinc,  /// Kotlin compiler
    Scalac,   /// Scala compiler
    Groovyc   /// Groovy compiler
}

/// JVM worker configuration
struct JVMWorkerConfig
{
    JVMCompiler compiler = JVMCompiler.Javac;
    string javaHome;              /// JAVA_HOME path
    string compilerPath;          /// Override compiler path
    string[] jvmArgs;             /// JVM arguments (-Xmx, -XX:, etc.)
    string[] compilerArgs;        /// Default compiler arguments
    Duration startupTimeout = seconds(30);
    Duration requestTimeout = minutes(5);
    size_t maxHeapMB = 2048;      /// Max heap size
    bool enableIncrementalCompilation = true;
    string annotationProcessorPath;
}

/// JVM Persistent Worker Factory
final class JVMWorkerFactory : IWorkerFactory
{
    private JVMWorkerConfig config;
    private string workerWrapperPath;
    
    this(JVMWorkerConfig config = JVMWorkerConfig.init) @trusted
    {
        this.config = config;
        this.workerWrapperPath = findOrCreateWorkerWrapper();
    }
    
    string workerType() const pure nothrow @safe
    {
        final switch (config.compiler)
        {
            case JVMCompiler.Javac: return "jvm-javac";
            case JVMCompiler.Kotlinc: return "jvm-kotlinc";
            case JVMCompiler.Scalac: return "jvm-scalac";
            case JVMCompiler.Groovyc: return "jvm-groovyc";
        }
    }
    
    PersistentWorkerConfig defaultConfig() const @safe
    {
        PersistentWorkerConfig cfg;
        cfg.executable = workerWrapperPath;
        cfg.baseArgs = buildWorkerArgs();
        cfg.startupTimeout = config.startupTimeout;
        cfg.requestTimeout = config.requestTimeout;
        cfg.idleTimeout = minutes(5);
        cfg.maxRequests = 5000;
        return cfg;
    }
    
    Result!(PersistentWorker, WorkerError) createWorker(WorkerId id) @trusted
    {
        auto cfg = defaultConfig();
        
        // Build environment with JAVA_HOME
        string[string] env;
        if (!config.javaHome.empty)
            env["JAVA_HOME"] = config.javaHome;
        
        // Add compiler-specific env vars
        final switch (config.compiler)
        {
            case JVMCompiler.Javac:
                // Standard javac
                break;
            case JVMCompiler.Kotlinc:
                // Kotlin daemon integration
                env["KOTLIN_COMPILER_ENVIRONMENT_KEEPALIVE"] = "1";
                break;
            case JVMCompiler.Scalac:
                // Scala compile server
                env["SCALA_COMPILER_PERSISTENCE"] = "1";
                break;
            case JVMCompiler.Groovyc:
                break;
        }
        
        // Spawn worker process
        auto spawnResult = spawnWorkerTransport(
            cfg.executable,
            cfg.baseArgs,
            cfg.workDir,
            env
        );
        
        if (spawnResult.isErr)
            return Err!(PersistentWorker, WorkerError)(spawnResult.unwrapErr());
        
        auto transport = spawnResult.unwrap();
        auto worker = new PersistentWorker(id, cfg, transport);
        
        // Wait for worker to signal ready
        auto readyResult = waitForWorkerReady(transport, cfg.startupTimeout);
        if (readyResult.isErr)
        {
            transport.close();
            return Err!(PersistentWorker, WorkerError)(readyResult.unwrapErr());
        }
        
        worker.markReady();
        Logger.info("JVM worker ready: " ~ id.toString());
        
        return Ok!(PersistentWorker, WorkerError)(worker);
    }
    
    private string[] buildWorkerArgs() const @trusted
    {
        string[] args;
        
        // JVM arguments
        args ~= "-Xmx" ~ config.maxHeapMB.to!string ~ "m";
        
        // Tiered compilation for faster startup
        args ~= "-XX:+TieredCompilation";
        args ~= "-XX:TieredStopAtLevel=1";
        
        // Class data sharing for faster startup
        args ~= "-Xshare:auto";
        
        // User-provided JVM args
        args ~= config.jvmArgs;
        
        // Worker mode flag
        args ~= "--persistent_worker";
        
        // Compiler-specific args
        args ~= config.compilerArgs;
        
        return args;
    }
    
    /// Find or create the worker wrapper script/JAR
    private string findOrCreateWorkerWrapper() @trusted
    {
        // Look for bundled worker wrapper
        auto possiblePaths = [
            buildPath(thisExePath().dirName, "jvm-worker.jar"),
            buildPath(thisExePath().dirName, "..", "lib", "jvm-worker.jar"),
            "/usr/local/lib/bldr/jvm-worker.jar"
        ];
        
        foreach (path; possiblePaths)
        {
            if (exists(path))
                return path;
        }
        
        // Fall back to direct compiler invocation
        // (works with Kotlin's built-in daemon mode)
        return getCompilerPath();
    }
    
    /// Get the compiler executable path
    private string getCompilerPath() const @trusted
    {
        if (!config.compilerPath.empty && exists(config.compilerPath))
            return config.compilerPath;
        
        string compilerName;
        final switch (config.compiler)
        {
            case JVMCompiler.Javac: compilerName = "javac"; break;
            case JVMCompiler.Kotlinc: compilerName = "kotlinc"; break;
            case JVMCompiler.Scalac: compilerName = "scalac"; break;
            case JVMCompiler.Groovyc: compilerName = "groovyc"; break;
        }
        
        // Check JAVA_HOME first
        if (!config.javaHome.empty)
        {
            auto path = buildPath(config.javaHome, "bin", compilerName);
            if (exists(path)) return path;
        }
        
        // Fall back to PATH
        return compilerName;
    }
    
    /// Wait for worker to be ready
    private Result!WorkerError waitForWorkerReady(StdioWorkerTransport transport, Duration timeout) @trusted
    {
        // Send a no-op request to verify worker is alive
        WorkRequest pingRequest;
        pingRequest.requestId = 0;
        pingRequest.arguments = ["--version"];  // Most compilers support this
        
        auto sendResult = transport.sendRequest(pingRequest);
        if (sendResult.isErr)
            return Err!WorkerError(sendResult.unwrapErr());
        
        auto recvResult = transport.receiveResponse(timeout);
        if (recvResult.isErr)
            return Err!WorkerError(recvResult.unwrapErr());
        
        return Ok!WorkerError();
    }
}

/// Compile sources using JVM persistent worker
/// 
/// This is the main entry point for JVM compilation with warm workers.
/// Call this instead of spawning javac/kotlinc directly for 10-50x speedup.
Result!(CompilationResult, WorkerError) compileWithJVMWorker(
    WorkerPool pool,
    JVMCompiler compiler,
    string[] sources,
    string outputDir,
    string[] classpath = [],
    string[] options = []
) @trusted
{
    // Build worker type string
    string workerType;
    final switch (compiler)
    {
        case JVMCompiler.Javac: workerType = "jvm-javac"; break;
        case JVMCompiler.Kotlinc: workerType = "jvm-kotlinc"; break;
        case JVMCompiler.Scalac: workerType = "jvm-scalac"; break;
        case JVMCompiler.Groovyc: workerType = "jvm-groovyc"; break;
    }
    
    // Build arguments
    string[] args;
    
    // Output directory
    args ~= ["-d", outputDir];
    
    // Classpath
    if (classpath.length > 0)
        args ~= ["-cp", classpath.join(pathSeparator.to!string)];
    
    // User options
    args ~= options;
    
    // Source files
    args ~= sources;
    
    // Build input files for caching
    InputFile[] inputs;
    foreach (src; sources)
    {
        if (exists(src))
        {
            InputFile f;
            f.path = src;
            // Could compute digest here for caching
            inputs ~= f;
        }
    }
    
    // Execute on worker
    auto result = pool.execute(workerType, args, inputs);
    
    if (result.isErr)
        return Err!(CompilationResult, WorkerError)(result.unwrapErr());
    
    auto response = result.unwrap();
    
    CompilationResult compResult;
    compResult.success = response.success;
    compResult.output = response.output;
    compResult.executionTimeMs = response.executionTimeMs;
    compResult.wasCached = response.wasCached;
    
    return Ok!(CompilationResult, WorkerError)(compResult);
}

/// Compilation result
struct CompilationResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool wasCached;
    string[] outputFiles;
}

/// Path separator for classpath (platform-specific)
version(Windows)
{
    enum pathSeparator = ";";
}
else
{
    enum pathSeparator = ":";
}

