module infrastructure.analysis.manifests.python;

import std.string;
import std.array;
import std.algorithm;
import std.path : baseName, dirName, buildPath;
import std.file : readText, isFile, exists;
import std.regex;
import infrastructure.analysis.manifests.types;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Parser for pyproject.toml, requirements.txt, setup.py
final class PythonManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath) || !isFile(filePath))
            return BuildResult!ManifestInfo.err(
                manifestNotFoundError(filePath, "python"));
        
        string fileName = baseName(filePath);
        
        if (fileName == "pyproject.toml")
            return parsePyproject(filePath);
        else if (fileName == "setup.py")
            return parseSetupPy(filePath);
        else if (fileName == "requirements.txt" || fileName == "requirements-dev.txt")
            return parseRequirements(filePath);
        
        return BuildResult!ManifestInfo.err(
            manifestParseError(filePath, "python", "Unknown Python manifest type: " ~ fileName));
    }
    
    override bool canParse(string filePath) const @safe
    {
        string name = baseName(filePath);
        return name == "pyproject.toml" || name == "setup.py" || 
               name.startsWith("requirements") && name.endsWith(".txt");
    }
    
    override string name() const pure nothrow @safe
    {
        return "python";
    }
    
    private BuildResult!ManifestInfo parsePyproject(string filePath) @system
    {
        try
        {
            string content = readText(filePath);
            ManifestInfo info;
            info.language = TargetLanguage.Python;
            
            // Extract project name and version
            info.name = extractTomlValue(content, `name\s*=\s*"([^"]+)"`, "app");
            info.version_ = extractTomlValue(content, `version\s*=\s*"([^"]+)"`, "0.1.0");
            
            // Entry points
            info.entryPoints = detectPythonEntryPoints(dirName(filePath));
            info.sources = ["*.py", "src/**/*.py", info.name ~ "/**/*.py"];
            info.tests = ["tests/**/*.py", "test_*.py", "*_test.py"];
            
            // Parse dependencies
            info.dependencies = parsePyprojectDeps(content);
            
            // Detect target type
            info.suggestedType = inferPythonTargetType(dirName(filePath), info.dependencies);
            
            // Metadata
            string description = extractTomlValue(content, `description\s*=\s*"([^"]+)"`, "");
            if (!description.empty)
                info.metadata["description"] = description;
            
            string framework = detectPythonFramework(content, info.dependencies);
            if (!framework.empty)
                info.metadata["framework"] = framework;
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "python", e.msg));
        }
    }
    
    private BuildResult!ManifestInfo parseSetupPy(string filePath) @system
    {
        try
        {
            string content = readText(filePath);
            ManifestInfo info;
            info.language = TargetLanguage.Python;
            
            // Extract name
            info.name = extractPythonValue(content, `name\s*=\s*['"]([^'"]+)['"]`, "app");
            info.version_ = extractPythonValue(content, `version\s*=\s*['"]([^'"]+)['"]`, "0.1.0");
            
            // Entry points
            info.entryPoints = detectPythonEntryPoints(dirName(filePath));
            info.sources = ["*.py", "src/**/*.py", info.name ~ "/**/*.py"];
            info.tests = ["tests/**/*.py", "test_*.py", "*_test.py"];
            
            // Parse dependencies from install_requires
            info.dependencies = parseSetupPyDeps(content);
            
            // Target type
            info.suggestedType = inferPythonTargetType(dirName(filePath), info.dependencies);
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                manifestParseError(filePath, "python", e.msg));
        }
    }
    
    private BuildResult!ManifestInfo parseRequirements(string filePath) @system
    {
        try
        {
            string content = readText(filePath);
            ManifestInfo info;
            info.language = TargetLanguage.Python;
            info.name = baseName(dirName(filePath));
            info.version_ = "0.1.0";
            
            // Entry points
            info.entryPoints = detectPythonEntryPoints(dirName(filePath));
            info.sources = ["*.py", "src/**/*.py"];
            info.tests = ["tests/**/*.py"];
            
            // Parse dependencies
            info.dependencies = parseRequirementsTxt(content, filePath.endsWith("-dev.txt"));
            
            // Target type
            info.suggestedType = inferPythonTargetType(dirName(filePath), info.dependencies);
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            auto error = Errors.parse(filePath, "Parse error: " ~ e.msg, Parse.Failed)
                .withLocation(__FILE__, __LINE__)
                .build();
            return BuildResult!ManifestInfo.err(error);
        }
    }
    
    private string[] detectPythonEntryPoints(string dir) const
    {
        string[] candidates = [
            buildPath(dir, "main.py"),
            buildPath(dir, "app.py"),
            buildPath(dir, "__main__.py"),
            buildPath(dir, "src/main.py"),
            buildPath(dir, "src/app.py")
        ];
        
        string[] found;
        foreach (candidate; candidates)
            if (exists(candidate))
                found ~= candidate;
        
        return found.empty ? ["main.py"] : found;
    }
    
    private Dependency[] parsePyprojectDeps(string content) const
    {
        Dependency[] deps;
        
        // Find [project.dependencies] or [tool.poetry.dependencies]
        auto idx = content.indexOf("[project.dependencies]");
        if (idx < 0)
            idx = content.indexOf("[tool.poetry.dependencies]");
        
        if (idx >= 0)
        {
            auto remaining = content[idx .. $];
            auto nextSection = remaining.indexOf("\n[", 1);
            if (nextSection > 0)
                remaining = remaining[0 .. nextSection];
            
            // Parse TOML array style or Poetry style
            auto re = regex(`"([^"=]+)(?:[=><~]+[^"]+)?"`);
            foreach (match; matchAll(remaining, re))
            {
                if (match[1] != "python") // Skip Python version
                {
                    Dependency dep;
                    dep.name = match[1];
                    dep.type = DependencyType.Runtime;
                    deps ~= dep;
                }
            }
        }
        
        return deps;
    }
    
    private Dependency[] parseSetupPyDeps(string content) const
    {
        Dependency[] deps;
        
        // Find install_requires array
        auto re = regex(`install_requires\s*=\s*\[(.*?)\]`, "s");
        auto match = matchFirst(content, re);
        
        if (!match.empty)
        {
            auto depRe = regex(`['"]([^'">=<~]+)(?:[>=<~][^'"]+)?['"]`);
            foreach (depMatch; matchAll(match[1], depRe))
            {
                Dependency dep;
                dep.name = depMatch[1].strip;
                dep.type = DependencyType.Runtime;
                deps ~= dep;
            }
        }
        
        return deps;
    }
    
    private Dependency[] parseRequirementsTxt(string content, bool isDev) const
    {
        Dependency[] deps;
        
        foreach (line; content.lineSplitter)
        {
            line = line.strip;
            if (line.empty || line.startsWith("#") || line.startsWith("-"))
                continue;
            
            // Extract package name (before any version specifier)
            auto re = regex(`^([a-zA-Z0-9\-_]+)`);
            auto match = matchFirst(line, re);
            
            if (!match.empty)
            {
                Dependency dep;
                dep.name = match[1];
                dep.type = isDev ? DependencyType.Development : DependencyType.Runtime;
                deps ~= dep;
            }
        }
        
        return deps;
    }
    
    private TargetType inferPythonTargetType(string dir, in Dependency[] deps) const
    {
        // Check for web frameworks
        bool isWebFramework = deps.any!(d => 
            d.name == "django" || d.name == "flask" || d.name == "fastapi" || 
            d.name == "tornado" || d.name == "aiohttp");
        
        if (isWebFramework)
            return TargetType.Executable;
        
        // Check for __main__.py or manage.py
        if (exists(buildPath(dir, "__main__.py")) || exists(buildPath(dir, "manage.py")))
            return TargetType.Executable;
        
        // Check for setup.py (indicates library)
        if (exists(buildPath(dir, "setup.py")) && !exists(buildPath(dir, "main.py")))
            return TargetType.Library;
        
        return TargetType.Executable;
    }
    
    private string detectPythonFramework(string content, in Dependency[] deps) const
    {
        foreach (dep; deps)
        {
            switch (dep.name)
            {
                case "django": return "django";
                case "flask": return "flask";
                case "fastapi": return "fastapi";
                case "tornado": return "tornado";
                case "aiohttp": return "aiohttp";
                default: break;
            }
        }
        
        // Check content for imports
        if (content.canFind("django"))
            return "django";
        if (content.canFind("flask"))
            return "flask";
        if (content.canFind("fastapi"))
            return "fastapi";
        
        return "";
    }
    
    private string extractTomlValue(string content, string pattern, string defaultValue) const
    {
        auto re = regex(pattern);
        auto match = matchFirst(content, re);
        return match.empty ? defaultValue : match[1];
    }
    
    private string extractPythonValue(string content, string pattern, string defaultValue) const
    {
        auto re = regex(pattern);
        auto match = matchFirst(content, re);
        return match.empty ? defaultValue : match[1];
    }
}

