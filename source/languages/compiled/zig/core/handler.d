module languages.compiled.zig.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.base.base;
import languages.compiled.zig.core.config;
import languages.compiled.zig.analysis.builder;
import languages.compiled.zig.tooling.tools;
import languages.compiled.zig.analysis.targets;
import languages.compiled.zig.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;

/// Advanced Zig build handler with build.zig and cross-compilation support
class ZigHandler : BaseLanguageHandler
{
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building Zig target: " ~ target.name);
        
        // Parse Zig configuration
        ZigConfig zigConfig = parseZigConfig(target);
        
        // Auto-detect and enhance configuration
        enhanceConfigFromProject(zigConfig, target, config);
        
        // Run formatter if requested
        if (zigConfig.runFmt)
        {
            auto fmtResult = formatCode(target.sources, zigConfig);
            if (fmtResult.hasIssues())
            {
                Logger.info("Formatting issues found:");
                foreach (warning; fmtResult.warnings)
                {
                    Logger.warning("  " ~ warning);
                }
            }
        }
        
        // Run ast-check if requested
        if (zigConfig.runCheck)
        {
            auto checkResult = ZigTools.astCheck(target.sources.dup);
            if (!checkResult.success)
            {
                Logger.warning("AST check found issues:");
                foreach (error; checkResult.errors)
                {
                    Logger.warning("  " ~ error);
                }
            }
        }
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, zigConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, zigConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, zigConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, zigConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        ZigConfig zigConfig = parseZigConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Add platform-specific extension
            version(Windows)
            {
                if (zigConfig.outputType == OutputType.Exe)
                    name ~= ".exe";
            }
            
            string outputDir = zigConfig.outputDir.empty ? 
                              config.options.outputDir : 
                              zigConfig.outputDir;
            
            outputs ~= buildPath(outputDir, name);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Zig);
        if (spec is null)
            return [];
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = spec.scanImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                Logger.warning("Failed to analyze imports in " ~ source);
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        ZigConfig zigConfig
    )
    {
        LanguageBuildResult result;
        
        // Ensure output type is executable
        zigConfig.outputType = OutputType.Exe;
        
        // Auto-detect entry point
        if (zigConfig.entry.empty && !target.sources.empty)
        {
            // Look for main.zig first
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.zig")
                {
                    zigConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (zigConfig.entry.empty)
                zigConfig.entry = target.sources[0];
        }
        
        // Build with selected builder
        return compileTarget(target, config, zigConfig);
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        ZigConfig zigConfig
    )
    {
        LanguageBuildResult result;
        
        // Set output type to library
        if (zigConfig.outputType == OutputType.Exe)
            zigConfig.outputType = OutputType.Lib;
        
        // Auto-detect entry point
        if (zigConfig.entry.empty && !target.sources.empty)
        {
            // Look for lib.zig or root.zig first
            foreach (source; target.sources)
            {
                string basename = baseName(source);
                if (basename == "lib.zig" || basename == "root.zig")
                {
                    zigConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (zigConfig.entry.empty)
                zigConfig.entry = target.sources[0];
        }
        
        return compileTarget(target, config, zigConfig);
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        ZigConfig zigConfig
    )
    {
        LanguageBuildResult result;
        
        // Set mode to test
        zigConfig.mode = ZigBuildMode.Test;
        
        return compileTarget(target, config, zigConfig);
    }
    
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        ZigConfig zigConfig
    )
    {
        LanguageBuildResult result;
        
        zigConfig.mode = ZigBuildMode.Custom;
        
        return compileTarget(target, config, zigConfig);
    }
    
    private LanguageBuildResult compileTarget(
        const Target target,
        const WorkspaceConfig config,
        ZigConfig zigConfig
    )
    {
        LanguageBuildResult result;
        
        // Create builder
        auto builder = ZigBuilderFactory.create(zigConfig.builder, zigConfig);
        
        if (!builder.isAvailable())
        {
            result.error = "Zig compiler not available. Install from: https://ziglang.org/download/";
            return result;
        }
        
        Logger.debugLog("Using Zig builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")");
        
        // Compile
        auto compileResult = builder.build(target.sources, zigConfig, target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (compileResult.hadWarnings && !compileResult.warnings.empty)
        {
            Logger.warning("Compilation warnings:");
            foreach (warn; compileResult.warnings[0 .. min(5, $)])
            {
                Logger.warning("  " ~ warn);
            }
            if (compileResult.warnings.length > 5)
            {
                Logger.warning("  ... and " ~ (compileResult.warnings.length - 5).to!string ~ " more warnings");
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private ZigConfig parseZigConfig(in Target target)
    {
        ZigConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("zig" in target.langConfig)
            configKey = "zig";
        else if ("zigConfig" in target.langConfig)
            configKey = "zigConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = ZigConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse Zig config, using defaults: " ~ e.msg);
            }
        }
        
        // Apply target flags to config
        if (!target.flags.empty)
        {
            // Target flags are added during compilation
        }
        
        return config;
    }
    
    private void enhanceConfigFromProject(
        ref ZigConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        if (target.sources.empty && target.root.empty)
            return;
        
        // Determine search directory - prefer target.root if set
        string sourceDir;
        if (!target.root.empty)
        {
            sourceDir = target.root.isAbsolute ? target.root : buildPath(workspace.root, target.root);
            Logger.debugLog("Using target root for build.zig search: " ~ sourceDir);
        }
        else if (!target.sources.empty)
        {
            sourceDir = dirName(target.sources[0]);
        }
        else
        {
            sourceDir = workspace.root;
        }
        
        // Auto-detect build.zig
        if (config.builder == ZigBuilderType.Auto)
        {
            auto buildZigPath = BuildZigParser.findBuildZig(sourceDir);
            if (!buildZigPath.empty)
            {
                Logger.debugLog("Detected build.zig at: " ~ buildZigPath);
                config.buildZig.path = buildZigPath.idup;
                config.builder = ZigBuilderType.BuildZig;
                
                // Parse build.zig for project info
                auto project = BuildZigParser.parseBuildZig(buildZigPath);
                if (!project.name.empty)
                {
                    Logger.debugLog("Project: " ~ project.name ~ 
                                 (project.version_.empty ? "" : " v" ~ project.version_));
                }
            }
            else
            {
                config.builder = ZigBuilderType.Compile;
            }
        }
        
        // Auto-detect entry point
        if (config.entry.empty && !target.sources.empty)
        {
            // Look for main.zig, lib.zig, or root.zig
            foreach (source; target.sources)
            {
                string basename = baseName(source);
                if (basename == "main.zig" || 
                    basename == "lib.zig" || 
                    basename == "root.zig")
                {
                    config.entry = source.idup;
                    break;
                }
            }
            
            // Fallback to first source
            if (config.entry.empty)
                config.entry = target.sources[0].idup;
        }
        
        // Initialize target manager
        TargetManager.initialize();
    }
    
    private ToolResult formatCode(in string[] sources, ZigConfig config)
    {
        return ZigTools.format(
            sources.dup,
            config.fmtCheck,  // check only
            !config.fmtCheck, // write in place
            config.fmtExclude // exclude pattern
        );
    }
}


