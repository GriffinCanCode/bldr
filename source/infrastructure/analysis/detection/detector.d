module infrastructure.analysis.detection.detector;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.ignore;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;
import languages.registry;

/// Language detection result
struct LanguageInfo
{
    TargetLanguage language;
    string[] sourceFiles;
    string[] manifestFiles;
    ProjectFramework framework;
    double confidence;  // 0.0-1.0
}

/// Framework detection
enum ProjectFramework
{
    None,
    // JavaScript/TypeScript
    React,
    Vue,
    Angular,
    Svelte,
    NextJS,
    ViteReact,
    ViteVue,
    // Python
    Django,
    Flask,
    FastAPI,
    // Ruby
    Rails,
    Sinatra,
    // Elixir
    Phoenix,
    PhoenixLiveView,
    // JavaScript/Node.js
    Express,
    // Go
    Gin,
    Echo,
    Fiber,
    // Rust
    Actix,
    Rocket,
    Axum,
    // PHP
    Laravel,
    Symfony,
    // Java
    Spring,
    Quarkus,
    // .NET
    AspNetCore,
}

/// Project metadata
struct ProjectMetadata
{
    string projectName;
    string mainEntry;
    LanguageInfo[] languages;
    bool isMonorepo;
    string[] subprojects;
}

/// Intelligent project detector
class ProjectDetector
{
    private string projectDir;
    
    this(string projectDir)
    {
        this.projectDir = projectDir;
    }
    
    /// Detect all project metadata
    ProjectMetadata detect()
    {
        ProjectMetadata meta;
        
        // Infer project name from directory
        meta.projectName = baseName(absolutePath(projectDir));
        
        // Scan for language-specific files
        meta.languages = detectLanguages();
        
        // Detect if monorepo
        meta.isMonorepo = detectMonorepo();
        
        // Find main entry point
        meta.mainEntry = detectMainEntry(meta.languages);
        
        return meta;
    }
    
    /// Detect all languages present in project
    private LanguageInfo[] detectLanguages()
    {
        LanguageInfo[TargetLanguage] found;
        
        // Scan directory tree
        scanDirectory(projectDir, found);
        
        // Convert to array and sort by confidence
        auto languages = found.values.array;
        languages.sort!((a, b) => a.confidence > b.confidence);
        
        return languages;
    }
    
    /// Recursively scan directory for language markers
    private void scanDirectory(string dir, ref LanguageInfo[TargetLanguage] found, int depth = 0)
    {
        if (depth > 10)  // Prevent deep recursion
            return;
        
        if (!exists(dir) || !isDir(dir))
            return;
        
        try
        {
            foreach (DirEntry entry; dirEntries(dir, SpanMode.shallow))
            {
                // Validate entry is within directory to prevent traversal attacks
                if (!SecurityValidator.isPathWithinBase(entry.name, dir))
                    continue;
                
                immutable name = baseName(entry.name);
                
                // Skip ignored directories using centralized ignore registry
                // This prevents scanning dependency folders like node_modules, venv, etc.
                if (entry.isDir && IgnoreRegistry.shouldIgnoreDirectoryAny(entry.name))
                    continue;
                
                if (entry.isFile)
                {
                    detectFromFile(entry.name, found);
                }
                else if (entry.isDir)
                {
                    scanDirectory(entry.name, found, depth + 1);
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.debug_("failed_to_scan_directory_").field("detail", "Failed to scan directory: " ~ dir).emit();
        }
    }
    
    /// Detect language from a single file
    private void detectFromFile(string filePath, ref LanguageInfo[TargetLanguage] found)
    {
        immutable ext = extension(filePath);
        immutable name = baseName(filePath);
        
        // Check manifest files first (higher confidence)
        if (checkManifest(name, filePath, found))
            return;
        
        // Check by extension
        TargetLanguage lang = extensionToLanguage(ext);
        if (lang == TargetLanguage.Generic)
            return;
        
        // Add to found languages
        if (lang !in found)
        {
            found[lang] = LanguageInfo(
                lang,
                [filePath],
                [],
                ProjectFramework.None,
                0.5  // Medium confidence for file extension
            );
        }
        else
        {
            found[lang].sourceFiles ~= filePath;
            found[lang].confidence = min(1.0, found[lang].confidence + 0.1);
        }
    }
    
    /// Check if file is a manifest and update detection
    private bool checkManifest(string name, string path, ref LanguageInfo[TargetLanguage] found)
    {
        // JavaScript/TypeScript manifests
        if (name == "package.json")
        {
            detectNodeProject(path, found);
            return true;
        }
        
        // Python manifests
        if (name == "requirements.txt" || name == "setup.py" || 
            name == "pyproject.toml" || name == "Pipfile")
        {
            addOrUpdate(found, TargetLanguage.Python, [], [path], 0.9);
            detectPythonFramework(dirName(path), found);
            return true;
        }
        
        // Go manifests
        if (name == "go.mod" || name == "go.sum")
        {
            addOrUpdate(found, TargetLanguage.Go, [], [path], 0.95);
            detectGoFramework(dirName(path), found);
            return true;
        }
        
        // Rust manifests
        if (name == "Cargo.toml" || name == "Cargo.lock")
        {
            addOrUpdate(found, TargetLanguage.Rust, [], [path], 0.95);
            detectRustFramework(dirName(path), found);
            return true;
        }
        
        // Ruby manifests
        if (name == "Gemfile" || name == "Gemfile.lock")
        {
            addOrUpdate(found, TargetLanguage.Ruby, [], [path], 0.9);
            detectRubyFramework(dirName(path), found);
            return true;
        }
        
        // Elixir manifests
        if (name == "mix.exs" || name == "mix.lock")
        {
            addOrUpdate(found, TargetLanguage.Elixir, [], [path], 0.95);
            detectElixirFramework(dirName(path), found);
            return true;
        }
        
        // Java manifests
        if (name == "pom.xml" || name == "build.gradle" || name == "build.gradle.kts")
        {
            addOrUpdate(found, TargetLanguage.Java, [], [path], 0.9);
            detectJavaFramework(dirName(path), found);
            return true;
        }
        
        // .NET manifests
        if (name.endsWith(".csproj") || name.endsWith(".fsproj") || name.endsWith(".sln"))
        {
            addOrUpdate(found, TargetLanguage.CSharp, [], [path], 0.95);
            return true;
        }
        
        // PHP manifests
        if (name == "composer.json")
        {
            addOrUpdate(found, TargetLanguage.PHP, [], [path], 0.9);
            detectPHPFramework(dirName(path), found);
            return true;
        }
        
        // TypeScript config
        if (name == "tsconfig.json" || name == "deno.json")
        {
            addOrUpdate(found, TargetLanguage.TypeScript, [], [path], 0.9);
            return true;
        }
        
        // R project
        if (name == "DESCRIPTION" || name.endsWith(".Rproj"))
        {
            addOrUpdate(found, TargetLanguage.R, [], [path], 0.95);
            return true;
        }
        
        // Elm project
        if (name == "elm.json")
        {
            addOrUpdate(found, TargetLanguage.Elm, [], [path], 0.95);
            return true;
        }
        
        return false;
    }
    
    /// Detect Node.js project details from package.json
    private void detectNodeProject(string packageJsonPath, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            import std.json;
            string content = readText(packageJsonPath);
            auto json = parseJSON(content);
            
            // Check dependencies for framework hints
            ProjectFramework framework = ProjectFramework.None;
            bool isTypeScript = false;
            
            if ("dependencies" in json)
            {
                auto deps = json["dependencies"].object;
                
                if ("react" in deps || "react-dom" in deps)
                {
                    framework = ProjectFramework.React;
                    
                    if ("next" in deps)
                        framework = ProjectFramework.NextJS;
                }
                else if ("vue" in deps)
                {
                    framework = ProjectFramework.Vue;
                }
                else if ("@angular/core" in deps)
                {
                    framework = ProjectFramework.Angular;
                }
                else if ("svelte" in deps)
                {
                    framework = ProjectFramework.Svelte;
                }
                
                if ("typescript" in deps)
                    isTypeScript = true;
            }
            
            if ("devDependencies" in json)
            {
                auto devDeps = json["devDependencies"].object;
                
                if ("typescript" in devDeps || "@types/node" in devDeps)
                    isTypeScript = true;
                
                if ("vite" in devDeps)
                {
                    if (framework == ProjectFramework.React)
                        framework = ProjectFramework.ViteReact;
                    else if (framework == ProjectFramework.Vue)
                        framework = ProjectFramework.ViteVue;
                }
            }
            
            // Determine language
            auto lang = isTypeScript ? TargetLanguage.TypeScript : TargetLanguage.JavaScript;
            addOrUpdate(found, lang, [], [packageJsonPath], 0.95, framework);
        }
        catch (Exception e)
        {
            structuredLog.debug_("failed_to_parse_packagejson_").field("detail", "Failed to parse package.json: " ~ e.msg).emit();
        }
    }
    
    /// Detect Python framework
    private void detectPythonFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        ProjectFramework framework = ProjectFramework.None;
        
        // Check for Django
        if (exists(buildPath(dir, "manage.py")))
            framework = ProjectFramework.Django;
        // Check for Flask
        else if (exists(buildPath(dir, "app.py")) || exists(buildPath(dir, "application.py")))
        {
            try
            {
                auto content = readText(buildPath(dir, "app.py"));
                if (content.canFind("Flask"))
                    framework = ProjectFramework.Flask;
                else if (content.canFind("FastAPI"))
                    framework = ProjectFramework.FastAPI;
            }
            catch (Exception e)
            {
                // File may not exist or be readable, framework detection will use other heuristics
            }
        }
        
        if (TargetLanguage.Python in found && framework != ProjectFramework.None)
            found[TargetLanguage.Python].framework = framework;
    }
    
    /// Detect Go framework
    private void detectGoFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            string goModPath = buildPath(dir, "go.mod");
            if (!exists(goModPath))
                return;
            
            auto content = readText(goModPath);
            ProjectFramework framework = ProjectFramework.None;
            
            if (content.canFind("gin-gonic/gin"))
                framework = ProjectFramework.Gin;
            else if (content.canFind("labstack/echo"))
                framework = ProjectFramework.Echo;
            else if (content.canFind("gofiber/fiber"))
                framework = ProjectFramework.Fiber;
            
            if (TargetLanguage.Go in found && framework != ProjectFramework.None)
                found[TargetLanguage.Go].framework = framework;
        }
        catch (Exception e)
        {
            // File may not exist or be readable, framework detection will use other heuristics
        }
    }
    
    /// Detect Rust framework
    private void detectRustFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            string cargoPath = buildPath(dir, "Cargo.toml");
            if (!exists(cargoPath))
                return;
            
            auto content = readText(cargoPath);
            ProjectFramework framework = ProjectFramework.None;
            
            if (content.canFind("actix-web"))
                framework = ProjectFramework.Actix;
            else if (content.canFind("rocket"))
                framework = ProjectFramework.Rocket;
            else if (content.canFind("axum"))
                framework = ProjectFramework.Axum;
            
            if (TargetLanguage.Rust in found && framework != ProjectFramework.None)
                found[TargetLanguage.Rust].framework = framework;
        }
        catch (Exception e)
        {
            // File may not exist or be readable, framework detection will use other heuristics
        }
    }
    
    /// Detect Ruby framework
    private void detectRubyFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        // Check for Rails
        if (exists(buildPath(dir, "config", "application.rb")) ||
            exists(buildPath(dir, "Rakefile")))
        {
            if (TargetLanguage.Ruby in found)
                found[TargetLanguage.Ruby].framework = ProjectFramework.Rails;
        }
    }
    
    /// Detect Elixir framework
    private void detectElixirFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            string mixPath = buildPath(dir, "mix.exs");
            if (!exists(mixPath))
                return;
            
            auto content = readText(mixPath);
            ProjectFramework framework = ProjectFramework.None;
            
            if (content.canFind(":phoenix"))
            {
                framework = content.canFind(":phoenix_live_view") ? 
                    ProjectFramework.PhoenixLiveView : ProjectFramework.Phoenix;
            }
            
            if (TargetLanguage.Elixir in found && framework != ProjectFramework.None)
                found[TargetLanguage.Elixir].framework = framework;
        }
        catch (Exception e)
        {
            // File may not exist or be readable, framework detection will use other heuristics
        }
    }
    
    /// Detect Java framework
    private void detectJavaFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            string pomPath = buildPath(dir, "pom.xml");
            if (exists(pomPath))
            {
                auto content = readText(pomPath);
                ProjectFramework framework = ProjectFramework.None;
                
                if (content.canFind("spring-boot"))
                    framework = ProjectFramework.Spring;
                else if (content.canFind("quarkus"))
                    framework = ProjectFramework.Quarkus;
                
                if (TargetLanguage.Java in found && framework != ProjectFramework.None)
                    found[TargetLanguage.Java].framework = framework;
            }
        }
        catch (Exception e)
        {
            // File may not exist or be readable, framework detection will use other heuristics
        }
    }
    
    /// Detect PHP framework
    private void detectPHPFramework(string dir, ref LanguageInfo[TargetLanguage] found)
    {
        try
        {
            string composerPath = buildPath(dir, "composer.json");
            if (!exists(composerPath))
                return;
            
            import std.json;
            auto content = readText(composerPath);
            auto json = parseJSON(content);
            
            ProjectFramework framework = ProjectFramework.None;
            
            if ("require" in json)
            {
                auto deps = json["require"].object;
                
                if ("laravel/framework" in deps)
                    framework = ProjectFramework.Laravel;
                else if ("symfony/symfony" in deps)
                    framework = ProjectFramework.Symfony;
            }
            
            if (TargetLanguage.PHP in found && framework != ProjectFramework.None)
                found[TargetLanguage.PHP].framework = framework;
        }
        catch (Exception e)
        {
            // File may not exist or be readable, framework detection will use other heuristics
        }
    }
    
    /// Add or update language info
    private void addOrUpdate(
        ref LanguageInfo[TargetLanguage] found,
        TargetLanguage lang,
        string[] sources,
        string[] manifests,
        double confidence,
        ProjectFramework framework = ProjectFramework.None
    )
    {
        if (lang !in found)
        {
            found[lang] = LanguageInfo(
                lang,
                sources,
                manifests,
                framework,
                confidence
            );
        }
        else
        {
            found[lang].sourceFiles ~= sources;
            found[lang].manifestFiles ~= manifests;
            found[lang].confidence = max(found[lang].confidence, confidence);
            
            if (framework != ProjectFramework.None)
                found[lang].framework = framework;
        }
    }
    
    /// Map file extension to language - delegates to centralized registry
    private TargetLanguage extensionToLanguage(string ext) pure
    {
        return inferLanguageFromExtension(ext);
    }
    
    /// Detect if project is a monorepo
    private bool detectMonorepo()
    {
        // Check for common monorepo markers
        immutable markers = [
            "lerna.json",
            "pnpm-workspace.yaml",
            "rush.json",
            "nx.json"
        ];
        
        foreach (marker; markers)
        {
            if (exists(buildPath(projectDir, marker)))
                return true;
        }
        
        return false;
    }
    
    /// Detect main entry point
    private string detectMainEntry(LanguageInfo[] languages)
    {
        if (languages.empty)
            return "";
        
        // Look for common entry point names
        immutable entryPoints = [
            "main", "index", "app", "application", "server", "cli"
        ];
        
        foreach (lang; languages)
        {
            foreach (source; lang.sourceFiles)
            {
                immutable base = baseName(stripExtension(source));
                
                if (entryPoints.canFind(base))
                    return source;
            }
        }
        
        // Return first source file as fallback
        return languages[0].sourceFiles.length > 0 ? 
               languages[0].sourceFiles[0] : "";
    }
}

/// Simple language detector for testing and simple use cases
class LanguageDetector
{
    private string projectDir;
    
    this()
    {
        this.projectDir = ".";
    }
    
    this(string projectDir)
    {
        this.projectDir = projectDir;
    }
    
    /// Detect languages in a directory
    TargetLanguage[] detectLanguages(string path)
    {
        auto detector = new ProjectDetector(path);
        auto metadata = detector.detect();
        
        TargetLanguage[] languages;
        foreach (langInfo; metadata.languages)
        {
            languages ~= langInfo.language;
        }
        
        return languages;
    }
    
    /// Detect languages with confidence scores
    LanguageInfo[] detectWithConfidence(string path)
    {
        auto detector = new ProjectDetector(path);
        auto metadata = detector.detect();
        return metadata.languages;
    }
    
    /// Detect language by file extension
    TargetLanguage detectByExtension(string ext)
    {
        return extensionToLanguage(ext);
    }
    
    /// Map file extension to language - delegates to centralized registry
    private TargetLanguage extensionToLanguage(string ext) pure
    {
        return inferLanguageFromExtension(ext);
    }
}

