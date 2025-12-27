module languages.dotnet.csharp.managers.msbuild;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.uni;
import languages.dotnet.csharp.core.config;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// MSBuild operations
struct MSBuildOps
{
    /// Build project with MSBuild
    static bool build(string projectRoot, CSharpConfig config)
    {
        structuredLog.info("building_with_msbuild").emit();
        
        string[] cmd = ["msbuild"];
        
        // Find project file
        auto projectFile = findProjectFile(projectRoot);
        if (!projectFile.empty)
            cmd ~= [projectFile];
        
        // Target
        cmd ~= ["/t:Build"];
        
        // Configuration
        cmd ~= ["/p:Configuration=" ~ config.configuration];
        
        // Output directory
        if (!config.outputPath.empty)
            cmd ~= ["/p:OutputPath=" ~ config.outputPath];
        
        // Platform target
        if (!config.platformTarget.empty)
            cmd ~= ["/p:Platform=" ~ config.platformTarget];
        
        // Verbosity
        if (!config.msbuild.verbosity.empty)
            cmd ~= ["/v:" ~ config.msbuild.verbosity];
        
        // Max CPU count
        if (config.msbuild.maxCpuCount > 0)
            cmd ~= ["/m:" ~ config.msbuild.maxCpuCount.to!string];
        else
            cmd ~= ["/m"]; // Use all available CPUs
        
        // Node reuse
        if (!config.msbuild.nodeReuse)
            cmd ~= ["/nr:false"];
        
        // Detailed summary
        if (config.msbuild.detailedSummary)
            cmd ~= ["/ds"];
        
        // Binary logger
        if (config.msbuild.binaryLogger)
        {
            if (!config.msbuild.binaryLogPath.empty)
                cmd ~= ["/bl:" ~ config.msbuild.binaryLogPath];
            else
                cmd ~= ["/bl"];
        }
        
        // Additional MSBuild properties
        foreach (key, value; config.msbuild.properties)
        {
            cmd ~= ["/p:" ~ key ~ "=" ~ value];
        }
        
        // Restore
        if (config.nuget.autoRestore)
            cmd ~= ["/restore"];
        
        // Execute build - use safe array form
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("msbuild_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("msbuild_succeeded").emit();
        return true;
    }
    
    /// Clean project with MSBuild
    static bool clean(string projectRoot, CSharpConfig config)
    {
        structuredLog.info("cleaning_with_msbuild").emit();
        
        string[] cmd = ["msbuild"];
        
        // Find project file
        auto projectFile = findProjectFile(projectRoot);
        if (!projectFile.empty)
            cmd ~= [projectFile];
        
        // Target
        cmd ~= ["/t:Clean"];
        
        // Configuration
        cmd ~= ["/p:Configuration=" ~ config.configuration];
        
        // Execute clean - use safe array form
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.warning("msbuild_clean_had_issues_").field("detail", "MSBuild clean had issues: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Rebuild project with MSBuild
    static bool rebuild(string projectRoot, CSharpConfig config)
    {
        structuredLog.info("rebuilding_with_msbuild").emit();
        
        string[] cmd = ["msbuild"];
        
        // Find project file
        auto projectFile = findProjectFile(projectRoot);
        if (!projectFile.empty)
            cmd ~= [projectFile];
        
        // Target
        cmd ~= ["/t:Rebuild"];
        
        // Configuration
        cmd ~= ["/p:Configuration=" ~ config.configuration];
        
        // Execute rebuild - use safe array form
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("msbuild_rebuild_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("msbuild_rebuild_succeeded").emit();
        return true;
    }
    
    /// Run tests with MSBuild
    static bool test(string projectRoot, TestConfig config)
    {
        structuredLog.info("running_tests_with_msbuild").emit();
        
        // MSBuild doesn't have a direct test target, use VSTest instead
        string[] cmd = ["vstest.console"];
        
        // Find test assemblies
        auto testDlls = findTestAssemblies(projectRoot);
        if (testDlls.empty)
        {
            structuredLog.warning("no_test_assemblies_found").emit();
            return true;
        }
        
        cmd ~= testDlls;
        
        // Test filter
        if (!config.filter.empty)
            cmd ~= ["/TestCaseFilter:" ~ config.filter];
        
        // Logger
        if (!config.logger.empty)
            cmd ~= ["/Logger:" ~ config.logger];
        
        // Parallel
        if (config.parallel)
            cmd ~= ["/Parallel"];
        
        // Execute tests - use safe array form
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("msbuild_tests_failed_").field("detail", "MSBuild tests failed: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("msbuild_tests_succeeded").emit();
        return true;
    }
    
    /// Find project file in directory
    private static string findProjectFile(string dir)
    {
        if (!exists(dir) || !isDir(dir))
            return "";
        
        foreach (entry; dirEntries(dir, "*.csproj", SpanMode.shallow))
        {
            return entry.name;
        }
        
        return "";
    }
    
    /// Find test assemblies in directory
    private static string[] findTestAssemblies(string dir)
    {
        string[] dlls;
        
        auto binDir = buildPath(dir, "bin");
        if (!exists(binDir))
            return dlls;
        
        foreach (entry; dirEntries(binDir, "*.dll", SpanMode.depth))
        {
            // Simple heuristic: test assemblies often contain "Test" in name
            if (entry.name.canFind("Test"))
                dlls ~= entry.name;
        }
        
        return dlls;
    }
}

/// MSBuild tool detection
struct MSBuildToolDetection
{
    /// Check if MSBuild is available
    static bool isMSBuildAvailable()
    {
        try
        {
            auto result = execute(["msbuild", "/version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Check if project has MSBuild file
    static bool hasMSBuildFile(string dir)
    {
        if (!exists(dir) || !isDir(dir))
            return false;
        
        foreach (entry; dirEntries(dir, "*.csproj", SpanMode.shallow))
        {
            return true;
        }
        
        foreach (entry; dirEntries(dir, "*.sln", SpanMode.shallow))
        {
            return true;
        }
        
        return false;
    }
    
    /// Get MSBuild version
    static string getVersion()
    {
        try
        {
            auto result = execute(["msbuild", "/version"]);
            if (result.status == 0)
            {
                // Parse version from output
                auto lines = result.output.split("\n");
                foreach (line; lines)
                {
                    if (line.canFind("Microsoft") && line.canFind("Build") && line.canFind("Engine"))
                    {
                        // Extract version number
                        auto parts = line.split();
                        foreach (part; parts)
                        {
                            import std.ascii : isDigit;
                            if (part.canFind(".") && part.length > 0 && isDigit(part[0]))
                                return part;
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
        }
        
        return "";
    }
}

