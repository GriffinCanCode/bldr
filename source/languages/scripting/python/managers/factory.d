module languages.scripting.python.managers.factory;

import std.file;
import std.path;
import std.algorithm;
import std.string;
import languages.scripting.python.core.config;
import languages.scripting.python.managers.base;
import languages.scripting.python.managers.pip;
import languages.scripting.python.managers.uv;
import languages.scripting.python.managers.poetry;
import languages.scripting.python.managers.pdm;
import languages.scripting.python.managers.hatch;
import languages.scripting.python.managers.conda;
import languages.scripting.python.managers.pipenv;
import languages.scripting.python.tooling.detection : ToolDetection;
import infrastructure.utils.logging : structuredLog;
alias PyTools = ToolDetection;

/// Factory for creating package managers
class PackageManagerFactory
{
    /// Create package manager based on type
    static PackageManager create(PyPackageManager type, string pythonCmd = "python3", string venvPath = "")
    {
        final switch (type)
        {
            case PyPackageManager.Auto:
                return createAuto(pythonCmd, venvPath);
            case PyPackageManager.Pip:
                return new PipManager(pythonCmd, venvPath);
            case PyPackageManager.Uv:
                return new UvManager(pythonCmd, venvPath);
            case PyPackageManager.Poetry:
                return new PoetryManager();
            case PyPackageManager.PDM:
                return new PDMManager();
            case PyPackageManager.Hatch:
                return new HatchManager();
            case PyPackageManager.Conda:
                return new CondaManager();
            case PyPackageManager.Pipenv:
                return new PipenvManager();
            case PyPackageManager.None:
                return new NullManager();
        }
    }
    
    /// Auto-detect best available package manager
    private static PackageManager createAuto(string pythonCmd, string venvPath)
    {
        // Priority: uv (fastest) > poetry > pip
        
        // Check for uv (ultra-fast, Rust-based)
        if (PyTools.isUvAvailable())
            return new UvManager(pythonCmd, venvPath);
        
        // Check for poetry (if pyproject.toml with poetry config exists)
        if (PyTools.isPoetryAvailable())
        {
            // Only use poetry if we detect it's actually being used
            // Otherwise fallback to pip
        }
        
        // Default to pip
        if (PyTools.isPipAvailable(pythonCmd))
            return new PipManager(pythonCmd, venvPath);
        
        // Fallback to null manager
        return new NullManager();
    }
    
    /// Detect package manager from project structure
    static PyPackageManager detectFromProject(string projectDir)
    {
        // Check for poetry
        string pyprojectPath = buildPath(projectDir, "pyproject.toml");
        if (exists(pyprojectPath))
        {
            try
            {
                auto content = readText(pyprojectPath);
                if (content.canFind("[tool.poetry]"))
                    return PyPackageManager.Poetry;
                if (content.canFind("[tool.pdm]"))
                    return PyPackageManager.PDM;
                if (content.canFind("[tool.hatch]"))
                    return PyPackageManager.Hatch;
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_python_package_manager_").field("detail", "Failed to detect Python package manager: " ~ e.msg).emit();
            }
        }
        
        // Check for Pipfile
        if (exists(buildPath(projectDir, "Pipfile")))
            return PyPackageManager.Pipenv;
        
        // Check for conda
        if (exists(buildPath(projectDir, "environment.yml")) || 
            exists(buildPath(projectDir, "environment.yaml")))
            return PyPackageManager.Conda;
        
        // Check for uv
        if (PyTools.isUvAvailable())
            return PyPackageManager.Uv;
        
        // Default to pip
        return PyPackageManager.Pip;
    }
}

