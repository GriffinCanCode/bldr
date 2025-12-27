module languages.compiled.cpp.builders.meson;

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

/// Meson build system builder
class MesonBuilder : BaseCppBuilder
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
            result.error = "Meson is not available. Install from https://mesonbuild.com/";
            return result;
        }
        
        structuredLog.info("building_with_meson").emit();
        
        // Find meson.build
        string mesonFile = findMesonFile(workspace.root);
        if (mesonFile.empty)
        {
            result.error = "No meson.build file found";
            return result;
        }
        
        string projectDir = dirName(mesonFile);
        string buildDir = buildPath(projectDir, "builddir");
        
        // Setup build directory if needed
        if (!exists(buildDir) || !exists(buildPath(buildDir, "build.ninja")))
        {
            auto setupResult = setupMeson(projectDir, buildDir, config);
            if (!setupResult.success)
            {
                result.error = "Meson setup failed: " ~ setupResult.error;
                return result;
            }
        }
        
        // Compile
        auto compileResult = compileMeson(buildDir);
        if (!compileResult.success)
        {
            result.error = "Meson compile failed: " ~ compileResult.error;
            return result;
        }
        
        // Find output files
        string outputPath = findMesonOutput(buildDir, target, workspace);
        if (!outputPath.empty && exists(outputPath))
        {
            result.outputs ~= outputPath;
            result.outputHash = FastHash.hashFile(outputPath);
        }
        
        result.success = true;
        
        structuredLog.info("meson_build_completed_successfully").emit();
        
        return result;
    }
    
    override bool isAvailable()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        return !ExecutableDetector.findInPath("meson").empty && 
               !ExecutableDetector.findInPath("ninja").empty;
    }
    
    override string name() const
    {
        return "Meson";
    }
    
    override string getVersion()
    {
        auto res = execute(["meson", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    override bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "pch":
            case "lto":
            case "sanitizers":
            case "unity":
                return true;
            default:
                return false;
        }
    }
    
    private string findMesonFile(string startDir)
    {
        string candidate = buildPath(startDir, "meson.build");
        return exists(candidate) ? candidate : "";
    }
    
    private CppCompileResult setupMeson(string projectDir, string buildDir, in CppConfig config)
    {
        CppCompileResult result;
        
        structuredLog.debug_("setting_up_meson_build").emit();
        
        string[] cmd = ["meson", "setup", buildDir];
        
        // Add build type
        if (config.debugInfo)
            cmd ~= ["--buildtype=debug"];
        else if (config.optLevel == OptLevel.O3)
            cmd ~= ["--buildtype=release"];
        else
            cmd ~= ["--buildtype=plain"];
        
        // Add LTO if requested
        if (config.lto != LtoMode.Off)
            cmd ~= ["-Db_lto=true"];
        
        // Add sanitizers
        if (!config.sanitizers.empty)
        {
            foreach (san; config.sanitizers)
            {
                switch (san)
                {
                    case Sanitizer.Address:
                        cmd ~= ["-Db_sanitize=address"];
                        break;
                    case Sanitizer.Thread:
                        cmd ~= ["-Db_sanitize=thread"];
                        break;
                    case Sanitizer.UndefinedBehavior:
                        cmd ~= ["-Db_sanitize=undefined"];
                        break;
                    default:
                        break;
                }
            }
        }
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        return result;
    }
    
    private CppCompileResult compileMeson(string buildDir)
    {
        CppCompileResult result;
        
        structuredLog.debug_("compiling_with_meson").emit();
        
        string[] cmd = ["meson", "compile", "-C", buildDir];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        return result;
    }
    
    private string findMesonOutput(string buildDir, in Target target, in WorkspaceConfig workspace)
    {
        // Meson puts outputs in builddir
        string name = target.name.split(":")[$ - 1];
        
        string[] candidates = [
            buildPath(buildDir, name),
            buildPath(buildDir, "lib" ~ name ~ ".a"),
            buildPath(buildDir, "lib" ~ name ~ ".so"),
            buildPath(buildDir, name ~ ".exe")
        ];
        
        foreach (candidate; candidates)
        {
            if (exists(candidate))
                return candidate;
        }
        
        return "";
    }
}

