module languages.scripting.python.managers.uv;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.python.managers.base;
import languages.scripting.python.managers.environments;
import languages.scripting.python.tooling.detection : ToolDetection;
alias PyTools = ToolDetection;
import infrastructure.utils.logging;

/// UV package manager (ultra-fast, Rust-based)
class UvManager : PackageManager
{
    private string pythonCmd;
    private string venvPath;
    
    this(string pythonCmd = "python3", string venvPath = "")
    {
        this.pythonCmd = pythonCmd;
        this.venvPath = venvPath;
    }
    
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        if (!exists(file))
        {
            result.error = "Requirements file not found: " ~ file;
            return result;
        }
        
        string[] cmd = ["uv", "pip", "install", "-r", file];
        if (upgrade)
            cmd ~= "--upgrade";
        
        structuredLog.info("installing_dependencies_from_").field("detail", "Installing dependencies from " ~ file ~ " using uv (fast!)").emit();
        
        StopWatch sw;
        sw.start();
        
        auto env = venvPath.empty ? null : getVenvEnv();
        auto res = execute(cmd, env);
        
        sw.stop();
        result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
        
        if (res.status != 0)
        {
            result.error = "uv install failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        structuredLog.info("log_event").field("message", "Dependencies installed in %.2fs (uv is ~10-100x faster!)".format(result.timeSeconds)).emit();
        
        return result;
    }
    
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false)
    {
        import std.datetime.stopwatch : StopWatch;
        
        InstallResult result;
        
        string[] cmd = ["uv", "pip", "install"];
        if (upgrade)
            cmd ~= "--upgrade";
        if (editable)
            cmd ~= "-e";
        cmd ~= packages;
        
        structuredLog.info("installing_packages_with_uv_").field("detail", "Installing packages with uv: " ~ packages.join(", ")).emit();
        
        StopWatch sw;
        sw.start();
        
        auto env = venvPath.empty ? null : getVenvEnv();
        auto res = execute(cmd, env);
        
        sw.stop();
        result.timeSeconds = sw.peek().total!"msecs" / 1000.0;
        
        if (res.status != 0)
        {
            result.error = "uv install failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.installedPackages = packages;
        structuredLog.info("packages_installed_in_2fsformatresulttim").emit();
        
        return result;
    }
    
    bool isAvailable()
    {
        return PyTools.isUvAvailable();
    }
    
    string name() const
    {
        return "uv";
    }
    
    string getVersion()
    {
        auto res = execute(["uv", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    private string[string] getVenvEnv()
    {
        return VirtualEnv.getVenvEnv(venvPath);
    }
}

