module languages.scripting.php.tooling.packagers.phar;

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

/// Native PHP PHAR packager
class NativePharPackager : Packager
{
    PackageResult createPackage(
        const string[] sources,
        PHARConfig config,
        const string projectRoot
    )
    {
        PackageResult result;
        
        // Generate PHP script to create PHAR
        string pharScript = generatePharScript(config, sources, projectRoot);
        
        // Write script to temporary file
        string scriptPath = buildPath(projectRoot, ".build_phar.php");
        std.file.write(scriptPath, pharScript);
        
        // Execute script
        string[] cmd = ["php", scriptPath];
        
        structuredLog.info("creating_phar_with_native_php_phar_class").emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        result.output = res.output;
        
        // Clean up script
        try
        {
            remove(scriptPath);
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_cleanup_script_file_").field("detail", "Failed to cleanup script file: " ~ e.msg).emit();
        }
        
        if (res.status == 0)
        {
            result.success = true;
            
            string outputFile = config.outputFile;
            if (outputFile.empty)
                outputFile = "app.phar";
            
            string pharPath = buildPath(projectRoot, outputFile);
            if (exists(pharPath))
            {
                result.artifacts ~= pharPath;
                result.artifactSize = getSize(pharPath);
                structuredLog.info("phar_created_").field("detail", "PHAR created: " ~ pharPath ~ 
                          " (" ~ (result.artifactSize / 1024).to!string ~ " KB)").emit();
            }
        }
        else
        {
            result.success = false;
            result.errors ~= "PHAR creation failed: " ~ res.output;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        // Check if phar.readonly is off
        auto res = execute(["php", "-r", "echo ini_get('phar.readonly');"]);
        if (res.status == 0)
        {
            return res.output.strip == "0" || res.output.strip.empty;
        }
        return true; // Assume available
    }
    
    string name() const
    {
        return "Native PHAR";
    }
    
    string getVersion()
    {
        auto res = execute(["php", "-r", "echo Phar::apiVersion();"]);
        if (res.status == 0)
            return res.output.strip;
        
        return "unknown";
    }
    
    /// Generate PHP script to create PHAR
    private string generatePharScript(
        PHARConfig config,
        const string[] sources,
        const string projectRoot
    )
    {
        string script = "<?php\n";
        script ~= "// Auto-generated PHAR build script\n\n";
        
        // Check phar.readonly
        script ~= "if (ini_get('phar.readonly')) {\n";
        script ~= "    echo \"Error: phar.readonly is enabled. Run with: php -d phar.readonly=0\\n\";\n";
        script ~= "    exit(1);\n";
        script ~= "}\n\n";
        
        // Output file
        string outputFile = config.outputFile;
        if (outputFile.empty)
            outputFile = "app.phar";
        
        script ~= "$pharFile = '" ~ outputFile ~ "';\n\n";
        
        // Remove existing PHAR
        script ~= "if (file_exists($pharFile)) {\n";
        script ~= "    unlink($pharFile);\n";
        script ~= "}\n\n";
        
        // Create PHAR
        script ~= "$phar = new Phar($pharFile);\n";
        script ~= "$phar->startBuffering();\n\n";
        
        // Add directories
        if (!config.directories.empty)
        {
            foreach (dir; config.directories)
            {
                script ~= "$phar->buildFromDirectory('" ~ dir ~ "');\n";
            }
        }
        else
        {
            // Add all PHP files from sources
            script ~= "$phar->buildFromDirectory('.');\n";
        }
        
        // Set default stub
        if (!config.stub.empty && exists(config.stub))
        {
            script ~= "$stub = file_get_contents('" ~ config.stub ~ "');\n";
            script ~= "$phar->setStub($stub);\n";
        }
        else if (!config.entryPoint.empty)
        {
            script ~= "$phar->setDefaultStub('" ~ config.entryPoint ~ "');\n";
        }
        else if (!sources.empty)
        {
            script ~= "$phar->setDefaultStub('" ~ sources[0] ~ "');\n";
        }
        
        // Compression
        if (config.compression == "gz")
        {
            script ~= "$phar->compressFiles(Phar::GZ);\n";
        }
        else if (config.compression == "bz2")
        {
            script ~= "$phar->compressFiles(Phar::BZ2);\n";
        }
        
        // Signature
        if (config.signature == "sha256")
        {
            script ~= "$phar->setSignatureAlgorithm(Phar::SHA256);\n";
        }
        else if (config.signature == "sha512")
        {
            script ~= "$phar->setSignatureAlgorithm(Phar::SHA512);\n";
        }
        
        script ~= "\n$phar->stopBuffering();\n\n";
        script ~= "echo \"PHAR created successfully: $pharFile\\n\";\n";
        script ~= "echo \"Size: \" . filesize($pharFile) . \" bytes\\n\";\n";
        
        return script;
    }
}

