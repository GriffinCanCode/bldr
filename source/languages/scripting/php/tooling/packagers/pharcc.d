module languages.scripting.php.tooling.packagers.pharcc;

import languages.scripting.php.tooling.packagers.base;
import languages.scripting.php.core.config;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// Pharcc packager - compile PHP to standalone binary
class PharccPackager : Packager
{
    PackageResult createPackage(
        const string[] sources,
        PHARConfig config,
        const string projectRoot
    )
    {
        PackageResult result;
        
        if (!isAvailable())
        {
            result.success = false;
            result.errors ~= "pharcc not found. Install: composer require --dev macfja/pharcc";
            return result;
        }
        
        string pharccCmd = findPharccCommand();
        
        string[] cmd = [pharccCmd];
        
        // Input file (entry point)
        string entryPoint = config.entryPoint;
        if (entryPoint.empty && !sources.empty)
            entryPoint = sources[0];
        
        if (entryPoint.empty)
        {
            result.success = false;
            result.errors ~= "No entry point specified for pharcc";
            return result;
        }
        
        cmd ~= entryPoint;
        
        // Output file
        string outputFile = config.outputFile;
        if (outputFile.empty)
        {
            outputFile = baseName(entryPoint, ".php");
        }
        
        cmd ~= ["--output", outputFile];
        
        // Include directories
        foreach (dir; config.directories)
        {
            if (exists(buildPath(projectRoot, dir)))
                cmd ~= ["--add", buildPath(projectRoot, dir)];
        }
        
        structuredLog.info("running_pharcc_").field("detail", "Running pharcc: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        if (res.status == 0)
        {
            result.success = true;
            
            string binaryPath = buildPath(projectRoot, outputFile);
            if (exists(binaryPath))
            {
                result.artifacts ~= binaryPath;
                result.artifactSize = getSize(binaryPath);
                
                // Make executable on Unix
                version(Posix)
                {
                    // Validate path before using it with external command
                    if (!SecurityValidator.isPathSafe(binaryPath))
                    {
                        structuredLog.warning("unsafe_binary_path_detected_skipping_chm").field("detail", "Unsafe binary path detected, skipping chmod: " ~ binaryPath).emit();
                    }
                    else
                    {
                        // Use safe array form instead of executeShell
                        auto chmodResult = execute(["chmod", "+x", binaryPath]);
                        if (chmodResult.status != 0)
                        {
                            structuredLog.warning("failed_to_make_binary_executable_").field("detail", "Failed to make binary executable: " ~ chmodResult.output).emit();
                        }
                    }
                }
                
                structuredLog.info("standalone_binary_created_").field("detail", "Standalone binary created: " ~ binaryPath ~ 
                          " (" ~ (result.artifactSize / (1024 * 1024)).to!string ~ " MB)").emit();
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "pharcc compilation failed: " ~ res.output;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        // Check vendor/bin
        if (exists(buildPath("vendor", "bin", "pharcc")))
            return true;
        
        // Check global
        auto res = execute(["pharcc", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "pharcc";
    }
    
    string getVersion()
    {
        string cmd = findPharccCommand();
        if (cmd.empty)
            return "not installed";
        
        auto res = execute([cmd, "--version"]);
        if (res.status == 0)
            return res.output.strip;
        
        return "unknown";
    }
    
    private string findPharccCommand()
    {
        string vendorBin = buildPath("vendor", "bin", "pharcc");
        if (exists(vendorBin))
            return vendorBin;
        
        auto res = execute(["which", "pharcc"]);
        if (res.status == 0)
            return "pharcc";
        
        return "";
    }
}

