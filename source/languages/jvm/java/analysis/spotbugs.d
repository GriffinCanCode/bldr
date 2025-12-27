module languages.jvm.java.analysis.spotbugs;

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

/// SpotBugs static analyzer
class SpotBugsAnalyzer : Analyzer
{
    override AnalysisResult analyze(const string[] sources, AnalysisConfig config, string workingDir)
    {
        AnalysisResult result;
        
        structuredLog.info("running_spotbugs_analysis").emit();
        
        string[] cmd = ["spotbugs"];
        
        // Add effort level
        cmd ~= ["-effort:" ~ config.effort];
        
        // Add threshold
        if (config.threshold == "low")
            cmd ~= "-low";
        else if (config.threshold == "medium")
            cmd ~= "-medium";
        else if (config.threshold == "high")
            cmd ~= "-high";
        
        // Add exclude filter if specified
        if (!config.excludePatterns.empty)
        {
            string excludeFile = createExcludeFilter(config.excludePatterns, workingDir);
            if (!excludeFile.empty)
                cmd ~= ["-exclude", excludeFile];
        }
        
        // Output as XML for parsing
        string outputFile = buildPath(workingDir, "spotbugs-result.xml");
        cmd ~= ["-xml:withMessages", "-output", outputFile];
        
        // Add class files (need to find compiled classes)
        // For now, assume target/classes or bin
        string classDir = findClassDirectory(workingDir);
        if (classDir.empty)
        {
            result.error = "Could not find compiled class directory";
            return result;
        }
        
        cmd ~= classDir;
        
        auto analysisRes = execute(cmd, null, Config.none, size_t.max, workingDir);
        
        // SpotBugs returns non-zero if bugs found
        if (analysisRes.status != 0 && !exists(outputFile))
        {
            result.error = "SpotBugs failed:\n" ~ analysisRes.output;
            return result;
        }
        
        // Parse results
        if (exists(outputFile))
        {
            parseSpotBugsXML(outputFile, result);
            remove(outputFile);
        }
        
        result.success = true;
        
        return result;
    }
    
    override bool isAvailable()
    {
        try
        {
            auto result = execute(["spotbugs", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "SpotBugs";
    }
    
    private string createExcludeFilter(string[] patterns, string workingDir)
    {
        string filterFile = buildPath(workingDir, "spotbugs-exclude.xml");
        
        auto f = File(filterFile, "w");
        f.writeln("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        f.writeln("<FindBugsFilter>");
        
        foreach (pattern; patterns)
        {
            f.writeln("  <Match>");
            f.writeln("    <Class name=\"~" ~ pattern ~ "\" />");
            f.writeln("  </Match>");
        }
        
        f.writeln("</FindBugsFilter>");
        f.close();
        
        return filterFile;
    }
    
    private string findClassDirectory(string workingDir)
    {
        string[] candidates = [
            buildPath(workingDir, "target", "classes"),
            buildPath(workingDir, "build", "classes", "java", "main"),
            buildPath(workingDir, "bin"),
            buildPath(workingDir, "out", "production")
        ];
        
        foreach (dir; candidates)
        {
            if (exists(dir) && isDir(dir))
                return dir;
        }
        
        return "";
    }
    
    private void parseSpotBugsXML(string xmlFile, ref AnalysisResult result)
    {
        // Simple XML parsing for bug instances
        import std.regex;
        
        string content = readText(xmlFile);
        
        auto bugPattern = regex(`<BugInstance[^>]*priority="(\d+)"[^>]*>\s*<ShortMessage>(.*?)</ShortMessage>.*?<SourceLine[^>]*sourcepath="([^"]*)"[^>]*start="(\d+)"`, "sg");
        
        foreach (match; matchAll(content, bugPattern))
        {
            AnalysisIssue issue;
            issue.file = match[3];
            issue.line = match[4].to!int;
            issue.message = match[2];
            
            int priority = match[1].to!int;
            issue.severity = priority <= 2 ? "error" : "warning";
            
            result.issues ~= issue;
            
            if (issue.severity == "error")
                result.errorCount++;
            else
                result.warningCount++;
        }
    }
}

