module languages.scripting.python.managers.conda;

import std.process;
import std.file;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.python.managers.base;
import languages.scripting.python.tooling.detection : ToolDetection;
alias PyTools = ToolDetection;
import infrastructure.utils.logging;

/// Conda package manager
class CondaManager : PackageManager
{
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        if (!exists(file))
        {
            result.error = "Environment file not found: " ~ file;
            return result;
        }
        
        structuredLog.info("installing_conda_environment_from_").field("detail", "Installing conda environment from " ~ file).emit();
        
        StopWatch sw;
        sw.start();
        
        auto res = execute(["conda", "env", "create", "-f", file]);
        
        sw.stop();
        result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
        
        if (res.status != 0)
        {
            result.error = "conda env create failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        structuredLog.info("conda_environment_created_in_2fsformatre").emit();
        
        return result;
    }
    
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        string[] cmd = ["conda", "install", "-y"] ~ packages;
        
        structuredLog.info("installing_packages_with_conda_").field("detail", "Installing packages with conda: " ~ packages.join(", ")).emit();
        
        StopWatch sw;
        sw.start();
        
        auto res = execute(cmd);
        
        sw.stop();
        result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
        
        if (res.status != 0)
        {
            result.error = "conda install failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.installedPackages = packages;
        structuredLog.info("packages_installed_in_2fsformatresulttim").emit();
        
        return result;
    }
    
    bool isAvailable()
    {
        return PyTools.isCondaAvailable();
    }
    
    string name() const
    {
        return "conda";
    }
    
    string getVersion()
    {
        auto res = execute(["conda", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

