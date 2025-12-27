module languages.jvm.kotlin.tooling.builders.js;

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

/// Kotlin/JS builder for JavaScript output
class JSBuilder : KotlinBuilder
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
        
        structuredLog.debug_("building_kotlinjs").emit();
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name ~ ".js");
        }
        
        string outputDir = dirName(outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build with kotlin-js compiler
        auto cmd = ["kotlinc-js"];
        
        // IR backend (default for modern Kotlin)
        cmd ~= ["-Xir-produce-js"];
        
        // Module kind
        cmd ~= ["-module-kind", "umd"]; // or "commonjs", "amd", "plain"
        
        // Source map
        cmd ~= ["-source-map"];
        
        // Compiler flags
        cmd ~= config.compilerFlags;
        
        // Add language version
        if (config.languageVersion.major > 0)
            cmd ~= ["-language-version", config.languageVersion.toString()];
        
        // Add API version
        if (config.apiVersion.major > 0)
            cmd ~= ["-api-version", config.apiVersion.toString()];
        
        // Add sources
        cmd ~= sources;
        
        // Output
        cmd ~= ["-output", outputPath];
        
        structuredLog.debug_("executing_").field("detail", "Executing: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "kotlinc-js compilation failed: " ~ res.output;
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
        auto result = execute(["kotlinc-js", "-version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "JS";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.JS;
    }
}

