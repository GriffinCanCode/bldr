module languages.dotnet.csharp.tooling.analyzers.roslyn;

import std.stdio;
import std.process;
import std.file;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import languages.dotnet.csharp.tooling.analyzers.base;
import languages.dotnet.csharp.tooling.detection;
import languages.dotnet.csharp.core.config;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// Roslyn analyzer (built-in to .NET SDK)
class RoslynAnalyzer : CSharpAnalyzer_
{
    override AnalysisResult analyze(
        string[] sources,
        AnalysisConfig config,
        string projectRoot
    )
    {
        AnalysisResult result;
        
        structuredLog.info("running_roslyn_static_analysis").emit();
        
        string[] cmd = ["dotnet", "build"];
        
        // Enable warnings
        cmd ~= ["/p:TreatWarningsAsErrors=" ~ (config.treatWarningsAsErrors ? "true" : "false")];
        cmd ~= ["/p:WarningLevel=" ~ config.warningLevel.to!string];
        
        // Nullable reference types
        if (config.nullable)
        {
            cmd ~= ["/p:Nullable=enable"];
        }
        
        // Suppress specific warnings
        if (config.noWarn.length > 0)
        {
            cmd ~= ["/p:NoWarn=" ~ config.noWarn.join(";")];
        }
        
        // Warnings as errors
        if (config.warningsAsErrors.length > 0)
        {
            cmd ~= ["/p:WarningsAsErrors=" ~ config.warningsAsErrors.join(";")];
        }
        
        // EditorConfig
        if (!config.editorConfigFile.empty && exists(config.editorConfigFile))
        {
            cmd ~= ["/p:EditorConfigEnabled=true"];
        }
        
        // Verbosity to capture warnings
        cmd ~= ["--verbosity", "normal"];
        
        // Execute build - use safe array form
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        // Parse output for errors and warnings
        parseOutput(res.output, result);
        
        if (result.hasErrors())
        {
            structuredLog.warning("analysis_found_").field("detail", "Analysis found " ~ result.errors.length.to!string ~ " error(s)").emit();
        }
        
        if (result.hasWarnings())
        {
            structuredLog.info("analysis_found_").field("detail", "Analysis found " ~ result.warnings.length.to!string ~ " warning(s)").emit();
        }
        
        result.success = true;
        
        return result;
    }
    
    override bool isAvailable()
    {
        return AnalyzerDetection.isRoslynAvailable();
    }
    
    override string name()
    {
        return "Roslyn Analyzer";
    }
    
    private void parseOutput(string output, ref AnalysisResult result)
    {
        auto lines = output.split("\n");
        
        // Regex for compiler messages: file.cs(line,col): error/warning CODE: message
        auto messagePattern = regex(`([^(]+)\((\d+),(\d+)\):\s+(error|warning)\s+([A-Z0-9]+):\s+(.+)`);
        
        foreach (line; lines)
        {
            auto match = matchFirst(line.strip(), messagePattern);
            if (!match.empty)
            {
                auto level = match[4];
                auto code = match[5];
                auto message = match[6];
                auto fullMessage = code ~ ": " ~ message;
                
                if (level == "error")
                {
                    result.errors ~= fullMessage;
                }
                else if (level == "warning")
                {
                    result.warnings ~= fullMessage;
                }
            }
            else
            {
                // Also check for simple "error:" or "warning:" lines
                if (line.canFind("error:") || line.canFind("error "))
                {
                    result.errors ~= line.strip();
                }
                else if (line.canFind("warning:") || line.canFind("warning "))
                {
                    result.warnings ~= line.strip();
                }
            }
        }
    }
}

