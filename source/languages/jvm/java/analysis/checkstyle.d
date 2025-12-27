module languages.jvm.java.analysis.checkstyle;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.jvm.java.analysis.base;
import languages.jvm.java.core.config;
import infrastructure.utils.logging;

/// Checkstyle analyzer
class CheckstyleAnalyzer : Analyzer
{
    override AnalysisResult analyze(const string[] sources, AnalysisConfig config, string workingDir)
    {
        AnalysisResult result;
        
        structuredLog.info("running_checkstyle_analysis").emit();
        
        string[] cmd = ["checkstyle"];
        
        // Add config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["-c", config.configFile];
        else
            cmd ~= ["-c", "/google_checks.xml"]; // Default Google checks
        
        // Output format
        string outputFile = buildPath(workingDir, "checkstyle-result.xml");
        cmd ~= ["-f", "xml", "-o", outputFile];
        
        // Add source files
        cmd ~= sources;
        
        auto analysisRes = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        // Checkstyle returns non-zero if violations found
        if (analysisRes.status != 0 && !exists(outputFile))
        {
            result.error = "Checkstyle failed:\n" ~ analysisRes.output;
            return result;
        }
        
        // Parse results
        if (exists(outputFile))
        {
            parseCheckstyleXML(outputFile, result);
            remove(outputFile);
        }
        
        result.success = true;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["checkstyle", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "Checkstyle";
    }
    
    private void parseCheckstyleXML(string xmlFile, ref AnalysisResult result)
    {
        import std.regex;
        
        string content = readText(xmlFile);
        
        auto errorPattern = regex(`<error[^>]*line="(\d+)"[^>]*severity="([^"]*)"[^>]*message="([^"]*)"[^>]*source="([^"]*)"`, "g");
        
        foreach (match; matchAll(content, errorPattern))
        {
            AnalysisIssue issue;
            issue.line = match[1].to!int;
            issue.severity = match[2].toLower;
            issue.message = match[3];
            issue.rule = match[4];
            
            result.issues ~= issue;
            
            if (issue.severity == "error")
                result.errorCount++;
            else
                result.warningCount++;
        }
    }
}

