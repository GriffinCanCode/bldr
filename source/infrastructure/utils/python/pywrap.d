module infrastructure.utils.python.pywrap;

import std.stdio;
import std.file;
import std.path;
import std.array;
import std.algorithm;
import infrastructure.utils.python.pycheck;

/// Configuration for Python executable wrapper
struct WrapperConfig
{
    string mainFile;        // Main Python file to execute
    string outputPath;      // Where to write wrapper
    string projectRoot;     // Project root for PYTHONPATH
    bool hasMain;           // Main file has main() function
    bool hasMainGuard;      // Main file has if __name__ == "__main__"
    bool isExecutable;      // Main file is already executable
}

/// Generates smart Python executable wrappers with proper entry point detection
class PyWrapperGenerator
{
    /// Generate an executable wrapper for a Python project
    static void generate(WrapperConfig config)
    {
        string wrapper = buildWrapper(config);
        
        // Ensure output directory exists
        auto outputDir = dirName(config.outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
            
        // Write wrapper
        std.file.write(config.outputPath, wrapper);
        
        // Make executable on POSIX systems
        version (Posix)
        {
            import core.sys.posix.sys.stat;
            import std.string : toStringz;
            if (exists(config.outputPath))
            {
                chmod(toStringz(config.outputPath), 
                      S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH);
            }
        }
    }
    
    /// Build wrapper script content based on entry point detection
    private static string buildWrapper(WrapperConfig config)
    {
        auto moduleName = baseName(config.mainFile, ".py");
        auto moduleDir = dirName(config.mainFile);
        
        // Calculate relative path from output to project root
        auto outputDir = absolutePath(dirName(config.outputPath));
        auto projectRoot = absolutePath(config.projectRoot);
        auto relPath = relativePath(projectRoot, outputDir);
        
        // Build wrapper components
        string wrapper = "#!/usr/bin/env python3\n";
        wrapper ~= "\"\"\"Auto-generated executable wrapper by Builder.\"\"\"\n\n";
        
        // Setup PYTHONPATH properly
        wrapper ~= "import sys\n";
        wrapper ~= "import os\n\n";
        wrapper ~= "# Add project root to Python path\n";
        wrapper ~= "project_root = os.path.join(os.path.dirname(__file__), " 
                   ~ escapeString(relPath) ~ ")\n";
        wrapper ~= "project_root = os.path.abspath(project_root)\n";
        wrapper ~= "if project_root not in sys.path:\n";
        wrapper ~= "    sys.path.insert(0, project_root)\n\n";
        
        // Handle different entry point patterns
        if (config.isExecutable)
        {
            // File has if __name__ == "__main__" - execute as __main__ module
            wrapper ~= "# Execute module with main guard using runpy\n";
            wrapper ~= "if __name__ == '__main__':\n";
            wrapper ~= "    import runpy\n";
            
            auto modulePath = config.mainFile;
            wrapper ~= "    runpy.run_path(" ~ escapeString(modulePath) ~ ", run_name='__main__')\n";
        }
        else if (config.hasMain)
        {
            // File has main() function - import and call it
            wrapper ~= "# Import and call main() function\n";
            wrapper ~= "if __name__ == '__main__':\n";
            
            if (moduleDir.empty || moduleDir == ".")
                wrapper ~= "    from " ~ moduleName ~ " import main\n";
            else
            {
                auto importPath = moduleDir.replace("/", ".").replace("\\", ".");
                wrapper ~= "    from " ~ importPath ~ "." ~ moduleName ~ " import main\n";
            }
            
            wrapper ~= "    main()\n";
        }
        else
        {
            // No standard entry point - execute as module
            wrapper ~= "# Execute module directly\n";
            wrapper ~= "if __name__ == '__main__':\n";
            
            auto modulePath = config.mainFile;
            wrapper ~= "    import runpy\n";
            wrapper ~= "    runpy.run_path(" ~ escapeString(modulePath) ~ ", run_name='__main__')\n";
        }
        
        return wrapper;
    }
    
    /// Escape string for Python literal
    private static string escapeString(string s)
    {
        return "'" ~ s.replace("\\", "\\\\").replace("'", "\\'") ~ "'";
    }
}

