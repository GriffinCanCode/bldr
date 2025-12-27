module languages.compiled.cpp.builders.bazel;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.cpp.core.config;
import infrastructure.toolchain.core.spec;
import languages.compiled.cpp.builders.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Bazel build system builder
class BazelBuilder : BaseCppBuilder
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
            result.error = "Bazel is not available. Install from https://bazel.build/";
            return result;
        }
        
        structuredLog.info("building_with_bazel").emit();
        
        // Find WORKSPACE or BUILD file
        string buildFile = findBuildFile(workspace.root);
        if (buildFile.empty)
        {
            result.error = "No Bazel WORKSPACE or BUILD file found";
            return result;
        }
        
        string projectDir = dirName(buildFile);
        
        // Determine target name from config or use default
        string bazelTarget = determineBazelTarget(target, config);
        
        // Build command
        string[] cmd = ["bazel", "build"];
        
        // Add optimization flags
        if (config.optLevel == OptLevel.O3)
            cmd ~= ["--compilation_mode=opt"];
        else if (config.debugInfo)
            cmd ~= ["--compilation_mode=dbg"];
        else
            cmd ~= ["--compilation_mode=fastbuild"];
        
        cmd ~= [bazelTarget];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        // Execute build
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = "Bazel build failed:\n" ~ res.output;
            return result;
        }
        
        // Find output files in bazel-bin
        string outputPath = findBazelOutput(projectDir, target, workspace);
        if (!outputPath.empty && exists(outputPath))
        {
            result.outputs ~= outputPath;
            result.outputHash = FastHash.hashFile(outputPath);
        }
        
        result.success = true;
        
        structuredLog.info("bazel_build_completed_successfully").emit();
        
        return result;
    }
    
    override bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("bazel").empty;
    }
    
    override string name() const
    {
        return "Bazel";
    }
    
    override string getVersion()
    {
        auto res = execute(["bazel", "version"]);
        if (res.status == 0)
        {
            // Extract version from output
            auto lines = res.output.split("\n");
            if (lines.length > 0)
                return lines[0].strip;
        }
        return "unknown";
    }
    
    override bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "pch":
            case "lto":
            case "sanitizers":
                return true;
            default:
                return false;
        }
    }
    
    private string findBuildFile(string startDir)
    {
        // Look for WORKSPACE or BUILD file
        string[] candidates = [
            buildPath(startDir, "WORKSPACE"),
            buildPath(startDir, "WORKSPACE.bazel"),
            buildPath(startDir, "BUILD"),
            buildPath(startDir, "BUILD.bazel")
        ];
        
        foreach (candidate; candidates)
        {
            if (exists(candidate))
                return candidate;
        }
        
        return "";
    }
    
    private string determineBazelTarget(in Target target, in CppConfig config)
    {
        // Use target name if it looks like a Bazel target
        if (target.name.startsWith("//") || target.name.startsWith(":"))
            return target.name;
        
        // Default to //:target_name
        string name = target.name.split(":")[$ - 1];
        return "//:" ~ name;
    }
    
    private string findBazelOutput(string projectDir, in Target target, in WorkspaceConfig workspace)
    {
        string binDir = buildPath(projectDir, "bazel-bin");
        if (!exists(binDir))
            return "";
        
        // Look for the executable or library
        string name = target.name.split(":")[$ - 1];
        
        string[] candidates = [
            buildPath(binDir, name),
            buildPath(binDir, "lib" ~ name ~ ".a"),
            buildPath(binDir, "lib" ~ name ~ ".so"),
            buildPath(binDir, name ~ ".exe")
        ];
        
        foreach (candidate; candidates)
        {
            if (exists(candidate))
                return candidate;
        }
        
        return "";
    }
}

