module languages.jvm.scala.tooling.checkers.scalafix;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.scala.tooling.checkers.base;
import languages.jvm.scala.core.config;
import infrastructure.utils.logging;

/// Scalafix checker/linter implementation
class ScalafixChecker : Checker
{
    override CheckResult check(const string[] sources, LinterConfig config, string workingDir)
    {
        CheckResult result;
        
        if (sources.empty)
        {
            result.success = true;
            return result;
        }
        
        structuredLog.debug_("checking_scala_sources_with_scalafix").emit();
        
        // Build scalafix command
        string[] cmd = ["scalafix"];
        
        // Check mode (no rewrites)
        cmd ~= "--check";
        
        // Config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--config", config.configFile];
        else
        {
            string defaultConfig = buildPath(workingDir, ".scalafix.conf");
            if (exists(defaultConfig))
                cmd ~= ["--config", defaultConfig];
        }
        
        // Add rules
        foreach (rule; config.rules)
            cmd ~= ["--rules", rule];
        
        // Add sources
        cmd ~= sources;
        
        structuredLog.debug_("scalafix_command_").field("detail", "Scalafix command: " ~ cmd.join(" ")).emit();
        
        // Execute scalafix
        auto res = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        if (res.status != 0)
        {
            result.success = false;
            result.error = "Scalafix found issues";
            result.violations ~= res.output;
            
            // Count issues (rough estimate)
            result.issuesFound = cast(int)res.output.count('\n');
            
            if (config.failOnWarnings)
                return result;
        }
        
        result.success = true;
        
        if (!res.output.empty)
            result.warnings ~= res.output;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["scalafix", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "Scalafix";
    }
}

