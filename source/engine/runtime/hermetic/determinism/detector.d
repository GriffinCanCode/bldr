module engine.runtime.hermetic.determinism.detector;

import std.algorithm : canFind, startsWith, any;
import std.array : array, split;
import std.string : indexOf, strip;
import std.regex : regex, matchFirst;
import std.conv : to;
import infrastructure.errors;

/// Non-determinism sources
enum NonDeterminismSource
{
    Timestamp,      // Embedded timestamps
    RandomValue,    // Random values/UUIDs
    ThreadScheduling, // Thread scheduling
    BuildPath,      // Absolute build paths
    CompilerNonDet, // Compiler-specific non-determinism
    FileOrdering,   // File system ordering
    PointerAddress, // ASLR/pointer addresses
    OutputMismatch, // Output hash mismatch
    Unknown         // Unknown source
}

/// Compiler type for compiler-specific detection
enum CompilerType
{
    GCC,
    Clang,
    Rustc,
    Go,
    DMD,
    LDC,
    GDC,
    Javac,
    Scalac,
    Unknown
}

/// Detection result
struct Detection
{
    NonDeterminismSource source;
    string description;
    string[] compilerFlags;    // Suggested compiler flags
    string[] envVars;          // Suggested environment variables
    int priority;              // 1=critical, 2=high, 3=medium, 4=low
    string[] references;       // Documentation references
}

/// Non-determinism detector
struct NonDeterminismDetector
{
    /// Analyze compiler command for potential non-determinism
    static Detection[] analyzeCompilerCommand(
        string[] command,
        CompilerType compilerType = CompilerType.Unknown
    ) @safe
    {
        Detection[] detections;
        
        // Auto-detect compiler if not specified
        if (compilerType == CompilerType.Unknown)
            compilerType = detectCompiler(command);
        
        // Check for missing determinism flags
        final switch (compilerType)
        {
            case CompilerType.GCC:
            case CompilerType.GDC:
                detections ~= detectGCCIssues(command);
                break;
            
            case CompilerType.Clang:
                detections ~= detectClangIssues(command);
                break;
            
            case CompilerType.Rustc:
                detections ~= detectRustIssues(command);
                break;
            
            case CompilerType.Go:
                detections ~= detectGoIssues(command);
                break;
            
            case CompilerType.DMD:
            case CompilerType.LDC:
                detections ~= detectDIssues(command);
                break;
            
            case CompilerType.Javac:
                detections ~= detectJavaIssues(command);
                break;
            
            case CompilerType.Scalac:
                detections ~= detectScalaIssues(command);
                break;
            
            case CompilerType.Unknown:
                // Generic checks
                break;
        }
        
        return detections;
    }
    
    /// Analyze build output for non-determinism patterns
    static Detection[] analyzeBuildOutput(string stdout, string stderr) @safe
    {
        Detection[] detections;
        immutable output = stdout ~ "\n" ~ stderr;
        
        // Check for timestamp patterns
        if (containsTimestamp(output))
        {
            Detection d;
            d.source = NonDeterminismSource.Timestamp;
            d.description = "Detected timestamp patterns in output";
            d.envVars = ["SOURCE_DATE_EPOCH"];
            d.priority = 2;
            detections ~= d;
        }
        
        // Check for UUID patterns
        if (hasUUIDPattern(output))
        {
            Detection d;
            d.source = NonDeterminismSource.RandomValue;
            d.description = "Detected UUID/random value patterns in output";
            d.priority = 1;
            detections ~= d;
        }
        
        return detections;
    }
    
    /// Compare build outputs and return violations if they differ
    static Detection[] compareBuildOutputs(string hash1, string hash2, string[] files) @safe
    {
        Detection[] detections;
        
        if (hash1 != hash2)
        {
            Detection d;
            d.source = NonDeterminismSource.OutputMismatch;
            d.description = "Build outputs differ (hash mismatch)";
            d.priority = 1;
            detections ~= d;
        }
        
        return detections;
    }

    /// Detect compiler type from command
    static CompilerType detectCompiler(string[] command) pure @safe nothrow
    {
        if (command.length == 0)
            return CompilerType.Unknown;
        
        immutable compiler = command[0];
        
        if (compiler.canFind("gcc") || compiler.canFind("g++"))
            return CompilerType.GCC;
        if (compiler.canFind("clang"))
            return CompilerType.Clang;
        if (compiler.canFind("rustc"))
            return CompilerType.Rustc;
        if (compiler.canFind("go"))
            return CompilerType.Go;
        if (compiler.canFind("dmd"))
            return CompilerType.DMD;
        if (compiler.canFind("ldc"))
            return CompilerType.LDC;
        if (compiler.canFind("gdc"))
            return CompilerType.GDC;
        if (compiler.canFind("javac"))
            return CompilerType.Javac;
        if (compiler.canFind("scalac"))
            return CompilerType.Scalac;
        
        return CompilerType.Unknown;
    }

    /// Check for timestamp patterns in output
    static bool containsTimestamp(string text) @safe
    {
        // Pattern: YYYY-MM-DD or HH:MM:SS
        try
        {
            auto datePattern = regex(r"\d{4}-\d{2}-\d{2}");
            auto timePattern = regex(r"\d{2}:\d{2}:\d{2}");
            
            return !matchFirst(text, datePattern).empty || 
                   !matchFirst(text, timePattern).empty;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private:
    
    /// Detect GCC/GDC issues
    static Detection[] detectGCCIssues(string[] command) @safe
    {
        Detection[] detections;
        
        // Check for -frandom-seed
        if (!command.any!(arg => arg.startsWith("-frandom-seed")))
        {
            Detection d;
            d.source = NonDeterminismSource.CompilerNonDet;
            d.description = "GCC uses random seeds for register allocation";
            d.compilerFlags = ["-frandom-seed=42"];
            d.priority = 1;
            d.references = ["https://gcc.gnu.org/onlinedocs/gcc/Developer-Options.html"];
            detections ~= d;
        }
        
        // Check for -ffile-prefix-map
        if (!command.any!(arg => arg.startsWith("-ffile-prefix-map")))
        {
            Detection d;
            d.source = NonDeterminismSource.BuildPath;
            d.description = "Build paths may be embedded in debug info";
            d.compilerFlags = ["-ffile-prefix-map=/workspace/=./"];
            d.priority = 2;
            detections ~= d;
        }
        
        return detections;
    }
    
    /// Detect Clang issues
    static Detection[] detectClangIssues(string[] command) @safe
    {
        Detection[] detections;
        
        // Check for -fdebug-prefix-map
        if (!command.any!(arg => arg.startsWith("-fdebug-prefix-map")))
        {
            Detection d;
            d.source = NonDeterminismSource.BuildPath;
            d.description = "Build paths may be embedded in debug info";
            d.compilerFlags = ["-fdebug-prefix-map=/workspace/=./"];
            d.priority = 2;
            detections ~= d;
        }
        
        // Check for __DATE__/__TIME__ overrides
        bool hasDateOverride = command.any!(arg => arg.canFind("__DATE__"));
        bool hasTimeOverride = command.any!(arg => arg.canFind("__TIME__"));
        
        if (!hasDateOverride || !hasTimeOverride)
        {
            Detection d;
            d.source = NonDeterminismSource.Timestamp;
            d.description = "__DATE__ and __TIME__ macros embed timestamps";
            d.compilerFlags = [
                "-Wno-builtin-macro-redefined",
                "-D__DATE__=\"Jan 01 2022\"",
                "-D__TIME__=\"00:00:00\""
            ];
            d.priority = 2;
            detections ~= d;
        }
        
        return detections;
    }
    
    /// Detect Rust issues
    static Detection[] detectRustIssues(string[] command) @safe
    {
        Detection[] detections;
        
        // Check for incremental compilation
        if (command.any!(arg => arg.canFind("incremental")))
        {
            Detection d;
            d.source = NonDeterminismSource.CompilerNonDet;
            d.description = "Rust incremental compilation is non-deterministic";
            d.compilerFlags = ["-Cincremental=false"];
            d.priority = 1;
            detections ~= d;
        }
        
        // Check for embed-bitcode
        if (!command.any!(arg => arg.canFind("embed-bitcode")))
        {
            Detection d;
            d.source = NonDeterminismSource.CompilerNonDet;
            d.description = "Bitcode embedding improves determinism";
            d.compilerFlags = ["-Cembed-bitcode=yes"];
            d.priority = 3;
            detections ~= d;
        }
        
        return detections;
    }
    
    /// Detect Go issues
    static Detection[] detectGoIssues(string[] command) @safe
    {
        Detection[] detections;
        
        // Check for -trimpath
        if (!command.any!(arg => arg == "-trimpath"))
        {
            Detection d;
            d.source = NonDeterminismSource.BuildPath;
            d.description = "Go embeds build paths in binaries";
            d.compilerFlags = ["-trimpath"];
            d.priority = 2;
            detections ~= d;
        }
        
        return detections;
    }
    
    /// Detect D compiler issues
    static Detection[] detectDIssues(string[] command) @safe
    {
        Detection[] detections;
        
        // Suggest SOURCE_DATE_EPOCH
        Detection d;
        d.source = NonDeterminismSource.Timestamp;
        d.description = "D compilers respect SOURCE_DATE_EPOCH for reproducibility";
        d.envVars = ["SOURCE_DATE_EPOCH=1640995200"];
        d.priority = 3;
        detections ~= d;
        
        return detections;
    }
    
    /// Detect Java issues
    static Detection[] detectJavaIssues(string[] command) @safe
    {
        Detection[] detections;
        
        Detection d;
        d.source = NonDeterminismSource.Timestamp;
        d.description = "Java class files embed timestamps";
        d.envVars = ["SOURCE_DATE_EPOCH=1640995200"];
        d.priority = 2;
        detections ~= d;
        
        return detections;
    }
    
    /// Detect Scala issues
    static Detection[] detectScalaIssues(string[] command) @safe
    {
        Detection[] detections;
        
        Detection d;
        d.source = NonDeterminismSource.Timestamp;
        d.description = "Scala compiler may embed timestamps";
        d.envVars = ["SOURCE_DATE_EPOCH=1640995200"];
        d.priority = 2;
        detections ~= d;
        
        return detections;
    }
    
    /// Check for UUID patterns in output
    static bool hasUUIDPattern(string text) @safe
    {
        // Pattern: 8-4-4-4-12 hex format
        try
        {
            auto uuidPattern = regex(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
            return !matchFirst(text, uuidPattern).empty;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

@safe unittest
{
    import std.stdio : writeln;
    
    writeln("Testing non-determinism detector...");
    
    // Test GCC detection
    auto gccDetections = NonDeterminismDetector.analyzeCompilerCommand(
        ["gcc", "main.c", "-o", "main"],
        CompilerType.GCC
    );
    assert(gccDetections.length > 0);
    assert(gccDetections[0].source == NonDeterminismSource.CompilerNonDet);
    
    // Test compiler type detection
    auto detectedType = NonDeterminismDetector.detectCompiler(["gcc", "-c", "test.c"]);
    assert(detectedType == CompilerType.GCC);
    
    detectedType = NonDeterminismDetector.detectCompiler(["rustc", "main.rs"]);
    assert(detectedType == CompilerType.Rustc);
    
    writeln("✓ Non-determinism detector tests passed");
}
