module languages.compiled.nim.builders.nimble;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.compiled.nim.builders.base;
import languages.compiled.nim.core.config;
import languages.compiled.nim.tooling.tools;
import languages.compiled.nim.analysis.nimble;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Nimble builder - uses nimble build system for package-based projects
class NimbleBuilder : NimBuilder
{
    void setActionCache(ActionCache cache)
    {
        // Nimble builder could add caching in future for nimble build operations
    }
    
    NimCompileResult build(
        in string[] sources,
        in NimConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        NimCompileResult result;
        
        // Find nimble file
        string nimbleFile = config.nimble.nimbleFile;
        if (nimbleFile.empty)
        {
            nimbleFile = NimbleParser.findNimbleFile(".");
            if (nimbleFile.empty)
            {
                result.error = "No .nimble file found in project";
                return result;
            }
        }
        
        structuredLog.debug_("using_nimble_file_").field("detail", "Using nimble file: " ~ nimbleFile).emit();
        
        // Parse nimble file
        auto nimbleData = NimbleParser.parseNimbleFile(nimbleFile);
        if (nimbleData.name.empty)
        {
            structuredLog.warning("failed_to_parse_nimble_file_proceeding_w").emit();
        }
        else
        {
            structuredLog.debug_("package_").field("detail", "Package: " ~ nimbleData.name ~ 
                        (nimbleData.version_.empty ? "" : " v" ~ nimbleData.version_)).emit();
        }
        
        // Install dependencies if requested
        if (config.nimble.installDeps)
        {
            auto installResult = installDependencies(nimbleFile, config);
            if (!installResult)
            {
                result.error = "Failed to install nimble dependencies";
                return result;
            }
        }
        
        // Build with nimble
        string[] cmd = buildNimbleCommand(nimbleFile, config, target);
        
        if (config.verbose || config.listCmd)
        {
            structuredLog.info("nimble_command_").field("detail", "Nimble command: " ~ cmd.join(" ")).emit();
        }
        
        // Set environment variables
        string[string] env = environment.toAA();
        foreach (key, value; config.env)
        {
            env[key] = value;
        }
        
        // Execute nimble
        auto res = execute(cmd, env);
        
        if (res.status != 0)
        {
            result.error = "Nimble build failed: " ~ res.output;
            return result;
        }
        
        // Determine output path
        string outputPath = findNimbleOutput(nimbleData, config, workspace);
        
        if (!exists(outputPath))
        {
            // Try alternative locations
            outputPath = findAlternativeOutput(nimbleData, config, workspace);
        }
        
        if (!exists(outputPath))
        {
            result.error = "Nimble build succeeded but output not found";
            result.success = true; // Build succeeded, just missing output tracking
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    bool isAvailable()
    {
        return NimTools.isNimbleAvailable();
    }
    
    string name() const
    {
        return "nimble";
    }
    
    string getVersion()
    {
        return NimTools.getNimbleVersion();
    }
    
    bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "nimble":
            case "dependencies":
            case "packages":
            case "tasks":
                return true;
            default:
                return false;
        }
    }
    
    private bool installDependencies(string nimbleFile, in NimConfig config)
    {
        structuredLog.info("installing_nimble_dependencies").emit();
        
        string[] cmd = ["nimble", "install", "-y"];
        
        if (config.nimble.devMode)
            cmd ~= "--depsOnly";
        
        cmd ~= config.nimble.flags;
        
        // Run from nimble file directory
        string workDir = dirName(nimbleFile);
        
        auto res = execute(cmd, null, std.process.Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            structuredLog.error("dependency_installation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("dependencies_installed_successfully").emit();
        return true;
    }
    
    private string[] buildNimbleCommand(string nimbleFile, in NimConfig config, in Target target)
    {
        string[] cmd = ["nimble"];
        
        // Custom tasks if specified
        if (!config.nimble.tasks.empty)
        {
            cmd ~= config.nimble.tasks;
        }
        else
        {
            // Default to build task
            cmd ~= "build";
        }
        
        // Add nimble flags
        cmd ~= config.nimble.flags;
        
        // Verbose
        if (config.verbose)
            cmd ~= "--verbose";
        
        // Pass through nim compiler options via nimble
        if (config.release)
            cmd ~= "-d:release";
        
        if (config.danger)
            cmd ~= "-d:danger";
        
        // Backend selection
        final switch (config.backend)
        {
            case NimBackend.C:
                // Default, no flag needed
                break;
            case NimBackend.Cpp:
                cmd ~= "--backend:cpp";
                break;
            case NimBackend.Js:
                cmd ~= "--backend:js";
                break;
            case NimBackend.ObjC:
                cmd ~= "--backend:objc";
                break;
        }
        
        return cmd;
    }
    
    private string findNimbleOutput(
        NimbleData nimbleData,
        in NimConfig config,
        in WorkspaceConfig workspace
    )
    {
        // Default nimble output locations
        string[] searchPaths = [
            ".",
            buildPath("bin", nimbleData.name),
            buildPath("build", nimbleData.name),
            nimbleData.name
        ];
        
        // Add platform-specific extensions
        version(Windows)
        {
            string[] withExt = searchPaths.map!(p => p ~ ".exe").array;
            searchPaths ~= withExt;
        }
        
        foreach (path; searchPaths)
        {
            if (exists(path))
                return path;
        }
        
        return "";
    }
    
    private string findAlternativeOutput(
        NimbleData nimbleData,
        in NimConfig config,
        in WorkspaceConfig workspace
    )
    {
        // Check workspace output directory
        string outputDir = workspace.options.outputDir;
        string baseName = nimbleData.name.empty ? "app" : nimbleData.name;
        
        version(Windows)
            baseName ~= ".exe";
        
        string path = buildPath(outputDir, baseName);
        if (exists(path))
            return path;
        
        return "";
    }
}

