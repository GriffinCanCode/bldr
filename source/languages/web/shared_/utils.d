module languages.web.shared_.utils;

import std.process;
import std.file;
import std.path;
import std.json;
import std.string;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;

/// Find package.json in source tree
string findPackageJson(const(string[]) sources)
{
    if (sources.empty)
        return "";
    
    string dir = dirName(sources[0]);
    
    while (dir != "/" && dir.length > 1)
    {
        string packagePath = buildPath(dir, "package.json");
        if (exists(packagePath))
            return packagePath;
        
        dir = dirName(dir);
    }
    
    return "";
}

/// Detect test command from package.json
string[] detectTestCommand(string packageJsonPath)
{
    try
    {
        auto content = readText(packageJsonPath);
        auto json = parseJSON(content);
        
        if ("scripts" in json && "test" in json["scripts"].object)
        {
            string testScript = json["scripts"]["test"].str;
            if (testScript != "echo \"Error: no test specified\" && exit 1")
            {
                return ["npm", "test"];
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_packagejson_").field("detail", "Failed to parse package.json: " ~ e.msg).emit();
    }
    
    return [];
}

/// Install npm dependencies  
void installDependencies(const(string[]) sources, string packageManager)
{
    import std.file : getcwd;
    
    // First check current directory for package.json
    string packageJsonPath = buildPath(getcwd(), "package.json");
    
    // If not found in current directory, try to find it relative to sources
    if (!exists(packageJsonPath))
    {
        packageJsonPath = findPackageJson(sources);
    }
    
    if (packageJsonPath.empty || !exists(packageJsonPath))
    {
        structuredLog.warning("no_packagejson_found_skipping_dependency").emit();
        return;
    }
    
    string packageDir = dirName(packageJsonPath);
    
    // Check if node_modules already exists and is recent
    string nodeModulesPath = buildPath(packageDir, "node_modules");
    if (exists(nodeModulesPath) && isDir(nodeModulesPath))
    {
        structuredLog.debug_("dependencies_already_installed_skipping").emit();
        return;
    }
    
    structuredLog.info("installing_dependencies_with_").field("detail", "Installing dependencies with " ~ packageManager ~ "...").emit();
    
    string[] cmd = [packageManager, "install"];
    auto res = execute(cmd, null, std.process.Config.none, size_t.max, packageDir);
    
    if (res.status != 0)
    {
        structuredLog.warning("failed_to_install_dependencies_").field("detail", "Failed to install dependencies: " ~ res.output).emit();
    }
    else
    {
        structuredLog.info("dependencies_installed_successfully").emit();
    }
}

