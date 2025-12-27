module languages.scripting.perl.services.build;

import languages.scripting.perl.core.config;
import infrastructure.config.schema.schema : LanguageBuildResult;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import engine.caching.actions.action;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import std.range : empty;

/// Build service interface
interface IPerlBuildService
{
    /// Build executable script
    LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    );
    
    /// Build library module
    LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    );
    
    /// Build CPAN module
    LanguageBuildResult buildCPAN(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig,
        ActionCache cache
    );
}

/// Concrete Perl build service
final class PerlBuildService : IPerlBuildService
{
    LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    ) @trusted
    {
        import std.process : executeShell;
        import std.file : copy, exists, mkdirRecurse;
        import std.path : buildPath, dirName, baseName, stripExtension;
        
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.success = true;
            return result;
        }
        
        string mainScript = target.sources[0];
        string outputPath;
        
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = mainScript.baseName.stripExtension;
            outputPath = buildPath(config.options.outputDir, name);
        }
        
        // Ensure output directory exists
        auto outputDir = outputPath.dirName;
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        // Copy script to output
        try
        {
            copy(mainScript, outputPath);
            
            version(Posix)
            {
                executeShell("chmod +x " ~ outputPath);
            }
            
            result.outputs ~= outputPath;
            result.success = true;
            result.outputHash = FastHash.hashFile(mainScript);
        }
        catch (Exception e)
        {
            result.error = "Failed to create executable: " ~ e.msg;
        }
        
        return result;
    }
    
    LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    ) @trusted
    {
        LanguageBuildResult result;
        
        // For regular modules, outputs are the source files
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    LanguageBuildResult buildCPAN(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig,
        ActionCache cache
    ) @trusted
    {
        // Detect build tool
        auto buildTool = detectBuildTool(config.root, perlConfig);
        
        if (buildTool == PerlBuildTool.Auto)
        {
            LanguageBuildResult result;
            result.error = "Could not detect CPAN build tool";
            return result;
        }
        
        // Run appropriate build
        final switch (buildTool)
        {
            case PerlBuildTool.Auto:
            case PerlBuildTool.None:
                LanguageBuildResult result;
                result.success = true;
                return result;
                
            case PerlBuildTool.ModuleBuild:
                return runModuleBuild(config.root, cache);
                
            case PerlBuildTool.MakeMaker:
                return runMakeMaker(config.root, cache);
                
            case PerlBuildTool.DistZilla:
                return runDistZilla(config.root);
                
            case PerlBuildTool.Minilla:
                return runMinilla(config.root);
        }
    }
    
    private PerlBuildTool detectBuildTool(string root, in PerlConfig config) @trusted
    {
        import std.file : exists;
        import std.path : buildPath;
        
        if (config.buildTool != PerlBuildTool.Auto)
            return config.buildTool;
        
        if (exists(buildPath(root, "Build.PL")))
            return PerlBuildTool.ModuleBuild;
        else if (exists(buildPath(root, "Makefile.PL")))
            return PerlBuildTool.MakeMaker;
        else if (exists(buildPath(root, "dist.ini")))
            return PerlBuildTool.DistZilla;
        else if (exists(buildPath(root, "minil.toml")))
            return PerlBuildTool.Minilla;
        
        return PerlBuildTool.Auto;
    }
    
    private LanguageBuildResult runModuleBuild(string projectRoot, ActionCache cache) @trusted
    {
        import std.process : execute, Config;
        import std.file : exists, dirEntries, SpanMode;
        import std.path : buildPath, baseName;
        
        LanguageBuildResult result;
        structuredLog.info("building_with_modulebuild").emit();
        
        // Gather input files for caching
        string buildPL = buildPath(projectRoot, "Build.PL");
        string[] inputFiles = [buildPL];
        
        string libDir = buildPath(projectRoot, "lib");
        if (exists(libDir))
        {
            foreach (entry; dirEntries(libDir, "*.pm", SpanMode.depth))
            {
                inputFiles ~= entry.name;
            }
        }
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = baseName(projectRoot);
        actionId.type = ActionType.Package;
        actionId.subId = "module_build";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        string[string] metadata;
        metadata["buildSystem"] = "Module::Build";
        
        // Check cache
        if (cache.isCached(actionId, inputFiles, metadata))
        {
            structuredLog.info("__cached_modulebuild").emit();
            result.success = true;
            return result;
        }
        
        // Run Build.PL
        bool success = false;
        auto configRes = execute(["perl", "Build.PL"], null, Config.none, size_t.max, projectRoot);
        
        if (configRes.status != 0)
        {
            result.error = "Build.PL failed: " ~ configRes.output;
            cache.update(actionId, inputFiles, [], metadata, false);
            return result;
        }
        
        // Run ./Build
        auto buildRes = execute(["./Build"], null, Config.none, size_t.max, projectRoot);
        
        if (buildRes.status != 0)
        {
            result.error = "Build failed: " ~ buildRes.output;
            cache.update(actionId, inputFiles, [], metadata, false);
            return result;
        }
        
        success = true;
        result.success = true;
        cache.update(actionId, inputFiles, [], metadata, success);
        
        return result;
    }
    
    private LanguageBuildResult runMakeMaker(string projectRoot, ActionCache cache) @trusted
    {
        import std.process : execute, Config;
        import std.file : exists, dirEntries, SpanMode;
        import std.path : buildPath, baseName;
        
        LanguageBuildResult result;
        structuredLog.info("building_with_extutilsmakemaker").emit();
        
        // Gather input files
        string makefilePL = buildPath(projectRoot, "Makefile.PL");
        string[] inputFiles = [makefilePL];
        
        string libDir = buildPath(projectRoot, "lib");
        if (exists(libDir))
        {
            foreach (entry; dirEntries(libDir, "*.pm", SpanMode.depth))
            {
                inputFiles ~= entry.name;
            }
        }
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = baseName(projectRoot);
        actionId.type = ActionType.Package;
        actionId.subId = "make_maker";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        string[string] metadata;
        metadata["buildSystem"] = "ExtUtils::MakeMaker";
        
        // Check cache
        if (cache.isCached(actionId, inputFiles, metadata))
        {
            structuredLog.info("__cached_extutilsmakemaker").emit();
            result.success = true;
            return result;
        }
        
        // Run Makefile.PL
        bool success = false;
        auto configRes = execute(["perl", "Makefile.PL"], null, Config.none, size_t.max, projectRoot);
        
        if (configRes.status != 0)
        {
            result.error = "Makefile.PL failed: " ~ configRes.output;
            cache.update(actionId, inputFiles, [], metadata, false);
            return result;
        }
        
        // Run make
        auto buildRes = execute(["make"], null, Config.none, size_t.max, projectRoot);
        
        if (buildRes.status != 0)
        {
            result.error = "make failed: " ~ buildRes.output;
            cache.update(actionId, inputFiles, [], metadata, false);
            return result;
        }
        
        success = true;
        result.success = true;
        cache.update(actionId, inputFiles, [], metadata, success);
        
        return result;
    }
    
    private LanguageBuildResult runDistZilla(string projectRoot) @trusted
    {
        import std.process : execute, Config;
        
        LanguageBuildResult result;
        
        if (!isCommandAvailable("dzil"))
        {
            result.error = "dzil command not available (install Dist::Zilla)";
            return result;
        }
        
        structuredLog.info("building_with_distzilla").emit();
        
        auto buildRes = execute(["dzil", "build"], null, Config.none, size_t.max, projectRoot);
        
        if (buildRes.status != 0)
        {
            result.error = "dzil build failed: " ~ buildRes.output;
            return result;
        }
        
        result.success = true;
        return result;
    }
    
    private LanguageBuildResult runMinilla(string projectRoot) @trusted
    {
        import std.process : execute, Config;
        
        LanguageBuildResult result;
        
        if (!isCommandAvailable("minil"))
        {
            result.error = "minil command not available (install Minilla)";
            return result;
        }
        
        structuredLog.info("building_with_minilla").emit();
        
        auto buildRes = execute(["minil", "build"], null, Config.none, size_t.max, projectRoot);
        
        if (buildRes.status != 0)
        {
            result.error = "minil build failed: " ~ buildRes.output;
            return result;
        }
        
        result.success = true;
        return result;
    }
    
    private bool isCommandAvailable(string cmd) @trusted
    {
        import std.process : execute;
        
        try
        {
            version(Windows)
            {
                auto res = execute(["where", cmd]);
                return res.status == 0;
            }
            else
            {
                auto res = execute(["which", cmd]);
                return res.status == 0;
            }
        }
        catch (Exception e)
        {
            return false;
        }
    }
}

