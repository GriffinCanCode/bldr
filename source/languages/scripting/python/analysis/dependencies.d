module languages.scripting.python.analysis.dependencies;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.json;
import infrastructure.utils.logging;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Python package dependency
struct PythonDependency
{
    string name;
    string version_;  // Can be version specifier like ">=1.0,<2.0"
    string[] extras;  // Extra features like "dev", "test"
    bool optional;
}

/// Dependency file type
enum DependencyFileType
{
    /// requirements.txt
    Requirements,
    /// pyproject.toml
    Pyproject,
    /// setup.py
    Setup,
    /// Pipfile
    Pipfile,
    /// environment.yml (conda)
    CondaEnv
}

/// Dependency analyzer - parses Python dependency files
class DependencyAnalyzer
{
    /// Find dependency files in project directory
    static string[] findDependencyFiles(string projectDir)
    {
        string[] files;
        
        // Check for pyproject.toml
        string pyprojectPath = buildPath(projectDir, "pyproject.toml");
        if (exists(pyprojectPath))
            files ~= pyprojectPath;
        
        // Check for requirements files
        string[] reqFiles = [
            "requirements.txt",
            "requirements-dev.txt",
            "requirements-test.txt",
            "dev-requirements.txt"
        ];
        
        foreach (reqFile; reqFiles)
        {
            string reqPath = buildPath(projectDir, reqFile);
            if (exists(reqPath))
                files ~= reqPath;
        }
        
        // Check for setup.py
        string setupPath = buildPath(projectDir, "setup.py");
        if (exists(setupPath))
            files ~= setupPath;
        
        // Check for Pipfile
        string pipfilePath = buildPath(projectDir, "Pipfile");
        if (exists(pipfilePath))
            files ~= pipfilePath;
        
        // Check for conda environment file
        string condaEnvPath = buildPath(projectDir, "environment.yml");
        if (!exists(condaEnvPath))
            condaEnvPath = buildPath(projectDir, "environment.yaml");
        if (exists(condaEnvPath))
            files ~= condaEnvPath;
        
        return files;
    }
    
    /// Detect dependency file type
    static DependencyFileType detectFileType(string filePath)
    {
        string basename = baseName(filePath);
        
        if (basename == "pyproject.toml")
            return DependencyFileType.Pyproject;
        else if ((() @trusted => SIMDStrings.startsWith(basename, "requirements") || SIMDStrings.endsWith(basename, "requirements.txt"))())
            return DependencyFileType.Requirements;
        else if (basename == "setup.py")
            return DependencyFileType.Setup;
        else if (basename == "Pipfile")
            return DependencyFileType.Pipfile;
        else if (basename == "environment.yml" || basename == "environment.yaml")
            return DependencyFileType.CondaEnv;
        
        // Default to requirements if unknown
        return DependencyFileType.Requirements;
    }
    
    /// Parse dependencies from file
    static PythonDependency[] parseDependencies(string filePath)
    {
        if (!exists(filePath))
        {
            structuredLog.warning("dependency_file_not_found_").field("detail", "Dependency file not found: " ~ filePath).emit();
            return [];
        }
        
        auto fileType = detectFileType(filePath);
        
        final switch (fileType)
        {
            case DependencyFileType.Requirements:
                return parseRequirementsTxt(filePath);
            case DependencyFileType.Pyproject:
                return parsePyprojectToml(filePath);
            case DependencyFileType.Setup:
                return parseSetupPy(filePath);
            case DependencyFileType.Pipfile:
                return parsePipfile(filePath);
            case DependencyFileType.CondaEnv:
                return parseCondaEnv(filePath);
        }
    }
    
    /// Parse requirements.txt file
    static PythonDependency[] parseRequirementsTxt(string filePath)
    {
        PythonDependency[] deps;
        
        try
        {
            auto content = readText(filePath);
            
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                
                // Skip empty lines and comments (SIMD-accelerated)
                if (trimmed.empty || (() @trusted => SIMDStrings.startsWith(trimmed, "#"))())
                    continue;
                
                // Skip flags like -r, -e, --index-url (SIMD-accelerated)
                if ((() @trusted => SIMDStrings.startsWith(trimmed, "-"))())
                    continue;
                
                auto dep = parseRequirementLine(trimmed);
                if (!dep.name.empty)
                    deps ~= dep;
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_requirementstxt_").field("detail", "Failed to parse requirements.txt: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Parse single requirement line
    private static PythonDependency parseRequirementLine(string line)
    {
        PythonDependency dep;
        
        // Handle extras: package[extra1,extra2]
        auto extrasMatch = matchFirst(line, regex(`^([a-zA-Z0-9_-]+)\[([^\]]+)\](.*)$`));
        if (extrasMatch)
        {
            dep.name = extrasMatch[1];
            dep.extras = extrasMatch[2].split(",").map!(s => s.strip).array;
            line = dep.name ~ extrasMatch[3];
        }
        
        // Parse version specifier: package==1.0.0, package>=1.0,<2.0, etc.
        auto versionMatch = matchFirst(line, regex(`^([a-zA-Z0-9_-]+)(.*)$`));
        if (versionMatch)
        {
            if (dep.name.empty)
                dep.name = versionMatch[1];
            
            auto versionSpec = versionMatch[2].strip;
            if (!versionSpec.empty)
                dep.version_ = versionSpec;
        }
        
        return dep;
    }
    
    /// Parse pyproject.toml file
    static PythonDependency[] parsePyprojectToml(string filePath)
    {
        PythonDependency[] deps;
        
        try
        {
            import std.algorithm : find;
            
            auto content = readText(filePath);
            
            // Simple TOML parsing for dependencies
            // Look for [project.dependencies] or [tool.poetry.dependencies]
            bool inProjectDeps = false;
            bool inPoetryDeps = false;
            bool inArray = false;
            
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                
                if (trimmed == "[project.dependencies]" || trimmed == "[project]")
                {
                    inProjectDeps = true;
                    inPoetryDeps = false;
                    continue;
                }
                else if (trimmed == "[tool.poetry.dependencies]")
                {
                    inPoetryDeps = true;
                    inProjectDeps = false;
                    continue;
                }
                else if ((() @trusted => SIMDStrings.startsWith(trimmed, "[") && SIMDStrings.endsWith(trimmed, "]"))())
                {
                    inProjectDeps = false;
                    inPoetryDeps = false;
                    inArray = false;
                    continue;
                }
                
                if ((() @trusted => SIMDStrings.startsWith(trimmed, "dependencies = ["))())
                {
                    inArray = true;
                    continue;
                }
                
                if (inArray && trimmed == "]")
                {
                    inArray = false;
                    continue;
                }
                
                if ((inProjectDeps && inArray) || inPoetryDeps)
                {
                    // Parse dependency line (SIMD-accelerated)
                    if (trimmed.empty || (() @trusted => SIMDStrings.startsWith(trimmed, "#"))())
                        continue;
                    
                    // Remove quotes and commas
                    auto depLine = trimmed.replace("\"", "").replace("'", "").replace(",", "").strip;
                    
                    if (!depLine.empty)
                    {
                        auto dep = parseRequirementLine(depLine);
                        if (!dep.name.empty)
                            deps ~= dep;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_pyprojecttoml_").field("detail", "Failed to parse pyproject.toml: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Parse setup.py file (simple heuristic)
    static PythonDependency[] parseSetupPy(string filePath)
    {
        PythonDependency[] deps;
        
        try
        {
            auto content = readText(filePath);
            
            // Look for install_requires= section
            auto installMatch = matchFirst(content, regex(`install_requires\s*=\s*\[([^\]]*)\]`, "s"));
            if (installMatch)
            {
                auto depsSection = installMatch[1];
                
                foreach (line; depsSection.lineSplitter)
                {
                    auto trimmed = line.strip.replace("\"", "").replace("'", "").replace(",", "").strip;
                    
                    if (trimmed.empty || trimmed.startsWith("#"))
                        continue;
                    
                    auto dep = parseRequirementLine(trimmed);
                    if (!dep.name.empty)
                        deps ~= dep;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_setuppy_").field("detail", "Failed to parse setup.py: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Parse Pipfile
    static PythonDependency[] parsePipfile(string filePath)
    {
        PythonDependency[] deps;
        
        try
        {
            auto content = readText(filePath);
            
            bool inPackages = false;
            
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                
                if (trimmed == "[packages]")
                {
                    inPackages = true;
                    continue;
                }
                else if ((() @trusted => SIMDStrings.startsWith(trimmed, "["))())
                {
                    inPackages = false;
                    continue;
                }
                
                if (inPackages && !trimmed.empty && !(() @trusted => SIMDStrings.startsWith(trimmed, "#"))())
                {
                    // Parse: package = "version" or package = "*"
                    auto parts = trimmed.split("=");
                    if (parts.length >= 1)
                    {
                        PythonDependency dep;
                        dep.name = parts[0].strip;
                        if (parts.length >= 2)
                        {
                            auto version_ = parts[1].strip.replace("\"", "").replace("'", "");
                            if (version_ != "*")
                                dep.version_ = version_;
                        }
                        
                        if (!dep.name.empty)
                            deps ~= dep;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_pipfile_").field("detail", "Failed to parse Pipfile: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Parse conda environment.yml
    static PythonDependency[] parseCondaEnv(string filePath)
    {
        PythonDependency[] deps;
        
        try
        {
            auto content = readText(filePath);
            
            bool inDeps = false;
            
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                
                if ((() @trusted => SIMDStrings.startsWith(trimmed, "dependencies:"))())
                {
                    inDeps = true;
                    continue;
                }
                else if (inDeps && !(() @trusted => SIMDStrings.startsWith(trimmed, "-"))() && !trimmed.empty)
                {
                    inDeps = false;
                }
                
                if (inDeps && (() @trusted => SIMDStrings.startsWith(trimmed, "-"))())
                {
                    auto depLine = trimmed[1 .. $].strip;
                    
                    // Handle pip dependencies
                    if (depLine == "pip:")
                        continue;
                    
                    auto dep = parseRequirementLine(depLine);
                    if (!dep.name.empty)
                        deps ~= dep;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_conda_environmentyml_").field("detail", "Failed to parse conda environment.yml: " ~ e.msg).emit();
        }
        
        return deps;
    }
}

