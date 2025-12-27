module languages.dotnet.fsharp.tooling.analyzers.compiler;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import languages.dotnet.fsharp.tooling.analyzers.base;
import languages.dotnet.fsharp.config;
import infrastructure.utils.logging;

/// Compiler-based analyzer (uses fsc warnings)
class CompilerAnalyzer : FSharpAnalyzer_
{
    AnalysisResult analyze(string[] files, FSharpAnalysisConfig config)
    {
        AnalysisResult result;
        
        // Compile with warnings to get analysis
        string[] cmd = ["fsc"];
        
        // Set warning level
        cmd ~= ["--warn:" ~ config.warningLevel.to!string];
        
        // Warnings as errors
        if (config.warningsAsErrors)
            cmd ~= ["--warnaserror+"];
        
        foreach (warn; config.warningsAsErrorsList)
            cmd ~= ["--warnaserror:" ~ warn.to!string];
        
        // Disable specific warnings
        foreach (warn; config.disableWarnings)
            cmd ~= ["--nowarn:" ~ warn.to!string];
        
        // Output to temp file
        import std.stdio : writeln;
        auto tempOut = buildPath(tempDir(), "fsharp_analysis.dll");
        cmd ~= ["--out:" ~ tempOut, "--target:library"];
        
        // Add source files
        foreach (file; files)
        {
            if (file.endsWith(".fs") || file.endsWith(".fsi"))
                cmd ~= [file];
        }
        
        auto res = execute(cmd);
        
        // Clean up temp file
        if (exists(tempOut))
        {
            try { remove(tempOut); } catch (Exception e) {}
        }
        
        // Parse compiler output
        result.analyzedFiles = files;
        result.issues = parseCompilerOutput(res.output);
        
        // Determine success
        int errorCount = cast(int)result.issues.count!(i => i.severity == AnalysisSeverity.Error);
        int warningCount = cast(int)result.issues.count!(i => i.severity == AnalysisSeverity.Warning);
        
        if (config.failOnErrors && errorCount > 0)
        {
            result.error = format("Compiler found %d error(s)", errorCount);
            result.success = false;
        }
        else if (config.failOnWarnings && warningCount > 0)
        {
            result.error = format("Compiler found %d warning(s)", warningCount);
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
        return "Compiler";
    }
    
    bool isAvailable()
    {
        auto res = execute(["fsc", "--help"]);
        return res.status == 0 || res.status == 1; // fsc returns 1 for --help
    }
    
    private AnalysisIssue[] parseCompilerOutput(string output)
    {
        AnalysisIssue[] issues;
        
        auto pattern = regex(r"^(.+)\((\d+),(\d+)\):\s+(warning|error)\s+(FS\d+):\s+(.+)$", "m");
        
        foreach (match; matchAll(output, pattern))
        {
            AnalysisIssue issue;
            issue.file = match[1];
            issue.line = match[2].to!int;
            issue.column = match[3].to!int;
            issue.ruleId = match[5];
            issue.message = match[6];
            
            if (match[4].toLower == "error")
                issue.severity = AnalysisSeverity.Error;
            else
                issue.severity = AnalysisSeverity.Warning;
            
            issues ~= issue;
        }
        
        return issues;
    }
}

