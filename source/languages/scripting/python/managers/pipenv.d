module languages.scripting.python.managers.pipenv;

import std.process;
import std.string;
import std.conv;
import languages.scripting.python.managers.base;
import languages.scripting.python.tooling.detection : ToolDetection;
alias PyTools = ToolDetection;
import infrastructure.utils.logging;

/// Pipenv package manager
class PipenvManager : PackageManager
{
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false)
    {
        InstallResult result;
        result.error = "Pipenv uses Pipfile, use installPackages instead";
        return result;
    }
    
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        structuredLog.info("installing_with_pipenv").emit();
        
        StopWatch sw;
        sw.start();
        
        auto res = execute(["pipenv", "install"]);
        
        sw.stop();
        result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
        
        if (res.status != 0)
        {
            result.error = "pipenv install failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        structuredLog.info("pipenv_installation_completed_in_2fsform").emit();
        
        return result;
    }
    
    bool isAvailable()
    {
        return PyTools.isPipenvAvailable();
    }
    
    string name() const
    {
        return "pipenv";
    }
    
    string getVersion()
    {
        auto res = execute(["pipenv", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

