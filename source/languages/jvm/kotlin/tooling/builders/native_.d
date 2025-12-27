module languages.jvm.kotlin.tooling.builders.native_;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.kotlin.tooling.builders.base;
import languages.jvm.kotlin.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Kotlin/Native builder for native executables
class NativeBuilder : KotlinBuilder
{
    this(ActionCache cache = null) {}
    
    override KotlinBuildResult build(
        in string[] sources,
        in KotlinConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        KotlinBuildResult result;
        
        structuredLog.debug_("building_kotlinnative_executable").emit();
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name);
        }
        
        string outputDir = dirName(outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build with kotlin-native compiler
        auto cmd = ["kotlinc-native"];
        
        // Add target platform
        if (!config.native.target.empty)
        {
            cmd ~= ["-target", config.native.target];
        }
        
        // Optimization
        if (config.native.optimization == "release")
        {
            cmd ~= ["-opt"];
        }
        else if (config.native.optimization == "debug")
        {
            cmd ~= ["-g"];
        }
        
        // Libraries
        foreach (lib; config.native.libraries)
        {
            cmd ~= ["-l", lib];
        }
        
        // Include directories
        foreach (incDir; config.native.includeDirs)
        {
            cmd ~= ["-includedir", incDir];
        }
        
        // Static linking
        if (config.native.staticLink)
        {
            cmd ~= ["-Xstatic-framework"];
        }
        
        // C interop
        if (config.native.cinterop && !config.native.cinteropDef.empty)
        {
            cmd ~= ["-cinterop", config.native.cinteropDef];
        }
        
        // Compiler flags
        cmd ~= config.compilerFlags;
        
        // Add sources
        cmd ~= sources;
        
        // Output
        cmd ~= ["-o", outputPath];
        
        structuredLog.debug_("executing_").field("detail", "Executing: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "kotlin-native compilation failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        
        if (exists(outputPath))
        {
            result.outputHash = FastHash.hashFile(outputPath);
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto result = execute(["kotlinc-native", "-version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "Native";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.Native;
    }
}

