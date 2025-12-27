module frontend.testframework.junit;

import std.stdio : File;
import std.format : format;
import std.array : array;
import std.algorithm : map, filter;
import std.string : strip, replace;
import std.range : empty;
import std.datetime : Duration;
import std.path : buildPath, dirName;
import std.file : exists, mkdirRecurse;
import frontend.testframework.results;
import infrastructure.utils.logging;
import infrastructure.errors;

/// JUnit XML test report generator
/// Generates XML format compatible with CI/CD systems (Jenkins, GitHub Actions, etc.)
class JUnitExporter
{
    private string outputPath;
    
    this(string outputPath) @system
    {
        this.outputPath = outputPath;
    }
    
    /// Export test results to JUnit XML format
    void export_(const TestResult[] results) @system
    {
        try
        {
            // Ensure output directory exists
            immutable dir = dirName(outputPath);
            if (!exists(dir))
            {
                mkdirRecurse(dir);
            }
            
            auto file = File(outputPath, "w");
            scope(exit) file.close();
            
            writeXmlHeader(file);
            writeTestSuites(file, results);
            
            structuredLog.info("exported_junit_xml_report_to_").field("detail", "Exported JUnit XML report to: " ~ outputPath).emit();
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_export_junit_xml_").field("detail", "Failed to export JUnit XML: " ~ e.msg).emit();
            throw e;
        }
    }
    
    private void writeXmlHeader(ref File file) @system
    {
        file.writeln("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    }
    
    private void writeTestSuites(ref File file, const TestResult[] results) @system
    {
        immutable stats = TestStats.compute(results);
        
        file.writeln("<testsuites>");
        file.writeln(format("  <testsuite name=\"Builder Tests\" tests=\"%d\" failures=\"%d\" errors=\"0\" time=\"%.3f\">",
            stats.totalTargets,
            stats.failedTargets,
            stats.totalDuration.total!"msecs" / 1000.0
        ));
        
        foreach (result; results)
        {
            writeTestCase(file, result);
        }
        
        file.writeln("  </testsuite>");
        file.writeln("</testsuites>");
    }
    
    private void writeTestCase(ref File file, const TestResult result) @system
    {
        immutable name = xmlEscape(result.targetId);
        immutable time = result.duration.total!"msecs" / 1000.0;
        
        if (result.cases.empty)
        {
            // Single test case for entire target
            if (result.passed)
            {
                file.writeln(format("    <testcase name=\"%s\" time=\"%.3f\"/>", name, time));
            }
            else
            {
                file.writeln(format("    <testcase name=\"%s\" time=\"%.3f\">", name, time));
                file.writeln(format("      <failure message=\"%s\">", xmlEscape(result.errorMessage)));
                if (!result.stderr.empty)
                {
                    file.writeln("<![CDATA[");
                    file.writeln(result.stderr);
                    file.writeln("]]>");
                }
                file.writeln("      </failure>");
                file.writeln("    </testcase>");
            }
        }
        else
        {
            // Multiple test cases
            foreach (tc; result.cases)
            {
                immutable caseName = xmlEscape(name ~ "::" ~ tc.name);
                immutable caseTime = tc.duration.total!"msecs" / 1000.0;
                
                if (tc.passed)
                {
                    file.writeln(format("    <testcase name=\"%s\" time=\"%.3f\"/>", caseName, caseTime));
                }
                else
                {
                    file.writeln(format("    <testcase name=\"%s\" time=\"%.3f\">", caseName, caseTime));
                    file.writeln(format("      <failure message=\"%s\">", xmlEscape(tc.failureMessage)));
                    if (!tc.stderr.empty)
                    {
                        file.writeln("<![CDATA[");
                        file.writeln(tc.stderr);
                        file.writeln("]]>");
                    }
                    file.writeln("      </failure>");
                    file.writeln("    </testcase>");
                }
            }
        }
    }
    
    private string xmlEscape(string text) @system
    {
        return text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&apos;");
    }
}

/// Helper function to export test results
void exportJUnit(const TestResult[] results, string outputPath) @system
{
    auto exporter = new JUnitExporter(outputPath);
    exporter.export_(results);
}

