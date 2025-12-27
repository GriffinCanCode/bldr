module languages.scripting.r.tooling.builders.packagebuilder;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import infrastructure.config.schema.schema;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.builders.base;
import languages.scripting.r.analysis.dependencies;
import languages.scripting.r.managers.packages;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Package builder - builds R packages
class RPackageBuilder : RBuilder
{
    override BuildResult build(
        in Target target,
        in WorkspaceConfig config,
        in RConfig rConfig,
        in string rCmd
    )
    {
        BuildResult result;
        
        string packageRoot = config.root;
        
        // Check if DESCRIPTION file exists
        string descPath = buildPath(packageRoot, "DESCRIPTION");
        if (!exists(descPath))
        {
            result.error = "DESCRIPTION file not found at: " ~ descPath;
            return result;
        }
        
        structuredLog.info("building_r_package_from_").field("detail", "Building R package from: " ~ packageRoot).emit();
        
        // Check or install dependencies first
        if (rConfig.installDeps)
        {
            auto deps = parseDESCRIPTION(descPath);
            if (!deps.empty)
            {
                structuredLog.info("package_has_").field("detail", "Package has " ~ deps.length.to!string ~ " dependencies").emit();
                auto installResult = installPackages(deps, rConfig.packageManager, rCmd, packageRoot, rConfig);
                
                if (!installResult.success)
                {
                    structuredLog.warning("failed_to_install_some_dependencies_").field("detail", "Failed to install some dependencies: " ~ installResult.error).emit();
                    if (!installResult.failedPackages.empty)
                    {
                        structuredLog.warning("failed_packages_").field("detail", "Failed packages: " ~ installResult.failedPackages.join(", ")).emit();
                    }
                }
                else
                {
                    structuredLog.info("successfully_installed_").field("detail", "Successfully installed " ~ installResult.installedPackages.length.to!string ~ " dependencies").emit();
                }
            }
        }
        
        // Determine build mode
        string[] cmdArgs;
        string outputPath;
        
        final switch (rConfig.mode)
        {
            case RBuildMode.Package:
                // Build source package
                cmdArgs = [rCmd, "CMD", "build"];
                if (!rConfig.package_.buildVignettes)
                    cmdArgs ~= "--no-build-vignettes";
                cmdArgs ~= packageRoot;
                outputPath = buildPath(config.options.outputDir, target.name ~ ".tar.gz");
                break;
                
            case RBuildMode.Check:
                // Check package
                cmdArgs = [rCmd, "CMD", "check"];
                // Don't run tests by default during check
                cmdArgs ~= "--no-tests";
                if (!rConfig.package_.buildVignettes)
                    cmdArgs ~= "--no-build-vignettes";
                cmdArgs ~= packageRoot;
                outputPath = buildPath(config.options.outputDir, "check.log");
                break;
                
            case RBuildMode.Vignette:
                // Build vignettes
                cmdArgs = [rCmd, "CMD", "build", "--no-manual"];
                cmdArgs ~= packageRoot;
                outputPath = buildPath(config.options.outputDir, "vignettes");
                break;
                
            case RBuildMode.Script:
            case RBuildMode.Shiny:
            case RBuildMode.RMarkdown:
                result.error = "Invalid build mode for package builder";
                return result;
        }
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmdArgs.join(" ")).emit();
        
        try
        {
            auto res = execute(cmdArgs);
            
            if (res.status != 0)
            {
                result.error = "R CMD failed with status " ~ res.status.to!string;
                result.toolWarnings ~= res.output;
                return result;
            }
            
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(descPath);
            
            structuredLog.info("r_package_build_completed_successfully").emit();
            
            return result;
        }
        catch (Exception e)
        {
            result.error = "Failed to build package: " ~ e.msg;
            return result;
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config, in RConfig rConfig)
    {
        string[] outputs;
        
        final switch (rConfig.mode)
        {
            case RBuildMode.Package:
                outputs ~= buildPath(config.options.outputDir, target.name ~ ".tar.gz");
                break;
            case RBuildMode.Check:
                outputs ~= buildPath(config.options.outputDir, "check.log");
                break;
            case RBuildMode.Vignette:
                outputs ~= buildPath(config.options.outputDir, "vignettes");
                break;
            case RBuildMode.Script:
            case RBuildMode.Shiny:
            case RBuildMode.RMarkdown:
                break;
        }
        
        return outputs;
    }
    
    override bool validate(in Target target, in RConfig rConfig)
    {
        // Package builds don't necessarily need source files specified,
        // as they build the entire package directory
        return true;
    }
}

