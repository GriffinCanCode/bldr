module languages.scripting.php.tooling.formatters.phpcsfixer;

import languages.scripting.php.tooling.formatters.base;
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

/// PHP-CS-Fixer code formatter
class PHPCSFixerFormatter : Formatter
{
    FormatResult format(
        const string[] sources,
        FormatterConfig config,
        const string projectRoot,
        bool checkOnly = false
    )
    {
        FormatResult result;
        
        string fixerCmd = PHPTools.getPHPCSFixerCommand();
        if (fixerCmd.empty)
        {
            result.success = false;
            result.errors ~= "PHP-CS-Fixer not found. Install: composer require --dev friendsofphp/php-cs-fixer";
            return result;
        }
        
        string[] cmd = [fixerCmd, "fix"];
        
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
            // Use PSR standard if no config file
            if (!config.psrStandard.empty)
            {
                cmd ~= ["--rules", "@" ~ config.psrStandard];
            }
        }
        
        // Dry run (check only)
        if (checkOnly || config.checkOnly || config.dryRun)
        {
            cmd ~= "--dry-run";
        }
        
        // Diff output
        cmd ~= "--diff";
        
        // Verbose output for debugging
        if (config.checkOnly)
        {
            cmd ~= "-v";
        }
        
        // Allow risky rules
        cmd ~= "--allow-risky=yes";
        
        // Format paths
        if (!sources.empty)
        {
            // PHP-CS-Fixer can handle files and directories
            cmd ~= sources;
        }
        else
        {
            // Default to project root
            cmd ~= projectRoot;
        }
        
        structuredLog.info("running_phpcsfixer_").field("detail", "Running PHP-CS-Fixer: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // PHP-CS-Fixer returns:
        // 0 = no changes needed or changes applied
        // 1 = general error
        // 4 = some files have invalid syntax (ignored)
        // 8 = some files need fixing (in dry-run mode)
        // 16 = configuration error
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.info("phpcsfixer_all_files_are_properly_format").emit();
        }
        else if (res.status == 8)
        {
            // Files need fixing (dry-run mode)
            parseOutput(res.output, result);
            result.success = true; // Don't fail the build
            
            if (!result.filesChanged.empty)
            {
                structuredLog.warning("phpcsfixer_").field("detail", "PHP-CS-Fixer: " ~ result.filesChanged.length.to!string ~ " file(s) need formatting").emit();
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "PHP-CS-Fixer failed with exit code " ~ res.status.to!string;
            result.errors ~= res.output;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isPHPCSFixerAvailable();
    }
    
    string name() const
    {
        return "PHP-CS-Fixer";
    }
    
    string getVersion()
    {
        string cmd = PHPTools.getPHPCSFixerCommand();
        if (cmd.empty)
            return "not installed";
        
        auto res = execute([cmd, "--version"]);
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
            ".php-cs-fixer.php",
            ".php-cs-fixer.dist.php",
            ".php_cs",
            ".php_cs.dist"
        ];
        
        foreach (configFile; configFiles)
        {
            string fullPath = buildPath(projectRoot, configFile);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Parse PHP-CS-Fixer output for changed files
    private void parseOutput(string output, ref FormatResult result)
    {
        foreach (line; output.lineSplitter)
        {
            string trimmed = line.strip;
            
            if (trimmed.empty)
                continue;
            
            // Look for fixed/changed files
            // Format: "   1) path/to/file.php"
            if (trimmed.canFind(")") && trimmed.canFind(".php"))
            {
                // Extract file path
                auto parts = trimmed.split(")");
                if (parts.length > 1)
                {
                    string filePath = parts[1].strip;
                    if (!filePath.empty)
                    {
                        result.filesChanged ~= filePath;
                        result.warnings ~= "Needs formatting: " ~ filePath;
                    }
                }
            }
            
            // Count files checked
            auto checkedMatch = matchFirst(trimmed, regex(`Checked (\d+) files`));
            if (checkedMatch)
            {
                result.filesChecked = checkedMatch[1].to!int;
            }
        }
    }
}

