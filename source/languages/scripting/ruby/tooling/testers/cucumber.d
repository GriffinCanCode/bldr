module languages.scripting.ruby.tooling.testers.cucumber;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import languages.scripting.ruby.core.config;

/// Cucumber test result
struct CucumberResult
{
    bool success;
    string error;
    size_t scenarios;
    size_t scenariosPassed;
    size_t scenariosFailed;
    size_t steps;
    size_t stepsPassed;
    size_t stepsFailed;
    size_t stepsSkipped;
    size_t stepsPending;
    string output;
    
    bool hasFailures() const { return scenariosFailed > 0 || stepsFailed > 0; }
}

/// Cucumber test runner
class CucumberRunner
{
    /// Check if Cucumber is available
    static bool isAvailable() { return isCommandAvailable("cucumber") || isCommandAvailable("bundle"); }
    
    /// Detect if project uses Cucumber
    static bool detectCucumber(string projectDir)
    {
        // Check for Gemfile with cucumber
        auto gemfilePath = buildPath(projectDir, "Gemfile");
        if (exists(gemfilePath)) {
            try {
                if (readText(gemfilePath).canFind("cucumber")) return true;
            } catch (Exception) {}
        }
        
        // Check for features directory or cucumber config
        return exists(buildPath(projectDir, "features")) ||
               exists(buildPath(projectDir, "cucumber.yml")) ||
               exists(buildPath(projectDir, "config", "cucumber.yml"));
    }
    
    /// Run Cucumber tests
    static CucumberResult runTests(in string[] featureFiles, in RubyTestConfig config, string rubyCmd, string workingDir)
    {
        CucumberResult result;
        
        structuredLog.info("running_cucumber_tests").emit();
        
        // Build command - use bundler if Gemfile exists and available
        immutable useBundler = exists(buildPath(workingDir, "Gemfile"));
        string[] cmd;
        
        if (useBundler && isCommandAvailable("bundle")) cmd = ["bundle", "exec", "cucumber"];
        else if (isCommandAvailable("cucumber")) cmd = ["cucumber"];
        else {
            result.error = "Cucumber not found (install: gem install cucumber)";
            return result;
        }
        
        // Add feature files or default to features directory
        if (!featureFiles.empty) cmd ~= featureFiles;
        else {
            auto featuresDir = buildPath(workingDir, "features");
            if (exists(featuresDir)) cmd ~= featuresDir;
        }
        
        // Add format for parseable output
        cmd ~= ["--format", "progress", "--format", "json", "--out", "cucumber-report.json"];
        
        // Add conditional arguments
        if (!config.cucumberTags.empty) cmd ~= ["--tags", config.cucumberTags];
        if (!config.cucumberProfile.empty) cmd ~= ["--profile", config.cucumberProfile];
        if (config.cucumberStrict) cmd ~= "--strict";
        if (config.cucumberDryRun) cmd ~= "--dry-run";
        cmd ~= config.cucumberArgs;
        
        // Execute Cucumber
        structuredLog.debug_("executing_").field("detail", "Executing: " ~ cmd.join(" ")).emit();
        
        auto execResult = execute(cmd, null, Config.none, size_t.max, workingDir);
        result.output = execResult.output;
        result.success = (execResult.status == 0);
        
        // Parse output
        parseCucumberOutput(execResult.output, result);
        
        // Try to parse JSON report for detailed results
        auto jsonReportPath = buildPath(workingDir, "cucumber-report.json");
        if (exists(jsonReportPath)) {
            try { parseCucumberJsonReport(jsonReportPath, result); }
            catch (Exception e) { structuredLog.debug_("failed_to_parse_cucumber_json_report_").field("detail", "Failed to parse Cucumber JSON report: " ~ e.msg).emit(); }
        }
        
        if (!result.success && result.error.empty)
            result.error = result.scenariosFailed > 0 ? 
                format!"%d scenario(s) failed"(result.scenariosFailed) : "Cucumber tests failed";
        
        // Log summary
        import std.format : format;
        structuredLog.info("log_event").field("message", format!"Cucumber results: %d/%d scenarios passed, %d/%d steps passed"(
            result.scenariosPassed, result.scenarios, result.stepsPassed, result.steps)).emit();
        
        if (result.stepsFailed > 0) structuredLog.warning("log_event").field("message", format!"%d step(s) failed"(result.stepsFailed)).emit();
        if (result.stepsPending > 0) structuredLog.info("log_event").field("message", format!"%d step(s) pending"(result.stepsPending)).emit();
        if (result.stepsSkipped > 0) structuredLog.info("log_event").field("message", format!"%d step(s) skipped"(result.stepsSkipped)).emit();
        
        return result;
    }
    
    /// Parse Cucumber console output - format: "X scenarios (Y failed, Z passed)" / "X steps (Y failed, Z skipped, W pending, V passed)"
    private static void parseCucumberOutput(string output, ref CucumberResult result)
    {
        try {
            auto scenariosMatch = output.matchFirst(regex(r"(\d+)\s+scenarios?\s*\(([^)]+)\)"));
            if (!scenariosMatch.empty) {
                result.scenarios = scenariosMatch[1].to!size_t;
                auto detail = scenariosMatch[2];
                auto failedM = detail.matchFirst(regex(r"(\d+)\s+failed"));
                auto passedM = detail.matchFirst(regex(r"(\d+)\s+passed"));
                if (!failedM.empty) result.scenariosFailed = failedM[1].to!size_t;
                if (!passedM.empty) result.scenariosPassed = passedM[1].to!size_t;
            }
            
            auto stepsMatch = output.matchFirst(regex(r"(\d+)\s+steps?\s*\(([^)]+)\)"));
            if (!stepsMatch.empty) {
                result.steps = stepsMatch[1].to!size_t;
                auto detail = stepsMatch[2];
                auto failedM = detail.matchFirst(regex(r"(\d+)\s+failed"));
                auto passedM = detail.matchFirst(regex(r"(\d+)\s+passed"));
                auto skippedM = detail.matchFirst(regex(r"(\d+)\s+skipped"));
                auto pendingM = detail.matchFirst(regex(r"(\d+)\s+pending"));
                if (!failedM.empty) result.stepsFailed = failedM[1].to!size_t;
                if (!passedM.empty) result.stepsPassed = passedM[1].to!size_t;
                if (!skippedM.empty) result.stepsSkipped = skippedM[1].to!size_t;
                if (!pendingM.empty) result.stepsPending = pendingM[1].to!size_t;
            }
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_cucumber_output_").field("detail", "Failed to parse Cucumber output: " ~ e.msg).emit();
        }
    }
    
    /// Parse Cucumber JSON report for detailed results
    private static void parseCucumberJsonReport(string reportPath, ref CucumberResult result)
    {
        import std.json;
        
        auto jsonContent = readText(reportPath);
        auto json = parseJSON(jsonContent);
        
        if (json.type != JSONType.array)
            return;
        
        size_t totalScenarios = 0;
        size_t passedScenarios = 0;
        size_t failedScenarios = 0;
        size_t totalSteps = 0;
        size_t passedSteps = 0;
        size_t failedSteps = 0;
        size_t skippedSteps = 0;
        size_t pendingSteps = 0;
        
        // Iterate through features
        foreach (feature; json.array)
        {
            if ("elements" !in feature)
                continue;
            
            // Iterate through scenarios
            foreach (scenario; feature["elements"].array)
            {
                totalScenarios++;
                bool scenarioFailed = false;
                
                if ("steps" !in scenario)
                    continue;
                
                // Iterate through steps
                foreach (step; scenario["steps"].array)
                {
                    totalSteps++;
                    
                    if ("result" !in step)
                        continue;
                    
                    immutable status = step["result"]["status"].str;
                    
                    if (status == "passed") passedSteps++;
                    else if (status == "failed") { failedSteps++; scenarioFailed = true; }
                    else if (status == "skipped") skippedSteps++;
                    else if (status == "pending" || status == "undefined") pendingSteps++;
                }
                
                scenarioFailed ? failedScenarios++ : passedScenarios++;
            }
        }
        
        // Update result with parsed data
        result.scenarios = totalScenarios;
        result.scenariosPassed = passedScenarios;
        result.scenariosFailed = failedScenarios;
        result.steps = totalSteps;
        result.stepsPassed = passedSteps;
        result.stepsFailed = failedSteps;
        result.stepsSkipped = skippedSteps;
        result.stepsPending = pendingSteps;
    }
    
    /// Check if command is available
    private static bool isCommandAvailable(string cmd)
    {
        try {
            version(Windows) return execute(["where", cmd]).status == 0;
            else return execute(["which", cmd]).status == 0;
        } catch (Exception) { return false; }
    }
}

