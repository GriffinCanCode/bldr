module infrastructure.tools.vscode.extension;

import std.process : execute;
import std.file : exists, getcwd;
import std.path : buildPath, absolutePath, dirName;
import std.string : strip, split;
import infrastructure.utils.logging;

/// VS Code Extension Manager
/// Handles automatic installation of bldr's VS Code extension
struct VSCodeExtension
{
    private static immutable string EXTENSION_NAME = "builder-lang-2.0.0.vsix";
    
    /// Install the bldr VS Code extension
    /// Returns: true if installation succeeded, false otherwise
    static bool install()
    {
        structuredLog.info("installing_bldr_vs_code_extension").emit();
        
        auto vsixPath = findExtensionVSIX();
        if (vsixPath.length == 0)
        {
            structuredLog.error("could_not_find_").field("detail", "Could not find " ~ EXTENSION_NAME).emit();
            structuredLog.error("expected_locations").emit();
            foreach (path; getSearchPaths())
                structuredLog.error("___").field("detail", "  - " ~ path).emit();
            return false;
        }
        
        structuredLog.info("found_extension_at_").field("detail", "Found extension at: " ~ vsixPath).emit();
        
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
            structuredLog.error("vs_code_cli_code_command_not_found").emit();
            structuredLog.error("please_install_vs_code_and_ensure_code_i").emit();
            structuredLog.error("visit_httpscodevisualstudiocom").emit();
            return false;
        }
        
        structuredLog.info("found_vs_code_version_").field("detail", "Found VS Code version: " ~ checkResult.output.strip.split('\n')[0]).emit();
        return true;
    }
    
    private static bool installExtension(string vsixPath)
    {
        structuredLog.info("installing_extension").emit();
        auto installResult = execute(["code", "--install-extension", vsixPath]);
        
        if (installResult.status != 0)
        {
            structuredLog.error("failed_to_install_extension").emit();
            structuredLog.error("log_event").field("message", installResult.output).emit();
            return false;
        }
        
        structuredLog.info("extension_installed_successfully").emit();
        structuredLog.info("reload_vs_code_window_to_activate_cmdshi").emit();
        return true;
    }
}

