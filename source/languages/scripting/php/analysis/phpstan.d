module languages.scripting.php.analysis.phpstan;

import languages.scripting.php.analysis.base;
import languages.scripting.php.core.config;
import languages.scripting.php.tooling.detection;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// PHPStan static analyzer
class PHPStanAnalyzer : Analyzer
{
    AnalysisResult analyze(
        const string[] sources,
        AnalysisConfig config,
        const string projectRoot
    )
    {
        AnalysisResult result;
        
        string phpstanCmd = PHPTools.getPHPStanCommand();
        if (phpstanCmd.empty)
        {
            result.success = false;
            result.errors ~= "PHPStan not found. Install: composer require --dev phpstan/phpstan";
            return result;
        }
        
        string[] cmd = [phpstanCmd, "analyze"];
        
        // Level (0-9, higher = stricter)
        cmd ~= ["--level", config.level.to!string];
        
        // Configuration file
        string configFile = config.configFile;
        if (configFile.empty)
            configFile = findConfigFile(projectRoot);
        
        if (!configFile.empty && exists(configFile))
        {
            cmd ~= ["--configuration", configFile];
        }
        
        // Memory limit
        if (!config.memoryLimit.empty)
        {
            cmd ~= ["--memory-limit", config.memoryLimit];
        }
        
        // Error format
        cmd ~= ["--error-format", "table"];
        
        // No progress bar
        cmd ~= "--no-progress";
        
        // No interaction
        cmd ~= "--no-interaction";
        
        // Baseline file (ignore existing errors)
        if (!config.baseline.empty && exists(config.baseline))
        {
            cmd ~= ["--baseline", config.baseline];
        }
        else if (config.generateBaseline && !config.baseline.empty)
        {
            // Generate baseline on first run
            string[] baselineCmd = cmd.dup;
            baselineCmd ~= ["--generate-baseline", config.baseline];
            
            structuredLog.info("generating_phpstan_baseline_").field("detail", "Generating PHPStan baseline: " ~ config.baseline).emit();
            auto baselineRes = execute(baselineCmd, null, Config.none, size_t.max, projectRoot);
            
            if (baselineRes.status == 0)
            {
                structuredLog.info("baseline_generated_successfully").emit();
                cmd ~= ["--baseline", config.baseline];
            }
        }
        
        // Paths to analyze
        if (!config.paths.empty)
            cmd ~= config.paths;
        else
            cmd ~= sources;
        
        structuredLog.info("running_phpstan_").field("detail", "Running PHPStan: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // PHPStan returns:
        // 0 = no errors
        // 1 = errors found
        // Other = fatal error
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.info("phpstan_analysis_passed_with_no_errors").emit();
        }
        else if (res.status == 1)
        {
            // Parse errors and warnings from output
            parseOutput(res.output, result);
            
            if (config.strict)
            {
                result.success = false;
            }
            else
            {
                // Warnings don't fail the build in non-strict mode
                result.success = result.errorCount == 0;
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "PHPStan failed with exit code " ~ res.status.to!string;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isPHPStanAvailable();
    }
    
    string name() const
    {
        return "PHPStan";
    }
    
    string getVersion()
    {
        string cmd = PHPTools.getPHPStanCommand();
        if (cmd.empty)
            return "not installed";
        
        auto res = execute([cmd, "--version"]);
        if (res.status == 0)
        {
            // Extract version like "PHPStan - PHP Static Analysis Tool 1.10.0"
            auto match = matchFirst(res.output, regex(`(\d+\.\d+\.\d+)`));
            if (match)
                return match[1];
            return res.output.strip;
        }
        
        return "unknown";
    }
    
    string findConfigFile(string projectRoot)
    {
        // PHPStan looks for config in this order:
        string[] configFiles = [
            "phpstan.neon",
            "phpstan.neon.dist",
            "phpstan.dist.neon"
        ];
        
        foreach (configFile; configFiles)
        {
            string fullPath = buildPath(projectRoot, configFile);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Parse PHPStan output for errors and warnings
    private void parseOutput(string output, ref AnalysisResult result)
    {
        foreach (line; output.lineSplitter)
        {
            string trimmed = line.strip;
            
            // Skip empty lines and decorative lines
            if (trimmed.empty || trimmed.all!(c => c == '-' || c == ' '))
                continue;
            
            // Count errors reported in summary
            auto errorMatch = matchFirst(trimmed, regex(`Found (\d+) error`));
            if (errorMatch)
            {
                result.errorCount = errorMatch[1].to!int;
                continue;
            }
            
            // Detect error lines (format: "Line X: Error message")
            if (trimmed.canFind("------ ") || trimmed.canFind(" Line "))
            {
                // This is likely an error line
                if (trimmed.canFind("Line ") || trimmed.canFind(":"))
                {
                    result.errors ~= trimmed;
                    if (result.errorCount == 0)
                        result.errorCount++;
                }
            }
            
            // Info messages
            if (trimmed.startsWith("[") || trimmed.canFind("Note:"))
            {
                result.warnings ~= trimmed;
            }
        }
    }
}

