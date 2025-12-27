module languages.dotnet.fsharp.tooling.formatters.fantomas;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.dotnet.fsharp.tooling.formatters.base;
import languages.dotnet.fsharp.config;
import infrastructure.utils.logging;

/// Fantomas formatter implementation
class FantomasFormatter : FSharpFormatter_
{
    FormatResult format(string[] files, FSharpFormatterConfig config)
    {
        FormatResult result;
        
        if (!isAvailable())
        {
            result.error = "Fantomas is not installed. Run: dotnet tool install -g fantomas";
            return result;
        }
        
        foreach (file; files)
        {
            if (!exists(file))
                continue;
            
            string[] cmd = ["dotnet", "fantomas"];
            
            // Configuration file
            if (!config.configFile.empty && exists(config.configFile))
                cmd ~= ["--config", config.configFile];
            
            // Check only mode
            if (config.checkOnly)
                cmd ~= ["--check"];
            
            // Add file
            cmd ~= [file];
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.issues ~= "Failed to format " ~ file ~ ": " ~ res.output;
                continue;
            }
            
            result.formattedFiles ~= file;
        }
        
        result.success = result.issues.length == 0;
        
        return result;
    }
    
    FormatResult check(string[] files, FSharpFormatterConfig config)
    {
        auto checkConfig = config;
        checkConfig.checkOnly = true;
        return format(files, checkConfig);
    }
    
    string getName()
    {
        return "Fantomas";
    }
    
    bool isAvailable()
    {
        auto res = execute(["dotnet", "fantomas", "--version"]);
        return res.status == 0;
    }
}

