module languages.scripting.python.managers.poetry;

import std.process : Config;
import infrastructure.utils.security : execute;  // SECURITY: Auto-migrated
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.python.managers.base;
import languages.scripting.python.tooling.detection : ToolDetection;
alias PyTools = ToolDetection;
import infrastructure.utils.logging;

/// Poetry package manager
class PoetryManager : PackageManager
{
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false)
    {
        InstallResult result;
        result.error = "Poetry uses pyproject.toml, use installPackages instead";
        return result;
    }
    
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        if (packages.empty)
        {
            // Install from pyproject.toml
            structuredLog.info("installing_dependencies_with_poetry").emit();
            
            StopWatch sw;
            sw.start();
            
            auto res = execute(["poetry", "install"]);
            
            sw.stop();
            result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
            
            if (res.status != 0)
            {
                result.error = "poetry install failed: " ~ res.output;
                return result;
            }
            
            result.success = true;
        }
        else
        {
            // Add and install specific packages
            structuredLog.info("installing_packages_with_poetry_").field("detail", "Installing packages with poetry: " ~ packages.join(", ")).emit();
            
            StopWatch sw;
            sw.start();
            
            foreach (pkg; packages)
            {
                auto cmd = ["poetry", "add", pkg];
                auto res = execute(cmd);
                
                if (res.status != 0)
                {
                    result.error = "poetry add failed for " ~ pkg ~ ": " ~ res.output;
                    return result;
                }
                
                result.installedPackages ~= pkg;
            }
            
            sw.stop();
            result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
            result.success = true;
        }
        
        structuredLog.info("poetry_installation_completed_in_2fsform").emit();
        return result;
    }
    
    bool isAvailable()
    {
        return PyTools.isPoetryAvailable();
    }
    
    string name() const
    {
        return "poetry";
    }
    
    string getVersion()
    {
        auto res = execute(["poetry", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

