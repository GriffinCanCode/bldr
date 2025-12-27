#!/usr/bin/env dub
/+ dub.sdl:
    name "build-profiler"
    dependency "builder" path="../../"
+/

/**
 * Comprehensive Build Profiler
 * 
 * Profiles real-world builds to identify bottlenecks:
 * - Phase timing (parse, analyze, execute, finalize)
 * - Hot path identification
 * - Memory allocation tracking
 * - Cache hit/miss analysis
 * - Per-target timing breakdown
 * 
 * Output:
 * - Detailed timing report
 * - Flame graph compatible output
 * - Memory profile
 * - Bottleneck recommendations
 */

module tests.bench.profiler;

import std.stdio;
import std.datetime.stopwatch;
import std.datetime;
import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.range;
import std.file;
import std.path;
import std.string;
import std.process;
import core.memory : GC;

/// Timing data for a single operation
struct TimingEntry
{
    string name;
    string category;
    Duration duration;
    size_t memoryDelta;
    string parent;
    
    double msecs() const => duration.total!"msecs" + duration.total!"usecs" % 1000 / 1000.0;
}

/// Profile data for a complete build
struct BuildProfile
{
    string projectPath;
    SysTime startTime;
    SysTime endTime;
    
    Duration totalTime;
    Duration parseTime;
    Duration analysisTime;
    Duration executionTime;
    Duration finalizationTime;
    
    size_t targetCount;
    size_t cachedTargets;
    size_t builtTargets;
    size_t failedTargets;
    
    size_t peakMemoryMB;
    size_t gcCollections;
    
    TimingEntry[] entries;
    string[] hotPaths;
    string[] recommendations;
    
    double cacheHitRate() const => targetCount > 0 ? 
        cachedTargets * 100.0 / targetCount : 0.0;
}

/// Profiler for build operations
class BuildProfiler
{
    private string builderBin;
    private bool verbose;
    private TimingEntry[] entries;
    private StopWatch[string] activeTimers;
    private size_t[string] memorySnapshots;
    
    this(string builderBin = null, bool verbose = false)
    {
        this.verbose = verbose;
        
        if (builderBin is null)
        {
            import std.file : thisExePath;
            auto scriptDir = thisExePath().dirName;
            auto projectRoot = buildPath(scriptDir, "..", "..");
            this.builderBin = buildPath(projectRoot, "bin", "builder");
        }
        else
        {
            this.builderBin = builderBin;
        }
    }
    
    /// Profile a single project build
    BuildProfile profileProject(string projectPath, bool clean = true)
    {
        BuildProfile profile;
        profile.projectPath = projectPath;
        profile.startTime = Clock.currTime();
        
        if (verbose)
            writeln("[PROFILER] Starting profile of: ", projectPath);
        
        // Clean if requested
        if (clean)
        {
            cleanProject(projectPath);
        }
        
        // Collect GC stats before
        GC.collect();
        auto gcStatsBefore = GC.stats();
        
        // Profile the build phases
        auto parseResult = profilePhase(projectPath, "parse");
        profile.parseTime = parseResult.duration;
        
        // Run actual build with timing capture
        auto buildResult = profileBuild(projectPath);
        profile.totalTime = buildResult.totalTime;
        profile.analysisTime = buildResult.analysisTime;
        profile.executionTime = buildResult.executionTime;
        profile.finalizationTime = buildResult.finalizationTime;
        
        profile.targetCount = buildResult.targetCount;
        profile.cachedTargets = buildResult.cachedTargets;
        profile.builtTargets = buildResult.builtTargets;
        profile.failedTargets = buildResult.failedTargets;
        
        // Collect GC stats after
        GC.collect();
        auto gcStatsAfter = GC.stats();
        
        // Note: numCollections not available in all GC implementations
        profile.gcCollections = 0;
        profile.peakMemoryMB = (gcStatsAfter.usedSize) / (1024 * 1024);
        
        profile.endTime = Clock.currTime();
        profile.entries = entries.dup;
        
        // Analyze for hot paths
        profile.hotPaths = identifyHotPaths(profile);
        profile.recommendations = generateRecommendations(profile);
        
        return profile;
    }
    
    /// Profile multiple projects and generate comparative report
    BuildProfile[] profileProjects(string[] projectPaths, bool clean = true)
    {
        BuildProfile[] profiles;
        
        foreach (i, path; projectPaths)
        {
            writeln(format("\n[%d/%d] Profiling: %s", i + 1, projectPaths.length, path));
            writeln("═".repeat(70).join);
            
            if (!exists(path))
            {
                writeln("  \x1b[33m⊘ SKIP\x1b[0m Project not found");
                continue;
            }
            
            auto profile = profileProject(path, clean);
            profiles ~= profile;
            
            printQuickSummary(profile);
        }
        
        return profiles;
    }
    
    private void cleanProject(string projectPath)
    {
        auto cacheDir = buildPath(projectPath, ".builder-cache");
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
        
        auto binDir = buildPath(projectPath, "bin");
        if (exists(binDir))
            rmdirRecurse(binDir);
    }
    
    private struct PhaseResult
    {
        Duration duration;
        bool success;
        string output;
    }
    
    private PhaseResult profilePhase(string projectPath, string phase)
    {
        PhaseResult result;
        
        auto sw = StopWatch(AutoStart.yes);
        auto cmdResult = execute([builderBin, phase], null, Config.none, size_t.max, projectPath);
        sw.stop();
        
        result.duration = sw.peek();
        result.success = cmdResult.status == 0;
        result.output = cmdResult.output;
        
        entries ~= TimingEntry(phase, "phase", result.duration, 0, "root");
        
        return result;
    }
    
    private struct BuildResult
    {
        Duration totalTime;
        Duration analysisTime;
        Duration executionTime;
        Duration finalizationTime;
        size_t targetCount;
        size_t cachedTargets;
        size_t builtTargets;
        size_t failedTargets;
    }
    
    private BuildResult profileBuild(string projectPath)
    {
        BuildResult result;
        
        auto sw = StopWatch(AutoStart.yes);
        auto cmdResult = execute([builderBin, "build", "--verbose"], null, Config.none, size_t.max, projectPath);
        sw.stop();
        
        result.totalTime = sw.peek();
        
        // Parse output for detailed timing
        parseBuilderOutput(cmdResult.output, result);
        
        return result;
    }
    
    private void parseBuilderOutput(string output, ref BuildResult result)
    {
        foreach (line; output.lineSplitter)
        {
            // Parse timing info from Builder output
            if (line.canFind("targets") && line.canFind("built"))
            {
                // Try to extract target counts
                auto parts = line.split();
                foreach (i, part; parts)
                {
                    if (part == "targets" && i > 0)
                    {
                        try { result.targetCount = to!size_t(parts[i-1]); }
                        catch (Exception) {}
                    }
                    if (part == "cached" && i > 0)
                    {
                        try { result.cachedTargets = to!size_t(parts[i-1]); }
                        catch (Exception) {}
                    }
                }
            }
            
            // Parse phase timings
            if (line.canFind("Analysis") && line.canFind("ms"))
                result.analysisTime = extractDuration(line);
            if (line.canFind("Execution") && line.canFind("ms"))
                result.executionTime = extractDuration(line);
        }
        
        result.builtTargets = result.targetCount - result.cachedTargets;
    }
    
    private Duration extractDuration(string line)
    {
        foreach (part; line.split())
        {
            if (part.endsWith("ms"))
            {
                try
                {
                    auto numStr = part[0 .. $-2].replace(",", "");
                    return dur!"msecs"(to!long(numStr));
                }
                catch (Exception) {}
            }
        }
        return Duration.zero;
    }
    
    private string[] identifyHotPaths(in BuildProfile profile)
    {
        string[] hotPaths;
        
        // Sort entries by duration
        auto sorted = profile.entries.dup.sort!((a, b) => a.duration > b.duration);
        
        // Top 5 slowest operations
        foreach (entry; sorted.take(5))
        {
            if (entry.duration.total!"msecs" > 10)  // Only include significant entries
                hotPaths ~= format("%s: %d ms", entry.name, entry.duration.total!"msecs");
        }
        
        return hotPaths;
    }
    
    private string[] generateRecommendations(in BuildProfile profile)
    {
        string[] recs;
        
        // Cache hit rate
        if (profile.cacheHitRate < 50.0 && profile.targetCount > 10)
            recs ~= "Low cache hit rate - check for non-deterministic builds or frequent invalidations";
        
        // Parse time
        if (profile.parseTime.total!"msecs" > 1000)
            recs ~= "High parse time - consider splitting large Builderfiles";
        
        // Execution dominance
        if (profile.totalTime.total!"msecs" > 0)
        {
            auto execRatio = profile.executionTime.total!"msecs" * 100.0 / profile.totalTime.total!"msecs";
            if (execRatio > 90)
                recs ~= "Execution-bound build - focus on parallelism and command optimization";
            else if (execRatio < 50)
                recs ~= "Overhead-bound build - check for unnecessary analysis or I/O";
        }
        
        // Memory usage
        if (profile.peakMemoryMB > 1000)
            recs ~= "High memory usage - consider arena allocation or graph optimization";
        
        // GC pressure
        if (profile.gcCollections > 10)
            recs ~= "High GC pressure - profile memory allocations for hot paths";
        
        return recs;
    }
    
    private void printQuickSummary(in BuildProfile profile)
    {
        writeln("\n  Quick Summary:");
        writeln(format("    Total Time:     %6d ms", profile.totalTime.total!"msecs"));
        writeln(format("    Parse:          %6d ms", profile.parseTime.total!"msecs"));
        writeln(format("    Analysis:       %6d ms", profile.analysisTime.total!"msecs"));
        writeln(format("    Execution:      %6d ms", profile.executionTime.total!"msecs"));
        writeln(format("    Targets:        %6d (%.1f%% cached)", 
                profile.targetCount, profile.cacheHitRate));
    }
}

/// Report generator for profiling data
class ProfileReporter
{
    /// Generate detailed text report
    static void generateTextReport(in BuildProfile profile, File output = stdout)
    {
        output.writeln();
        output.writeln("╔════════════════════════════════════════════════════════════════╗");
        output.writeln("║              BUILD PROFILE REPORT                              ║");
        output.writeln("╚════════════════════════════════════════════════════════════════╝");
        output.writeln();
        
        output.writeln("Project: ", profile.projectPath);
        output.writeln("Start:   ", profile.startTime.toISOExtString());
        output.writeln("End:     ", profile.endTime.toISOExtString());
        output.writeln();
        
        output.writeln("─".repeat(70).join);
        output.writeln("TIMING BREAKDOWN");
        output.writeln("─".repeat(70).join);
        output.writeln();
        
        auto total = profile.totalTime.total!"msecs";
        
        void printPhase(string name, Duration dur, string bar = "")
        {
            auto ms = dur.total!"msecs";
            auto pct = total > 0 ? ms * 100.0 / total : 0.0;
            auto barLen = cast(int)(pct / 2);
            output.writeln(format("  %-15s %6d ms (%5.1f%%) %s", 
                    name, ms, pct, "█".repeat(max(1, barLen)).join));
        }
        
        printPhase("Parse", profile.parseTime);
        printPhase("Analysis", profile.analysisTime);
        printPhase("Execution", profile.executionTime);
        printPhase("Finalization", profile.finalizationTime);
        output.writeln("  " ~ "─".repeat(40).join);
        printPhase("TOTAL", profile.totalTime);
        output.writeln();
        
        output.writeln("─".repeat(70).join);
        output.writeln("TARGET STATISTICS");
        output.writeln("─".repeat(70).join);
        output.writeln();
        output.writeln(format("  Total Targets:    %6d", profile.targetCount));
        output.writeln(format("  Cached:           %6d (%.1f%%)", 
                profile.cachedTargets, profile.cacheHitRate));
        output.writeln(format("  Built:            %6d", profile.builtTargets));
        output.writeln(format("  Failed:           %6d", profile.failedTargets));
        output.writeln();
        
        if (profile.targetCount > 0 && profile.totalTime.total!"msecs" > 0)
        {
            auto throughput = profile.targetCount / (profile.totalTime.total!"msecs" / 1000.0);
            output.writeln(format("  Throughput:       %.1f targets/sec", throughput));
        }
        output.writeln();
        
        output.writeln("─".repeat(70).join);
        output.writeln("RESOURCE USAGE");
        output.writeln("─".repeat(70).join);
        output.writeln();
        output.writeln(format("  Peak Memory:      %6d MB", profile.peakMemoryMB));
        output.writeln(format("  GC Collections:   %6d", profile.gcCollections));
        output.writeln();
        
        if (!profile.hotPaths.empty)
        {
            output.writeln("─".repeat(70).join);
            output.writeln("HOT PATHS (slowest operations)");
            output.writeln("─".repeat(70).join);
            output.writeln();
            foreach (i, path; profile.hotPaths)
                output.writeln(format("  %d. %s", i + 1, path));
            output.writeln();
        }
        
        if (!profile.recommendations.empty)
        {
            output.writeln("─".repeat(70).join);
            output.writeln("RECOMMENDATIONS");
            output.writeln("─".repeat(70).join);
            output.writeln();
            foreach (rec; profile.recommendations)
                output.writeln("  • ", rec);
            output.writeln();
        }
        
        output.writeln("═".repeat(70).join);
    }
    
    /// Generate markdown report
    static void generateMarkdownReport(in BuildProfile[] profiles, string outputPath)
    {
        auto f = File(outputPath, "w");
        
        f.writeln("# Build Profile Report");
        f.writeln();
        f.writeln("Generated: ", Clock.currTime().toISOExtString());
        f.writeln();
        
        if (profiles.length > 1)
        {
            f.writeln("## Summary");
            f.writeln();
            f.writeln("| Project | Total | Parse | Analysis | Execution | Cache Hit |");
            f.writeln("|---------|-------|-------|----------|-----------|-----------|");
            
            foreach (profile; profiles)
            {
                auto name = baseName(profile.projectPath);
                f.writeln(format("| %s | %d ms | %d ms | %d ms | %d ms | %.1f%% |",
                        name,
                        profile.totalTime.total!"msecs",
                        profile.parseTime.total!"msecs",
                        profile.analysisTime.total!"msecs",
                        profile.executionTime.total!"msecs",
                        profile.cacheHitRate));
            }
            f.writeln();
        }
        
        foreach (profile; profiles)
        {
            f.writeln("## ", baseName(profile.projectPath));
            f.writeln();
            f.writeln("### Timing");
            f.writeln();
            f.writeln("- **Total:** ", profile.totalTime.total!"msecs", " ms");
            f.writeln("- **Parse:** ", profile.parseTime.total!"msecs", " ms");
            f.writeln("- **Analysis:** ", profile.analysisTime.total!"msecs", " ms");
            f.writeln("- **Execution:** ", profile.executionTime.total!"msecs", " ms");
            f.writeln();
            f.writeln("### Targets");
            f.writeln();
            f.writeln("- **Total:** ", profile.targetCount);
            f.writeln("- **Cached:** ", profile.cachedTargets, " (", 
                    format("%.1f", profile.cacheHitRate), "%)");
            f.writeln("- **Built:** ", profile.builtTargets);
            f.writeln();
            
            if (!profile.recommendations.empty)
            {
                f.writeln("### Recommendations");
                f.writeln();
                foreach (rec; profile.recommendations)
                    f.writeln("- ", rec);
                f.writeln();
            }
        }
        
        f.close();
        writeln("\x1b[32m✓ Report written to: ", outputPath, "\x1b[0m");
    }
    
    /// Generate flame graph compatible output (folded stacks)
    static void generateFlameGraphData(in BuildProfile profile, string outputPath)
    {
        auto f = File(outputPath, "w");
        
        // Write folded stack format: path;path;path count
        foreach (entry; profile.entries)
        {
            auto stack = entry.parent == "root" ? 
                entry.name : entry.parent ~ ";" ~ entry.name;
            f.writeln(stack, " ", entry.duration.total!"usecs");
        }
        
        f.close();
        writeln("Flame graph data written to: ", outputPath);
        writeln("Generate flame graph with: flamegraph.pl ", outputPath, " > profile.svg");
    }
}

/// Interactive profiling session
class ProfilerSession
{
    private BuildProfiler profiler;
    private BuildProfile[] profiles;
    
    this(bool verbose = false)
    {
        profiler = new BuildProfiler(null, verbose);
    }
    
    void runInteractive()
    {
        writeln("╔════════════════════════════════════════════════════════════════╗");
        writeln("║            BUILDER BUILD PROFILER                              ║");
        writeln("║   Profile real-world builds and identify bottlenecks          ║");
        writeln("╚════════════════════════════════════════════════════════════════╝");
        writeln();
        
        // Profile example projects
        import std.file : thisExePath;
        auto scriptDir = thisExePath().dirName;
        auto projectRoot = buildPath(scriptDir, "..", "..");
        auto examplesDir = buildPath(projectRoot, "examples");
        
        string[] projects = [
            buildPath(examplesDir, "simple"),
            buildPath(examplesDir, "python-multi"),
            buildPath(examplesDir, "javascript", "javascript-basic"),
            buildPath(examplesDir, "go-project"),
            buildPath(examplesDir, "cpp-project"),
        ];
        
        profiles = profiler.profileProjects(projects, true);
        
        // Generate reports
        if (!profiles.empty)
        {
            writeln("\n\n");
            writeln("═".repeat(70).join);
            writeln("DETAILED REPORTS");
            writeln("═".repeat(70).join);
            
            foreach (profile; profiles)
                ProfileReporter.generateTextReport(profile);
            
            ProfileReporter.generateMarkdownReport(profiles, "build-profile-report.md");
        }
        
        // Print final summary
        printFinalSummary();
    }
    
    void profileSingle(string projectPath)
    {
        writeln("╔════════════════════════════════════════════════════════════════╗");
        writeln("║            BUILDER BUILD PROFILER                              ║");
        writeln("╚════════════════════════════════════════════════════════════════╝");
        writeln();
        writeln("Profiling: ", projectPath);
        writeln();
        
        auto profile = profiler.profileProject(projectPath, true);
        profiles ~= profile;
        
        ProfileReporter.generateTextReport(profile);
    }
    
    private void printFinalSummary()
    {
        if (profiles.empty) return;
        
        writeln("\n\n");
        writeln("╔════════════════════════════════════════════════════════════════╗");
        writeln("║                    PROFILING SUMMARY                           ║");
        writeln("╚════════════════════════════════════════════════════════════════╝");
        writeln();
        
        auto successful = profiles.filter!(p => p.totalTime.total!"msecs" > 0).array;
        
        if (successful.empty)
        {
            writeln("No successful builds to summarize.");
            return;
        }
        
        // Calculate averages
        auto avgTotal = successful.map!(p => p.totalTime.total!"msecs").sum / successful.length;
        auto avgParse = successful.map!(p => p.parseTime.total!"msecs").sum / successful.length;
        auto avgCache = successful.map!(p => p.cacheHitRate).sum / successful.length;
        
        writeln("Projects Profiled:  ", profiles.length);
        writeln("Successful:         ", successful.length);
        writeln();
        writeln("Average Times:");
        writeln(format("  Total:            %6d ms", avgTotal));
        writeln(format("  Parse:            %6d ms", avgParse));
        writeln(format("  Cache Hit Rate:   %5.1f%%", avgCache));
        writeln();
        
        // Identify overall bottlenecks
        writeln("Common Bottlenecks:");
        
        bool foundBottleneck = false;
        foreach (profile; successful)
        {
            foreach (rec; profile.recommendations)
            {
                writeln("  • ", rec);
                foundBottleneck = true;
            }
        }
        
        if (!foundBottleneck)
            writeln("  None identified - builds are performing well!");
        
        writeln();
        writeln("═".repeat(70).join);
    }
}

void main(string[] args)
{
    auto session = new ProfilerSession(args.canFind("--verbose") || args.canFind("-v"));
    
    if (args.length > 1 && !args[1].startsWith("-"))
    {
        // Profile specific project
        session.profileSingle(args[1]);
    }
    else
    {
        // Run interactive session with example projects
        session.runInteractive();
    }
}

