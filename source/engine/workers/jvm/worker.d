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
import engine.workers.base;
import infrastructure.errors;
import infrastructure.utils.logging;

/// JVM Persistent Worker Factory
/// 
/// Creates persistent workers for JVM-based compilers (javac, kotlinc, scalac).
/// Keeps JVM warm to avoid ~500ms-2s startup overhead per compilation.
/// 
/// Speedup: 10-50x for incremental compilations
/// 
/// Protocol: Bazel-compatible persistent worker protocol
/// - Input: JSON WorkRequest on stdin (newline-delimited)
/// - Output: JSON WorkResponse on stdout (newline-delimited)

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
    string javaHome;                       /// JAVA_HOME path
    string compilerPath;                   /// Override compiler path
    string[] jvmArgs;                      /// JVM arguments (-Xmx, -XX:, etc.)
    string[] compilerArgs;                 /// Default compiler arguments
    Duration startupTimeout = seconds(30);
    Duration requestTimeout = minutes(5);
    size_t maxHeapMB = 2048;               /// Max heap size
    bool enableIncrementalCompilation = true;
    string annotationProcessorPath;
}

/// JVM Persistent Worker Factory - extends base with JVM-specific logic
final class JVMWorkerFactory : BasePersistentWorkerFactory
{
    private JVMWorkerConfig config;
    private string workerWrapperPath;
    
    this(JVMWorkerConfig config = JVMWorkerConfig.init) @trusted
    {
        // Configure base with JVM-appropriate settings
        BaseWorkerConfig baseCfg;
        baseCfg.startupTimeout = config.startupTimeout;
        baseCfg.requestTimeout = config.requestTimeout;
        baseCfg.idleTimeout = minutes(5);
        baseCfg.maxRequests = 5000;
        baseCfg.coldStartMs = coldStartFor(config.compiler);
        
        super(baseCfg);
        this.config = config;
        this.workerWrapperPath = findOrCreateWorkerWrapper();
    }
    
    override string workerType() const pure nothrow @safe
    {
        final switch (config.compiler)
        {
            case JVMCompiler.Javac: return "jvm-javac";
            case JVMCompiler.Kotlinc: return "jvm-kotlinc";
            case JVMCompiler.Scalac: return "jvm-scalac";
            case JVMCompiler.Groovyc: return "jvm-groovyc";
        }
    }
    
    override PersistentWorkerConfig defaultConfig() const @safe
    {
        auto cfg = super.defaultConfig();
        cfg.executable = workerWrapperPath;
        cfg.baseArgs = buildWorkerArgs();
        cfg.idleTimeout = minutes(5);
        cfg.maxRequests = 5000;
        return cfg;
    }
    
    protected override string[] buildWorkerArgs() const @trusted
    {
        string[] args;
        
        // JVM memory settings
        args ~= "-Xmx" ~ config.maxHeapMB.to!string ~ "m";
        
        // Tiered compilation for faster startup
        args ~= "-XX:+TieredCompilation";
        args ~= "-XX:TieredStopAtLevel=1";
        
        // Class data sharing for faster startup
        args ~= "-Xshare:auto";
        
        // GC logging for memory monitoring
        args ~= "-Xlog:gc*:stderr:time";
        
        // User-provided JVM args
        args ~= config.jvmArgs;
        
        // Worker mode flag
        args ~= "--persistent_worker";
        
        // Compiler-specific args
        args ~= config.compilerArgs;
        
        return args;
    }
    
    protected override string getExecutable() const @trusted
    {
        return workerWrapperPath.length > 0 ? workerWrapperPath : getCompilerPath();
    }
    
    protected override string[string] buildEnvironment() const @trusted
    {
        auto env = super.buildEnvironment();
        
        // Set JAVA_HOME if configured
        if (!config.javaHome.empty)
            env["JAVA_HOME"] = config.javaHome;
        
        // Compiler-specific env vars
        final switch (config.compiler)
        {
            case JVMCompiler.Javac:
                break;
            case JVMCompiler.Kotlinc:
                env["KOTLIN_COMPILER_ENVIRONMENT_KEEPALIVE"] = "1";
                break;
            case JVMCompiler.Scalac:
                env["SCALA_COMPILER_PERSISTENCE"] = "1";
                break;
            case JVMCompiler.Groovyc:
                break;
        }
        
        return env;
    }
    
    /// Cold start time estimate for speedup calculation
    private static long coldStartFor(JVMCompiler compiler) pure nothrow @safe @nogc
    {
        final switch (compiler)
        {
            case JVMCompiler.Javac: return 800;
            case JVMCompiler.Kotlinc: return 2000;
            case JVMCompiler.Scalac: return 1500;
            case JVMCompiler.Groovyc: return 1000;
        }
    }
    
    /// Find or create the worker wrapper script/JAR
    private string findOrCreateWorkerWrapper() @trusted
    {
        auto possiblePaths = [
            buildPath(thisExePath().dirName, "jvm-worker.jar"),
            buildPath(thisExePath().dirName, "..", "lib", "jvm-worker.jar"),
            "/usr/local/lib/bldr/jvm-worker.jar"
        ];
        
        foreach (path; possiblePaths)
            if (exists(path))
                return path;
        
        // Fall back to direct compiler invocation
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
        
        return compilerName;
    }
}

/// Compile sources using JVM persistent worker
/// Main entry point for JVM compilation with warm workers - 10-50x speedup
Result!(CompilationResult, WorkerError) compileWithJVMWorker(
    WorkerPool pool,
    JVMCompiler compiler,
    string[] sources,
    string outputDir,
    string[] classpath = [],
    string[] options = []
) @trusted
{
    string workerType;
    final switch (compiler)
    {
        case JVMCompiler.Javac: workerType = "jvm-javac"; break;
        case JVMCompiler.Kotlinc: workerType = "jvm-kotlinc"; break;
        case JVMCompiler.Scalac: workerType = "jvm-scalac"; break;
        case JVMCompiler.Groovyc: workerType = "jvm-groovyc"; break;
    }
    
    // Build arguments
    string[] args = ["-d", outputDir];
    
    if (classpath.length > 0)
        args ~= ["-cp", classpath.join(pathSeparator.to!string)];
    
    args ~= options;
    args ~= sources;
    
    // Build input files for caching
    InputFile[] inputs = sources
        .filter!(src => exists(src))
        .map!(src => InputFile(src, ""))
        .array;
    
    auto result = pool.execute(workerType, args, inputs);
    
    if (result.isErr)
        return Err!(CompilationResult, WorkerError)(result.unwrapErr());
    
    auto response = result.unwrap();
    
    return Ok!(CompilationResult, WorkerError)(CompilationResult(
        response.success,
        response.output,
        response.executionTimeMs,
        response.wasCached,
        []
    ));
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

/// Path separator for classpath
version(Windows) { enum pathSeparator = ";"; }
else { enum pathSeparator = ":"; }

