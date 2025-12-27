module languages.jvm.kotlin.analysis;

/// Kotlin static analysis tools
/// 
/// Provides integration with detekt and compiler warnings.

import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// Analysis result
struct AnalysisResult
{
    bool success = false;
    string error;
    int issues = 0;
    int warnings = 0;
    int errors = 0;
    string[] violations;
}

/// Static analyzer interface
interface StaticAnalyzer
{
    /// Analyze Kotlin sources
    AnalysisResult analyze(string[] sources, AnalysisConfig config);
    
    /// Check if analyzer is available
    bool isAvailable();
    
    /// Get analyzer name
    string name() const;
}

/// Detekt analyzer implementation
class DetektAnalyzer : StaticAnalyzer
{
    override AnalysisResult analyze(string[] sources, AnalysisConfig config)
    {
        AnalysisResult result;
        
        structuredLog.info("running_detekt_analysis").emit();
        
        auto cmd = ["detekt"];
        
        // Input paths
        if (sources.length == 1 && isDir(sources[0]))
        {
            cmd ~= ["--input", sources[0]];
        }
        else
        {
            // Multiple files - use comma-separated list
            cmd ~= ["--input", sources.join(",")];
        }
        
        // Config file
        if (!config.detektConfig.empty && exists(config.detektConfig))
        {
            cmd ~= ["--config", config.detektConfig];
        }
        
        // Build upon default config
        if (config.detektBuildUponDefaultConfig)
        {
            cmd ~= ["--build-upon-default-config"];
        }
        
        // Parallel
        if (config.detektParallel)
        {
            cmd ~= ["--parallel"];
        }
        
        // Fail on warnings
        if (config.failOnWarnings)
        {
            cmd ~= ["--all-rules"];
        }
        
        auto res = execute(cmd);
        
        // detekt returns non-zero if issues found
        result.issues = res.status;
        result.success = res.status == 0 || !config.failOnErrors;
        
        if (res.status != 0)
        {
            // Parse output for violations
            result.violations = res.output.splitLines()
                .filter!(line => !line.empty && 
                               (line.canFind("Warning") || line.canFind("Error")))
                .array;
            
            result.warnings = cast(int)result.violations.count!(v => v.canFind("Warning"));
            result.errors = cast(int)result.violations.count!(v => v.canFind("Error"));
            
            if (config.failOnErrors && result.errors > 0)
            {
                result.error = format("detekt found %d errors", result.errors);
            }
            else if (config.failOnWarnings && result.warnings > 0)
            {
                result.error = format("detekt found %d warnings", result.warnings);
            }
            else
            {
                result.success = true; // Don't fail the build
            }
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto result = execute(["detekt", "--version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "detekt";
    }
}

/// Compiler warnings analyzer
class CompilerAnalyzer : StaticAnalyzer
{
    override AnalysisResult analyze(string[] sources, AnalysisConfig config)
    {
        AnalysisResult result;
        
        structuredLog.info("running_kotlin_compiler_analysis").emit();
        
        // Use kotlinc with -Werror to treat warnings as errors
        auto cmd = ["kotlinc"];
        
        // Enable all warnings
        cmd ~= ["-Xall-warnings"];
        
        // Progressive mode for stricter checks
        cmd ~= ["-progressive"];
        
        // Explicit API mode
        cmd ~= ["-Xexplicit-api=warning"];
        
        // Suppress specific warnings if configured
        // (would need to parse config.suppressWarnings)
        
        // Dry run - just check, don't produce output
        cmd ~= ["-Xno-call-assertions"];
        cmd ~= ["-Xno-param-assertions"];
        
        cmd ~= sources;
        
        // Don't actually generate output
        cmd ~= ["-d", "/dev/null"];
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        
        if (res.status != 0)
        {
            // Parse compiler output for warnings and errors
            auto lines = res.output.splitLines();
            
            result.violations = lines
                .filter!(line => line.canFind("warning:") || line.canFind("error:"))
                .array;
            
            result.warnings = cast(int)lines.count!(line => line.canFind("warning:"));
            result.errors = cast(int)lines.count!(line => line.canFind("error:"));
            result.issues = result.warnings + result.errors;
            
            if (config.failOnErrors && result.errors > 0)
            {
                result.error = format("Compiler found %d errors", result.errors);
            }
            else if (config.failOnWarnings && result.warnings > 0)
            {
                result.error = format("Compiler found %d warnings", result.warnings);
            }
            else
            {
                result.success = true;
            }
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto result = execute(["kotlinc", "-version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "kotlinc";
    }
}

/// Factory for creating analyzers
class AnalyzerFactory
{
    static StaticAnalyzer create(KotlinAnalyzer analyzer)
    {
        final switch (analyzer)
        {
            case KotlinAnalyzer.Auto:
                // Try detekt first, fallback to compiler
                auto detekt = new DetektAnalyzer();
                if (detekt.isAvailable())
                    return detekt;
                return new CompilerAnalyzer();
            
            case KotlinAnalyzer.Detekt:
                return new DetektAnalyzer();
            
            case KotlinAnalyzer.Compiler:
                return new CompilerAnalyzer();
            
            case KotlinAnalyzer.KtLint:
                // KtLint is a formatter with style checking
                // For analysis, we use detekt or compiler
                return new DetektAnalyzer();
            
            case KotlinAnalyzer.None:
                return null;
        }
    }
}

// Static availability check extension
private static bool staticIsAvailable(T : DetektAnalyzer)()
{
    auto result = execute(["detekt", "--version"]);
    return result.status == 0;
}

