module languages.dotnet.fsharp.tooling.analyzers.lint;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.json;
import std.regex;
import std.conv;
import languages.dotnet.fsharp.tooling.analyzers.base;
import languages.dotnet.fsharp.config;
import infrastructure.utils.logging;

/// FSharpLint analyzer implementation
class FSharpLintAnalyzer : FSharpAnalyzer_
{
    AnalysisResult analyze(string[] files, FSharpAnalysisConfig config)
    {
        AnalysisResult result;
        
        if (!isAvailable())
        {
            result.error = "FSharpLint is not installed. Run: dotnet tool install -g dotnet-fsharplint";
            return result;
        }
        
        string[] cmd = ["dotnet", "fsharplint", "lint"];
        
        // Configuration file
        if (!config.lintConfig.empty && exists(config.lintConfig))
            cmd ~= ["--lint-config", config.lintConfig];
        
        // Add files or project
        auto fsprojFiles = files.filter!(f => f.endsWith(".fsproj")).array;
        if (!fsprojFiles.empty)
        {
            // Lint entire project
            cmd ~= [fsprojFiles[0]];
        }
        else
        {
            // Lint individual files
            foreach (file; files)
            {
                if (file.endsWith(".fs") || file.endsWith(".fsx"))
                    cmd ~= [file];
            }
        }
        
        auto res = execute(cmd);
        
        // Parse output for issues
        result.analyzedFiles = files;
        result.issues = parseOutput(res.output, config);
        
        // Check if analysis should fail
        int errorCount = cast(int)result.issues.count!(i => i.severity == AnalysisSeverity.Error);
        int warningCount = cast(int)result.issues.count!(i => i.severity == AnalysisSeverity.Warning);
        
        if (config.failOnErrors && errorCount > 0)
        {
            result.error = format("Analysis found %d error(s)", errorCount);
            result.success = false;
        }
        else if (config.failOnWarnings && warningCount > 0)
        {
            result.error = format("Analysis found %d warning(s)", warningCount);
            result.success = false;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    string getName()
    {
        return "FSharpLint";
    }
    
    bool isAvailable()
    {
        auto res = execute(["dotnet", "fsharplint", "--version"]);
        return res.status == 0;
    }
    
    private AnalysisIssue[] parseOutput(string output, FSharpAnalysisConfig config)
    {
        AnalysisIssue[] issues;
        
        foreach (line; output.splitLines)
        {
            // Parse FSharpLint output format
            // Typical format: File.fs(line,col): warning/error FS1234: message
            
            auto match = line.matchFirst(r"^(.+)\((\d+),(\d+)\):\s+(warning|error|info)\s+(\w+):\s+(.+)$");
            if (!match.empty)
            {
                AnalysisIssue issue;
                issue.file = match[1];
                issue.line = match[2].to!int;
                issue.column = match[3].to!int;
                issue.ruleId = match[5];
                issue.message = match[6];
                
                string sevStr = match[4].toLower;
                if (sevStr == "error")
                    issue.severity = AnalysisSeverity.Error;
                else if (sevStr == "warning")
                    issue.severity = AnalysisSeverity.Warning;
                else
                    issue.severity = AnalysisSeverity.Info;
                
                issues ~= issue;
            }
        }
        
        return issues;
    }
}

