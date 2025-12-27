module languages.jvm.kotlin.tooling.processors;

/// Kotlin annotation processors (KAPT and KSP)
/// 
/// Provides integration with KAPT (Kotlin Annotation Processing Tool)
/// and KSP (Kotlin Symbol Processing) for compile-time code generation.

import std.process;
import std.file;
import std.string;
import std.algorithm;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// Processor runner for KAPT and KSP
class ProcessorRunner
{
    /// Run annotation processors
    static bool run(ProcessorConfig config, string[] sources)
    {
        if (!config.enabled)
            return true;
        
        if (config.type == ProcessorType.KAPT)
            return runKAPT(config, sources);
        else
            return runKSP(config, sources);
    }
    
    /// Run KAPT
    private static bool runKAPT(ProcessorConfig config, string[] sources)
    {
        structuredLog.info("running_kapt_annotation_processors").emit();
        
        // KAPT is typically run through Gradle
        // For direct kotlinc usage, use -Xplugin option
        
        auto cmd = ["kotlinc"];
        
        // Add KAPT plugin
        cmd ~= ["-Xplugin=kotlin-annotation-processing"];
        
        // Processors
        foreach (processor; config.processors)
        {
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:processors=" ~ processor];
        }
        
        // Arguments
        foreach (key, value; config.arguments)
        {
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:apoptions=" ~ key ~ "=" ~ value];
        }
        
        // Output directory
        if (!config.outputDir.empty)
        {
            if (!exists(config.outputDir))
                mkdirRecurse(config.outputDir);
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:aptMode=stubsAndApt"];
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:sources=" ~ config.outputDir];
        }
        
        // Correct error types
        if (config.correctErrorTypes)
        {
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:correctErrorTypes=true"];
        }
        
        // Verbose
        if (config.verbose)
        {
            cmd ~= ["-P", "plugin:org.jetbrains.kotlin.kapt3:verbose=true"];
        }
        
        cmd ~= sources;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("kapt_processing_failed_").field("detail", "KAPT processing failed: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run KSP
    private static bool runKSP(ProcessorConfig config, string[] sources)
    {
        structuredLog.info("running_ksp_symbol_processors").emit();
        
        // KSP is typically run through Gradle with the KSP plugin
        // For direct usage, we need the KSP compiler plugin
        
        auto cmd = ["kotlinc"];
        
        // Add KSP plugin
        cmd ~= ["-Xplugin=kotlin-ksp-plugin"];
        
        // Processors
        foreach (processor; config.processors)
        {
            cmd ~= ["-P", "plugin:com.google.devtools.ksp:symbolProcessors=" ~ processor];
        }
        
        // Arguments
        foreach (key, value; config.arguments)
        {
            cmd ~= ["-P", "plugin:com.google.devtools.ksp:apoptions=" ~ key ~ "=" ~ value];
        }
        
        // Output directory
        if (!config.outputDir.empty)
        {
            if (!exists(config.outputDir))
                mkdirRecurse(config.outputDir);
            cmd ~= ["-P", "plugin:com.google.devtools.ksp:projectBaseDir=" ~ config.outputDir];
        }
        
        // Incremental
        if (config.incremental)
        {
            cmd ~= ["-P", "plugin:com.google.devtools.ksp:incremental=true"];
        }
        
        // Warnings as errors
        if (config.allWarningsAsErrors)
        {
            cmd ~= ["-P", "plugin:com.google.devtools.ksp:allWarningsAsErrors=true"];
        }
        
        cmd ~= sources;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("ksp_processing_failed_").field("detail", "KSP processing failed: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Check if KAPT is available
    static bool hasKAPT()
    {
        // KAPT is bundled with Kotlin compiler
        auto result = execute(["kotlinc", "-version"]);
        return result.status == 0;
    }
    
    /// Check if KSP is available
    static bool hasKSP()
    {
        // KSP requires separate installation
        // Check through Gradle or Maven dependency
        return true; // Assume available if configured
    }
}

