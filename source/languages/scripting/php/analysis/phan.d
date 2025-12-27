module languages.scripting.php.analysis.phan;

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

/// Phan static analyzer (advanced inference)
class PhanAnalyzer : Analyzer
{
    AnalysisResult analyze(
        const string[] sources,
        AnalysisConfig config,
        const string projectRoot
    )
    {
        AnalysisResult result;
        
        if (!PHPTools.isPhanAvailable())
        {
            result.success = false;
            result.errors ~= "Phan not found. Install: composer require --dev phan/phan";
            return result;
        }
        
        string phanCmd = buildPath("vendor", "bin", "phan");
        if (!exists(phanCmd))
            phanCmd = "phan";
        
        string[] cmd = [phanCmd];
        
        // Configuration file
        string configFile = config.configFile;
        if (configFile.empty)
            configFile = findConfigFile(projectRoot);
        
        if (!configFile.empty && exists(configFile))
        {
            cmd ~= ["--config-file", configFile];
        }
        
        // Output format
        cmd ~= ["--output-mode", "text"];
        
        // No progress bar
        cmd ~= "--progress-bar";
        cmd ~= "--no-color";
        
        // Memory limit
        if (!config.memoryLimit.empty)
        {
            cmd ~= ["--memory-limit", config.memoryLimit];
        }
        
        // Paths to analyze (Phan requires directories)
        if (!config.paths.empty)
        {
            foreach (path; config.paths)
            {
                if (isDir(path))
                    cmd ~= ["--directory", path];
                else
                    cmd ~= ["--file-list", path];
            }
        }
        else if (!sources.empty)
        {
            // Create temporary file list
            string fileListPath = buildPath(projectRoot, ".phan_files.txt");
            std.file.write(fileListPath, sources.join("\n"));
            cmd ~= ["--file-list", fileListPath];
        }
        
        structuredLog.info("running_phan_").field("detail", "Running Phan: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // Clean up temporary file list
        string fileListPath = buildPath(projectRoot, ".phan_files.txt");
        if (exists(fileListPath))
        {
            try
            {
                remove(fileListPath);
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_cleanup_file_list_").field("detail", "Failed to cleanup file list: " ~ e.msg).emit();
            }
        }
        
        // Phan returns non-zero if issues found
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.info("phan_analysis_passed_with_no_issues").emit();
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
                // Only fail on errors
                result.success = result.errorCount == 0;
            }
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isPhanAvailable();
    }
    
    string name() const
    {
        return "Phan";
    }
    
    string getVersion()
    {
        auto res = execute(["phan", "--version"]);
        if (res.status == 0)
        {
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
            ".phan/config.php",
            "phan.php"
        ];
        
        foreach (configFile; configFiles)
        {
            string fullPath = buildPath(projectRoot, configFile);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Parse Phan output for errors and warnings
    private void parseOutput(string output, ref AnalysisResult result)
    {
        foreach (line; output.lineSplitter)
        {
            string trimmed = line.strip;
            
            if (trimmed.empty)
                continue;
            
            // Phan format: "file.php:123 PhanTypeMismatch Message"
            if (trimmed.canFind(":") && trimmed.canFind("Phan"))
            {
                // Check if it's an error or warning based on issue type
                if (trimmed.canFind("PhanUndeclared") ||
                    trimmed.canFind("PhanType") ||
                    trimmed.canFind("PhanInvalid"))
                {
                    result.errors ~= trimmed;
                    result.errorCount++;
                }
                else
                {
                    result.warnings ~= trimmed;
                    result.warningCount++;
                }
            }
        }
    }
}

