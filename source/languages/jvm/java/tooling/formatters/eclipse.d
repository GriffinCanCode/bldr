module languages.jvm.java.tooling.formatters.eclipse;

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

/// Eclipse formatter
class EclipseFormatter : JavaFormatter
{
    override FormatResult format(const string[] sources, FormatterConfig config, string workingDir, bool checkOnly = false)
    {
        FormatResult result;
        
        structuredLog.info("running_eclipse_formatter").emit();
        
        // Eclipse formatter requires the JAR
        string eclipseJar = findEclipseFormatterJar(workingDir);
        if (eclipseJar.empty)
        {
            result.error = "Eclipse formatter JAR not found";
            return result;
        }
        
        string[] cmd = ["java", "-jar", eclipseJar];
        
        // Add config file if specified
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["-config", config.configFile];
        
        // Check only or format
        if (!checkOnly)
            cmd ~= sources;
        
        auto formatRes = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        if (formatRes.status != 0)
        {
            result.error = "Eclipse formatter failed:\n" ~ formatRes.output;
            return result;
        }
        
        result.success = true;
        result.filesFormatted = cast(int)sources.length;
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Check if Eclipse formatter JAR is available
        return !findEclipseFormatterJar(".").empty;
    }
    
    override string name() const
    {
        return "Eclipse";
    }
    
    private string findEclipseFormatterJar(string workingDir)
    {
        // Look for Eclipse formatter JAR in common locations
        string[] locations = [
            "eclipse-formatter.jar",
            "tools/eclipse-formatter.jar",
            buildPath(workingDir, "eclipse-formatter.jar")
        ];
        
        foreach (loc; locations)
        {
            if (exists(loc))
                return loc;
        }
        
        return "";
    }
}

