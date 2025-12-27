module languages.compiled.cpp.builders.make;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.cpp.core.config;
// import toolchain; // Replaced by unified toolchain system
import infrastructure.toolchain.core.spec;
import languages.compiled.cpp.builders.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Make-based builder
class MakeBuilder : BaseCppBuilder
{
    this(CppConfig config)
    {
        super(config);
    }
    
    override CppCompileResult build(
        in string[] sources,
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        CppCompileResult result;
        
        if (!isAvailable())
        {
            result.error = "Make is not available";
            return result;
        }
        
        structuredLog.debug_("building_with_make").emit();
        
        // Find Makefile
        string makefile = findMakefile(sources);
        if (makefile.empty)
        {
            result.error = "Makefile not found";
            return result;
        }
        
        string projectDir = dirName(makefile);
        
        // Build with Make
        auto buildResult = buildMake(projectDir, config, target);
        if (!buildResult.success)
        {
            result.error = "Make build failed: " ~ buildResult.error;
            return result;
        }
        
        // Find output files
        string outputFile = findMakeOutput(projectDir, target, workspace);
        if (outputFile.empty || !exists(outputFile))
        {
            result.error = "Make output file not found";
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        result.outputHash = FastHash.hashFile(outputFile);
        result.warnings = buildResult.warnings;
        result.hadWarnings = buildResult.hadWarnings;
        
        return result;
    }
    
    override bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("make").empty;
    }
    
    override string name() const
    {
        return "Make";
    }
    
    override string getVersion()
    {
        auto res = execute(["make", "--version"]);
        if (res.status == 0)
        {
            auto lines = res.output.split("\n");
            if (!lines.empty)
                return lines[0].strip;
        }
        return "unknown";
    }
    
    private string findMakefile(in string[] sources)
    {
        if (sources.empty)
            return "";
        
        string dir = dirName(sources[0]);
        
        // Search for Makefile or makefile
        while (dir != "/" && dir.length > 1)
        {
            string makePath = buildPath(dir, "Makefile");
            if (exists(makePath))
                return makePath;
            
            makePath = buildPath(dir, "makefile");
            if (exists(makePath))
                return makePath;
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    private CppCompileResult buildMake(string projectDir, in CppConfig config, in Target target)
    {
        CppCompileResult result;
        
        string[] cmd = ["make"];
        
        // Parallel jobs
        if (config.jobs > 0)
        {
            cmd ~= ["-j", config.jobs.to!string];
        }
        
        // Target name (if specified in Makefile)
        string targetName = target.name.split(":")[$ - 1];
        // Only add if it's not the default target
        // cmd ~= targetName;
        
        structuredLog.info("building_with_make").emit();
        structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        // Execute in project directory
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        // Parse warnings
        foreach (line; res.output.split("\n"))
        {
            if (line.canFind("warning:") || line.canFind("Warning:"))
            {
                result.hadWarnings = true;
                result.warnings ~= line;
            }
        }
        
        result.success = true;
        return result;
    }
    
    private string findMakeOutput(string projectDir, in Target target, in WorkspaceConfig workspace)
    {
        string[] searchDirs = [
            projectDir,
            buildPath(projectDir, "bin"),
            buildPath(projectDir, "build"),
            buildPath(projectDir, "out")
        ];
        
        string targetName = target.name.split(":")[$ - 1];
        
        foreach (dir; searchDirs)
        {
            if (!exists(dir))
                continue;
            
            foreach (entry; dirEntries(dir, SpanMode.shallow))
            {
                if (entry.isFile && baseName(entry.name).canFind(targetName))
                {
                    return entry.name;
                }
            }
        }
        
        return "";
    }
}

