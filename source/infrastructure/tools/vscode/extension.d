module infrastructure.tools.vscode.extension;

import std.process : execute;
import std.file : exists, getcwd;
import std.path : buildPath, absolutePath, dirName;
import std.string : strip, split;
import infrastructure.utils.logging.logger;

/// VS Code Extension Manager
/// Handles automatic installation of bldr's VS Code extension
struct VSCodeExtension
{
    private static immutable string EXTENSION_NAME = "builder-lang-2.0.0.vsix";
    
    /// Install the bldr VS Code extension
    /// Returns: true if installation succeeded, false otherwise
    static bool install()
    {
        Logger.info("Installing bldr VS Code extension...");
        
        auto vsixPath = findExtensionVSIX();
        if (vsixPath.length == 0)
        {
            Logger.error("Could not find " ~ EXTENSION_NAME);
            Logger.error("Expected locations:");
            foreach (path; getSearchPaths())
                Logger.error("  - " ~ path);
            return false;
        }
        
        Logger.info("Found extension at: " ~ vsixPath);
        
        if (!checkVSCodeAvailable())
            return false;
        
        return installExtension(vsixPath);
    }
    
    /// Check if extension is already installed
    static bool isInstalled()
    {
        auto result = execute(["code", "--list-extensions"]);
        if (result.status != 0)
            return false;
        
        import std.algorithm : canFind;
        return result.output.canFind("builder-lang");
    }
    
    private static string findExtensionVSIX()
    {
        foreach (path; getSearchPaths())
        {
            if (exists(path))
                return absolutePath(path);
        }
        return "";
    }
    
    private static string[] getSearchPaths()
    {
        string currentDir = getcwd();
        
        return [
            // New location: tools/vscode/
            buildPath(currentDir, "tools", "vscode", EXTENSION_NAME),
            buildPath(currentDir, EXTENSION_NAME),
            // Legacy location for backwards compatibility
            buildPath(currentDir, "extension-vscode", EXTENSION_NAME),
            buildPath(dirName(currentDir), "tools", "vscode", EXTENSION_NAME),
            // If running from bin/ directory
            buildPath(dirName(currentDir), "..", "tools", "vscode", EXTENSION_NAME),
        ];
    }
    
    private static bool checkVSCodeAvailable()
    {
        auto checkResult = execute(["code", "--version"]);
        if (checkResult.status != 0)
        {
            Logger.error("VS Code CLI 'code' command not found");
            Logger.error("Please install VS Code and ensure 'code' is in your PATH");
            Logger.error("Visit: https://code.visualstudio.com/");
            return false;
        }
        
        Logger.info("Found VS Code version: " ~ checkResult.output.strip.split('\n')[0]);
        return true;
    }
    
    private static bool installExtension(string vsixPath)
    {
        Logger.info("Installing extension...");
        auto installResult = execute(["code", "--install-extension", vsixPath]);
        
        if (installResult.status != 0)
        {
            Logger.error("Failed to install extension");
            Logger.error(installResult.output);
            return false;
        }
        
        Logger.success("Extension installed successfully!");
        Logger.info("Reload VS Code window to activate: Cmd+Shift+P → 'Developer: Reload Window'");
        return true;
    }
}

