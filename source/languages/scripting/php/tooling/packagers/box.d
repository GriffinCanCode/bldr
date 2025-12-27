module languages.scripting.php.tooling.packagers.box;

import languages.scripting.php.tooling.packagers.base;
import languages.scripting.php.core.config;
import languages.scripting.php.tooling.detection;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import infrastructure.utils.logging;

/// Box PHAR packager (modern, recommended)
class BoxPackager : Packager
{
    PackageResult createPackage(
        const string[] sources,
        PHARConfig config,
        const string projectRoot
    )
    {
        PackageResult result;
        
        string boxCmd = PHPTools.getBoxCommand();
        if (boxCmd.empty)
        {
            result.success = false;
            result.errors ~= "Box not found. Install: composer require --dev humbug/box";
            return result;
        }
        
        // Check if box.json exists, otherwise create one
        string boxConfig = config.boxConfig;
        if (boxConfig.empty)
            boxConfig = buildPath(projectRoot, "box.json");
        
        if (!exists(boxConfig))
        {
            structuredLog.info("no_boxjson_found_creating_default_config").emit();
            createDefaultConfig(boxConfig, config, sources, projectRoot);
        }
        
        // Run box compile
        string[] cmd = [boxCmd, "compile"];
        
        if (exists(boxConfig))
        {
            cmd ~= ["--config", boxConfig];
        }
        
        // Working directory
        cmd ~= ["--working-dir", projectRoot];
        
        structuredLog.info("running_box_").field("detail", "Running Box: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        if (res.status == 0)
        {
            result.success = true;
            
            // Determine output file
            string outputFile = config.outputFile;
            if (outputFile.empty)
                outputFile = "app.phar"; // Box default
            
            string pharPath = buildPath(projectRoot, outputFile);
            if (exists(pharPath))
            {
                result.artifacts ~= pharPath;
                result.artifactSize = getSize(pharPath);
                structuredLog.info("phar_created_").field("detail", "PHAR created: " ~ pharPath ~ " (" ~ (result.artifactSize / 1024).to!string ~ " KB)").emit();
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "Box compilation failed: " ~ res.output;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return PHPTools.isBoxAvailable();
    }
    
    string name() const
    {
        return "Box";
    }
    
    string getVersion()
    {
        string cmd = PHPTools.getBoxCommand();
        if (cmd.empty)
            return "not installed";
        
        auto res = execute([cmd, "--version"]);
        if (res.status == 0)
            return res.output.strip;
        
        return "unknown";
    }
    
    /// Create default box.json configuration
    private void createDefaultConfig(
        string configPath,
        PHARConfig config,
        const string[] sources,
        const string projectRoot
    )
    {
        JSONValue boxConfig = parseJSON("{}");
        
        // Main entry point
        if (!config.entryPoint.empty)
        {
            boxConfig["main"] = config.entryPoint;
        }
        else if (!sources.empty)
        {
            boxConfig["main"] = sources[0];
        }
        
        // Output file
        if (!config.outputFile.empty)
        {
            boxConfig["output"] = config.outputFile;
        }
        else
        {
            boxConfig["output"] = "app.phar";
        }
        
        // Compression
        if (config.compression != "none")
        {
            if (config.compression == "gz")
                boxConfig["compression"] = "GZ";
            else if (config.compression == "bz2")
                boxConfig["compression"] = "BZ2";
        }
        
        // Signature
        if (!config.signature.empty && config.signature != "none")
        {
            boxConfig["algorithm"] = config.signature.toUpper;
        }
        
        // Directories to include
        if (!config.directories.empty)
        {
            boxConfig["directories"] = config.directories;
        }
        else
        {
            // Default: include src, lib directories
            string[] dirs;
            if (exists(buildPath(projectRoot, "src")))
                dirs ~= "src";
            if (exists(buildPath(projectRoot, "lib")))
                dirs ~= "lib";
            if (!dirs.empty)
                boxConfig["directories"] = dirs;
        }
        
        // Files to include
        if (!config.files.empty)
        {
            boxConfig["files"] = config.files;
        }
        
        // Exclude patterns
        if (!config.exclude.empty)
        {
            JSONValue[] excludePatterns;
            foreach (pattern; config.exclude)
            {
                excludePatterns ~= JSONValue(pattern);
            }
            boxConfig["blacklist"] = excludePatterns;
        }
        else
        {
            // Default exclusions
            boxConfig["blacklist"] = [
                "tests",
                "Tests",
                ".git",
                ".gitignore",
                ".github",
                "*.md",
                "phpunit.xml*",
                "composer.json",
                "composer.lock"
            ];
        }
        
        // Include dev dependencies
        if (!config.includeDev)
        {
            boxConfig["exclude-dev-files"] = true;
        }
        
        // Optimize
        if (config.optimize)
        {
            boxConfig["compactors"] = [
                "KevinGH\\Box\\Compactor\\Php",
                "KevinGH\\Box\\Compactor\\PhpScoper"
            ];
        }
        
        // Write configuration
        std.file.write(configPath, boxConfig.toPrettyString());
        structuredLog.info("created_boxjson_configuration_").field("detail", "Created box.json configuration: " ~ configPath).emit();
    }
}

