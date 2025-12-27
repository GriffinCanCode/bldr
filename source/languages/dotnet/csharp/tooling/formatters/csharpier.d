module languages.dotnet.csharp.tooling.formatters.csharpier;

import std.stdio;
import std.process;
import std.file;
import std.algorithm;
import std.array;
import std.string;
import languages.dotnet.csharp.tooling.formatters.base;
import languages.dotnet.csharp.tooling.detection;
import languages.dotnet.csharp.core.config;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// CSharpier formatter
class CSharpierFormatter : CSharpFormatter_
{
    override FormatResult format(
        string[] sources,
        FormatterConfig config,
        string projectRoot,
        bool checkOnly = false
    )
    {
        FormatResult result;
        
        structuredLog.info("formatting_with_csharpier").emit();
        
        string[] cmd = ["dotnet", "csharpier"];
        
        // Check only mode
        if (checkOnly || config.checkOnly)
        {
            cmd ~= ["--check"];
        }
        
        // Add source files/directories
        if (sources.length > 0)
        {
            cmd ~= sources;
        }
        else
        {
            cmd ~= ["."];
        }
        
        // Execute format - use safe array form
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            if (checkOnly)
            {
                result.error = "Format check failed (files need formatting)";
            }
            else
            {
                result.error = "Format failed: " ~ res.output;
            }
            return result;
        }
        
        result.success = true;
        result.formattedFiles = sources.dup;
        
        structuredLog.info("formatting_completed").emit();
        
        return result;
    }
    
    override bool isAvailable()
    {
        return FormatterDetection.isCSharpierAvailable();
    }
    
    override string name()
    {
        return "CSharpier";
    }
}

