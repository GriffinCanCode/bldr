module languages.jvm.java.tooling.formatters.google;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.java.tooling.formatters.base;
import languages.jvm.java.core.config;
import infrastructure.utils.logging;

/// Google Java Format formatter
class GoogleJavaFormatter : JavaFormatter
{
    override FormatResult format(const string[] sources, FormatterConfig config, string workingDir, bool checkOnly = false)
    {
        FormatResult result;
        
        structuredLog.info("running_googlejavaformat").emit();
        
        string[] cmd = ["google-java-format"];
        
        // Add style
        if (config.style == "aosp")
            cmd ~= "--aosp";
        // Default is Google style
        
        // Check only or format in place
        if (checkOnly)
            cmd ~= ["--dry-run", "--set-exit-if-changed"];
        else
            cmd ~= "--replace";
        
        // Add sources
        cmd ~= sources;
        
        auto formatRes = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        if (formatRes.status != 0 && checkOnly)
        {
            result.warnings ~= "Files need formatting";
            result.success = true; // It's a warning, not an error
        }
        else if (formatRes.status != 0)
        {
            result.error = "google-java-format failed:\n" ~ formatRes.output;
            return result;
        }
        
        result.success = true;
        result.filesFormatted = cast(int)sources.length;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["google-java-format", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "google-java-format";
    }
}

