module languages.jvm.java.analysis.pmd;

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

/// PMD static analyzer
class PMDAnalyzer : Analyzer
{
    override AnalysisResult analyze(const string[] sources, AnalysisConfig config, string workingDir)
    {
        AnalysisResult result;
        
        structuredLog.info("running_pmd_analysis").emit();
        
        string[] cmd = ["pmd"];
        
        // New PMD CLI format (PMD 7+)
        cmd ~= "check";
        
        // Add source directory
        if (sources.length > 0)
        {
            string sourceDir = dirName(sources[0]);
            cmd ~= ["-d", sourceDir];
        }
        else
        {
            cmd ~= ["-d", "src"];
        }
        
        // Add rulesets
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["-R", config.configFile];
        else
            cmd ~= ["-R", "category/java/bestpractices.xml,category/java/errorprone.xml"];
        
        // Output format
        string outputFile = buildPath(workingDir, "pmd-result.xml");
        cmd ~= ["-f", "xml", "-r", outputFile];
        
        // Fail on violations
        if (config.failOnErrors)
            cmd ~= "--fail-on-violation";
        
        auto analysisRes = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        // PMD returns non-zero if violations found
        if (analysisRes.status != 0 && !exists(outputFile))
        {
            result.error = "PMD failed:\n" ~ analysisRes.output;
            return result;
        }
        
        // Parse results
        if (exists(outputFile))
        {
            parsePMDXML(outputFile, result);
            remove(outputFile);
        }
        
        result.success = true;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["pmd", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "PMD";
    }
    
    private void parsePMDXML(string xmlFile, ref AnalysisResult result)
    {
        import std.regex;
        
        string content = readText(xmlFile);
        
        auto violationPattern = regex(`<violation[^>]*beginline="(\d+)"[^>]*priority="(\d+)"[^>]*rule="([^"]*)"[^>]*>(.*?)</violation>`, "sg");
        
        foreach (match; matchAll(content, violationPattern))
        {
            AnalysisIssue issue;
            issue.line = match[1].to!int;
            issue.rule = match[3];
            issue.message = match[4].strip;
            
            int priority = match[2].to!int;
            issue.severity = priority <= 2 ? "error" : "warning";
            
            result.issues ~= issue;
            
            if (issue.severity == "error")
                result.errorCount++;
            else
                result.warningCount++;
        }
    }
}

