module languages.dotnet.csharp.tooling.formatters.dotnetformat;

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

/// dotnet-format formatter
class DotNetFormatter : CSharpFormatter_
{
    override FormatResult format(
        string[] sources,
        FormatterConfig config,
        string projectRoot,
        bool checkOnly = false
    )
    {
        FormatResult result;
        
        structuredLog.info("formatting_with_dotnetformat").emit();
        
        string[] cmd = ["dotnet", "format"];
        
        // Check only mode
        if (checkOnly || config.checkOnly || config.verifyNoChanges)
        {
            cmd ~= ["--verify-no-changes"];
        }
        
        // Include generated code
        if (config.includeGenerated)
        {
            cmd ~= ["--include-generated"];
        }
        
        // Verbosity
        cmd ~= ["--verbosity", "detailed"];
        
        // Execute format - use safe array form
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            if (checkOnly || config.verifyNoChanges)
            {
                result.error = "Format verification failed (files need formatting)";
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
        return FormatterDetection.isDotNetFormatAvailable();
    }
    
    override string name()
    {
        return "dotnet-format";
    }
}

