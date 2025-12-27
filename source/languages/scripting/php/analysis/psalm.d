module languages.scripting.php.analysis.psalm;

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

/// Psalm static analyzer (security-focused)
class PsalmAnalyzer : Analyzer
{
    AnalysisResult analyze(
        const string[] sources,
        AnalysisConfig config,
        const string projectRoot
    )
    {
        AnalysisResult result;
        
        string psalmCmd = PHPTools.getPsalmCommand();
        if (psalmCmd.empty)
        {
            result.success = false;
            result.errors ~= "Psalm not found. Install: composer require --dev vimeo/psalm";
            return result;
        }
        
        string[] cmd = [psalmCmd];
        
        // Configuration file
        string configFile = config.configFile;
        if (configFile.empty)
            configFile = findConfigFile(projectRoot);
        
        if (!configFile.empty && exists(configFile))
        {
            cmd ~= ["--config", configFile];
        }
        else
        {
            // Initialize Psalm if no config exists
            structuredLog.info("no_psalm_configuration_found_initializin").emit();
            auto initCmd = [psalmCmd, "--init"];
            auto initRes = execute(initCmd, null, Config.none, size_t.max, projectRoot);
            
            if (initRes.status == 0)
            {
                configFile = buildPath(projectRoot, "psalm.xml");
                if (exists(configFile))
                    cmd ~= ["--config", configFile];
            }
        }
        
        // Show info (warnings and errors)
        cmd ~= "--show-info=true";
        
        // Memory limit
        if (!config.memoryLimit.empty)
        {
            cmd ~= ["--memory-limit", config.memoryLimit];
        }
        
        // No progress
        cmd ~= "--no-progress";
        
        // Paths to analyze
        if (!config.paths.empty)
            cmd ~= config.paths;
        else if (!sources.empty)
            cmd ~= sources;
        
        structuredLog.info("running_psalm_").field("detail", "Running Psalm: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // Psalm returns:
        // 0 = no issues
        // 1 = issues found
        // 2 = errors found
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.info("psalm_analysis_passed_with_no_issues").emit();
        }
        else
        {
            // Parse errors and warnings from output
            parseOutput(res.output, result);
            
            if (config.strict)
            {
                result.success = false;
            }
            else
            {
                // Only fail on errors, not warnings
                result.success = result.errorCount == 0;
            }
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isPsalmAvailable();
    }
    
    string name() const
    {
        return "Psalm";
    }
    
    string getVersion()
    {
        string cmd = PHPTools.getPsalmCommand();
        if (cmd.empty)
            return "not installed";
        
        auto res = execute([cmd, "--version"]);
        if (res.status == 0)
        {
            // Extract version like "Psalm 5.x.x"
            auto match = matchFirst(res.output, regex(`(\d+\.\d+\.\d+)`));
            if (match)
                return match[1];
            return res.output.strip;
        }
        
        return "unknown";
    }
    
    string findConfigFile(string projectRoot)
    {
        string[] configFiles = [
            "psalm.xml",
            "psalm.xml.dist"
        ];
        
        foreach (configFile; configFiles)
        {
            string fullPath = buildPath(projectRoot, configFile);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Parse Psalm output for errors and warnings
    private void parseOutput(string output, ref AnalysisResult result)
    {
        foreach (line; output.lineSplitter)
        {
            string trimmed = line.strip;
            
            if (trimmed.empty)
                continue;
            
            // Psalm format: "ERROR: Message (file.php:123:45)"
            // or "INFO: Message (file.php:123:45)"
            
            if (trimmed.startsWith("ERROR:"))
            {
                result.errors ~= trimmed;
                result.errorCount++;
            }
            else if (trimmed.startsWith("INFO:") || trimmed.startsWith("WARNING:"))
            {
                result.warnings ~= trimmed;
                result.warningCount++;
            }
            
            // Parse summary line
            auto errorMatch = matchFirst(trimmed, regex(`(\d+) error`));
            if (errorMatch)
            {
                result.errorCount = errorMatch[1].to!int;
            }
            
            auto warningMatch = matchFirst(trimmed, regex(`(\d+) other`));
            if (warningMatch)
            {
                result.warningCount = warningMatch[1].to!int;
            }
        }
    }
}

