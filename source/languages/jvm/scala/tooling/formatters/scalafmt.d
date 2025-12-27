module languages.jvm.scala.tooling.formatters.scalafmt;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.scala.tooling.formatters.base;
import languages.jvm.scala.core.config;
import infrastructure.utils.logging;

/// Scalafmt formatter implementation
class ScalafmtFormatter : Formatter
{
    override FormatResult format(const string[] sources, FormatterConfig config, string workingDir, bool checkOnly = false)
    {
        FormatResult result;
        
        if (sources.empty)
        {
            result.success = true;
            return result;
        }
        
        structuredLog.debug_("formatting_scala_sources_with_scalafmt").emit();
        
        // Build scalafmt command
        string[] cmd = ["scalafmt"];
        
        // Check-only mode
        if (checkOnly)
            cmd ~= "--test";
        
        // Config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--config", config.configFile];
        else
        {
            // Look for .scalafmt.conf in working directory
            string defaultConfig = buildPath(workingDir, ".scalafmt.conf");
            if (exists(defaultConfig))
                cmd ~= ["--config", defaultConfig];
        }
        
        // Add sources
        cmd ~= sources;
        
        structuredLog.debug_("scalafmt_command_").field("detail", "Scalafmt command: " ~ cmd.join(" ")).emit();
        
        // Execute scalafmt
        auto res = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        if (res.status != 0)
        {
            // Exit code 1 means formatting issues in check mode
            if (checkOnly && res.status == 1)
            {
                result.success = false;
                result.error = "Code style violations found";
                result.warnings ~= res.output;
            }
            else
            {
                result.error = "Scalafmt failed: " ~ res.output;
            }
            return result;
        }
        
        result.success = true;
        result.filesFormatted = cast(int)sources.length;
        result.filesChecked = cast(int)sources.length;
        
        if (!res.output.empty)
            result.warnings ~= res.output;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["scalafmt", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "Scalafmt";
    }
}

