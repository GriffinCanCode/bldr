module languages.scripting.php.tooling.formatters.phpcs;

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

/// PHP_CodeSniffer formatter
class PHPCSFormatter : Formatter
{
    FormatResult format(
        const string[] sources,
        FormatterConfig config,
        const string projectRoot,
        bool checkOnly = false
    )
    {
        FormatResult result;
        
        string phpcsCmd = PHPTools.getPHPCSCommand();
        if (phpcsCmd.empty)
        {
            result.success = false;
            result.errors ~= "PHPCS not found. Install: composer require --dev squizlabs/php_codesniffer";
            return result;
        }
        
        // PHPCS can check or fix
        string[] cmd;
        if (checkOnly || config.checkOnly || config.dryRun)
        {
            // Use phpcs for checking only
            cmd = [phpcsCmd];
        }
        else
        {
            // Use phpcbf for fixing
            string phpcbfCmd = phpcsCmd.replace("phpcs", "phpcbf");
            if (!exists(phpcbfCmd) && phpcbfCmd == "phpcbf")
            {
                // Try vendor/bin
                phpcbfCmd = buildPath("vendor", "bin", "phpcbf");
            }
            
            if (exists(phpcbfCmd) || phpcbfCmd == "phpcbf")
            {
                cmd = [phpcbfCmd];
            }
            else
            {
                // Fall back to check-only
                cmd = [phpcsCmd];
                structuredLog.warning("phpcbf_not_found_running_in_checkonly_mo").emit();
            }
        }
        
        // Configuration file
        string configFile = config.configFile;
        if (configFile.empty)
            configFile = findConfigFile(projectRoot);
        
        if (!configFile.empty && exists(configFile))
        {
            cmd ~= ["--standard=" ~ configFile];
        }
        else if (!config.psrStandard.empty)
        {
            // Use PSR standard
            cmd ~= ["--standard=" ~ config.psrStandard];
        }
        
        // Report format
        cmd ~= "--report=full";
        
        // Show warnings
        cmd ~= "-w";
        
        // Format paths
        if (!sources.empty)
        {
            cmd ~= sources;
        }
        else
        {
            cmd ~= projectRoot;
        }
        
        structuredLog.info("running_phpcs_").field("detail", "Running PHPCS: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // PHPCS returns:
        // 0 = no violations found
        // 1 = violations found (errors)
        // 2 = fixable violations found (warnings)
        // 3 = processing error
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.info("phpcs_no_coding_standard_violations_foun").emit();
        }
        else if (res.status == 1 || res.status == 2)
        {
            // Parse violations
            parseOutput(res.output, result);
            
            if (config.checkOnly || config.dryRun)
            {
                result.success = true; // Don't fail in check mode
            }
            else
            {
                // Some violations may have been fixed
                result.success = result.errors.empty;
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "PHPCS failed with exit code " ~ res.status.to!string;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isPHPCSAvailable();
    }
    
    string name() const
    {
        return "PHPCS";
    }
    
    string getVersion()
    {
        string cmd = PHPTools.getPHPCSCommand();
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
            "phpcs.xml",
            "phpcs.xml.dist",
            ".phpcs.xml",
            ".phpcs.xml.dist",
            "phpcs.ruleset.xml"
        ];
        
        foreach (configFile; configFiles)
        {
            string fullPath = buildPath(projectRoot, configFile);
            if (exists(fullPath))
                return fullPath;
        }
        
        return "";
    }
    
    /// Parse PHPCS output for violations
    private void parseOutput(string output, ref FormatResult result)
    {
        bool inFileSection = false;
        string currentFile;
        
        foreach (line; output.lineSplitter)
        {
            string trimmed = line.strip;
            
            if (trimmed.empty || trimmed.all!(c => c == '-'))
                continue;
            
            // Detect file section
            if (trimmed.startsWith("FILE:"))
            {
                inFileSection = true;
                currentFile = trimmed["FILE:".length .. $].strip;
                continue;
            }
            
            // Parse violation lines
            if (inFileSection && trimmed.canFind("|"))
            {
                // Format: " LINE | COLUMN | TYPE | MESSAGE "
                auto parts = trimmed.split("|").map!(p => p.strip).array;
                if (parts.length >= 4)
                {
                    string type = parts[2];
                    string message = parts[3];
                    
                    if (type == "ERROR")
                    {
                        result.errors ~= currentFile ~ ": " ~ message;
                    }
                    else if (type == "WARNING")
                    {
                        result.warnings ~= currentFile ~ ": " ~ message;
                    }
                    
                    if (!result.filesChanged.canFind(currentFile))
                        result.filesChanged ~= currentFile;
                }
            }
            
            // Count files checked
            auto checkedMatch = matchFirst(trimmed, regex(`(\d+) files? checked`));
            if (checkedMatch)
            {
                result.filesChecked = checkedMatch[1].to!int;
            }
        }
    }
}

