module languages.compiled.cpp.tooling.tools;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.cpp.core.config;
// import languages.compiled.cpp.tooling.toolchain; // Replaced by unified toolchain system
import infrastructure.toolchain.core.spec;
import infrastructure.utils.logging;

/// Convert CppStandard enum to compiler flag
private string cppStandardToFlag(CppStandard std)
{
    final switch (std)
    {
        case CppStandard.Cpp98: return "c++98";
        case CppStandard.Cpp03: return "c++03";
        case CppStandard.Cpp11: return "c++11";
        case CppStandard.Cpp14: return "c++14";
        case CppStandard.Cpp17: return "c++17";
        case CppStandard.Cpp20: return "c++20";
        case CppStandard.Cpp23: return "c++23";
        case CppStandard.Cpp26: return "c++26";
        case CppStandard.GnuCpp98: return "gnu++98";
        case CppStandard.GnuCpp03: return "gnu++03";
        case CppStandard.GnuCpp11: return "gnu++11";
        case CppStandard.GnuCpp14: return "gnu++14";
        case CppStandard.GnuCpp17: return "gnu++17";
        case CppStandard.GnuCpp20: return "gnu++20";
        case CppStandard.GnuCpp23: return "gnu++23";
        case CppStandard.GnuCpp26: return "gnu++26";
    }
}

/// Result from static analysis tool
struct AnalysisResult
{
    bool success;
    string error;
    bool hadIssues;
    string[] issues;
    string[] warnings;
    string[] errors;
}

/// Clang-Tidy static analyzer
class ClangTidy
{
    /// Check if clang-tidy is available
    static bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("clang-tidy").empty;
    }
    
    /// Get version
    static string getVersion()
    {
        auto res = execute(["clang-tidy", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Run clang-tidy on sources
    static AnalysisResult analyze(
        string[] sources,
        CppConfig config,
        string[] extraChecks = []
    )
    {
        AnalysisResult result;
        
        if (!isAvailable())
        {
            result.error = "clang-tidy not available";
            return result;
        }
        
        structuredLog.info("running_clangtidy").emit();
        
        // Build checks list
        string[] checks = [
            "bugprone-*",
            "cert-*",
            "clang-analyzer-*",
            "cppcoreguidelines-*",
            "modernize-*",
            "performance-*",
            "readability-*"
        ];
        checks ~= extraChecks;
        
        string checkStr = checks.join(",");
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = [
                "clang-tidy",
                source,
                "--checks=" ~ checkStr
            ];
            
            // Add include paths
            foreach (inc; config.includeDirs)
            {
                cmd ~= ["--", "-I" ~ inc];
            }
            
            // Add defines
            foreach (def; config.defines)
            {
                cmd ~= ["--", "-D" ~ def];
            }
            
            // Add standard
            cmd ~= ["--", "-std=" ~ cppStandardToFlag(config.cppStandard)];
            
            structuredLog.debug_("analyzing_").field("detail", "Analyzing: " ~ source).emit();
            
            auto res = execute(cmd);
            
            // clang-tidy returns non-zero if issues found
            if (res.status != 0 || !res.output.empty)
            {
                result.hadIssues = true;
                
                // Parse output for errors and warnings
                foreach (line; res.output.split("\n"))
                {
                    if (line.canFind("error:"))
                    {
                        result.errors ~= line;
                    }
                    else if (line.canFind("warning:"))
                    {
                        result.warnings ~= line;
                    }
                    else if (!line.strip.empty)
                    {
                        result.issues ~= line;
                    }
                }
            }
        }
        
        result.success = true;
        return result;
    }
}

/// CppCheck static analyzer
class CppCheck
{
    /// Check if cppcheck is available
    static bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("cppcheck").empty;
    }
    
    /// Get version
    static string getVersion()
    {
        auto res = execute(["cppcheck", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Run cppcheck on sources
    static AnalysisResult analyze(
        string[] sources,
        CppConfig config
    )
    {
        AnalysisResult result;
        
        if (!isAvailable())
        {
            result.error = "cppcheck not available";
            return result;
        }
        
        structuredLog.info("running_cppcheck").emit();
        
        string[] cmd = [
            "cppcheck",
            "--enable=all",
            "--inconclusive",
            "--std=" ~ cppStandardToFlag(config.cppStandard),
            "--quiet"
        ];
        
        // Add include paths
        foreach (inc; config.includeDirs)
        {
            cmd ~= "-I" ~ inc;
        }
        
        // Add defines
        foreach (def; config.defines)
        {
            cmd ~= "-D" ~ def;
        }
        
        // Add sources
        cmd ~= sources;
        
        auto res = execute(cmd);
        
        // Parse output
        if (!res.output.empty)
        {
            result.hadIssues = true;
            
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("error:"))
                {
                    result.errors ~= line;
                }
                else if (line.canFind("warning:"))
                {
                    result.warnings ~= line;
                }
                else if (!line.strip.empty)
                {
                    result.issues ~= line;
                }
            }
        }
        
        result.success = true;
        return result;
    }
}

/// Clang-Format code formatter
class ClangFormat
{
    /// Check if clang-format is available
    static bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("clang-format").empty;
    }
    
    /// Get version
    static string getVersion()
    {
        auto res = execute(["clang-format", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Format source files
    static bool format(
        string[] sources,
        string style = "LLVM",
        bool inPlace = true
    )
    {
        if (!isAvailable())
        {
            structuredLog.warning("clangformat_not_available").emit();
            return false;
        }
        
        structuredLog.info("formatting_code_with_clangformat").emit();
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = [
                "clang-format",
                "--style=" ~ style
            ];
            
            if (inPlace)
            {
                cmd ~= "-i";
            }
            
            cmd ~= source;
            
            structuredLog.debug_("formatting_").field("detail", "Formatting: " ~ source).emit();
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                structuredLog.error("failed_to_format_").field("detail", "Failed to format " ~ source).emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
                return false;
            }
        }
        
        structuredLog.info("code_formatted_successfully").emit();
        return true;
    }
    
    /// Check if files are formatted correctly
    static bool check(
        string[] sources,
        string style = "LLVM"
    )
    {
        if (!isAvailable())
        {
            return false;
        }
        
        bool allFormatted = true;
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = [
                "clang-format",
                "--style=" ~ style,
                "--dry-run",
                "--Werror",
                source
            ];
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                structuredLog.warning("file_not_properly_formatted_").field("detail", "File not properly formatted: " ~ source).emit();
                allFormatted = false;
            }
        }
        
        return allFormatted;
    }
}

/// Sanitizer result
struct SanitizerResult
{
    bool success;
    string error;
    bool hadIssues;
    string[] issues;
}

/// Sanitizer runner
class SanitizerRunner
{
    /// Run executable with sanitizers enabled
    static SanitizerResult run(
        string executable,
        Sanitizer[] sanitizers,
        string[] args = []
    )
    {
        SanitizerResult result;
        
        if (!exists(executable))
        {
            result.error = "Executable not found: " ~ executable;
            return result;
        }
        
        structuredLog.info("running_with_sanitizers_").field("detail", "Running with sanitizers: " ~ sanitizers.to!string).emit();
        
        // Build environment with sanitizer options
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        // Configure sanitizer options
        foreach (san; sanitizers)
        {
            final switch (san)
            {
                case Sanitizer.None:
                    break;
                case Sanitizer.Address:
                    env["ASAN_OPTIONS"] = "detect_leaks=1:check_initialization_order=1";
                    break;
                case Sanitizer.Thread:
                    env["TSAN_OPTIONS"] = "history_size=7";
                    break;
                case Sanitizer.Memory:
                    env["MSAN_OPTIONS"] = "poison_in_dtor=1";
                    break;
                case Sanitizer.UndefinedBehavior:
                    env["UBSAN_OPTIONS"] = "print_stacktrace=1";
                    break;
                case Sanitizer.Leak:
                    env["LSAN_OPTIONS"] = "report_objects=1";
                    break;
                case Sanitizer.HWAddress:
                    env["HWASAN_OPTIONS"] = "print_stacktrace=1";
                    break;
            }
        }
        
        // Run executable
        string[] cmd = [executable] ~ args;
        
        auto res = execute(cmd, env);
        
        if (res.status != 0)
        {
            result.hadIssues = true;
            
            // Parse sanitizer output
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("ERROR:") || 
                    line.canFind("WARNING:") ||
                    line.canFind("Sanitizer"))
                {
                    result.issues ~= line;
                }
            }
        }
        
        result.success = true;
        return result;
    }
}

/// Code coverage tool
class CoverageTool
{
    /// Check if gcov is available
    static bool isGcovAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("gcov").empty;
    }
    
    /// Check if llvm-cov is available
    static bool isLlvmCovAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("llvm-cov").empty;
    }
    
    /// Generate coverage report
    static bool generateReport(
        string[] gcdaFiles,
        string outputDir,
        string format = "html"
    )
    {
        // Try lcov first (if available)
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        if (!ExecutableDetector.findInPath("lcov").empty)
        {
            return generateLcovReport(gcdaFiles, outputDir);
        }
        
        // Fallback to gcov
        if (isGcovAvailable())
        {
            return generateGcovReport(gcdaFiles, outputDir);
        }
        
        structuredLog.warning("no_coverage_tool_available").emit();
        return false;
    }
    
    private static bool generateGcovReport(string[] gcdaFiles, string outputDir)
    {
        structuredLog.info("generating_coverage_report_with_gcov").emit();
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        foreach (gcda; gcdaFiles)
        {
            auto res = execute(["gcov", gcda]);
            if (res.status != 0)
            {
                structuredLog.error("gcov_failed").emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
                return false;
            }
        }
        
        return true;
    }
    
    private static bool generateLcovReport(string[] gcdaFiles, string outputDir)
    {
        structuredLog.info("generating_coverage_report_with_lcov").emit();
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        string infoFile = buildPath(outputDir, "coverage.info");
        string htmlDir = buildPath(outputDir, "html");
        
        // Generate .info file
        auto res = execute(["lcov", "--capture", "--directory", ".", "--output-file", infoFile]);
        if (res.status != 0)
        {
            structuredLog.error("lcov_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        // Generate HTML report
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        if (!ExecutableDetector.findInPath("genhtml").empty)
        {
            res = execute(["genhtml", infoFile, "--output-directory", htmlDir]);
            if (res.status != 0)
            {
                structuredLog.error("genhtml_failed").emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
                return false;
            }
            
            structuredLog.info("coverage_report_generated_").field("detail", "Coverage report generated: " ~ htmlDir).emit();
        }
        
        return true;
    }
}

