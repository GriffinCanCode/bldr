module languages.dynamic.spec;

import std.json;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import infrastructure.errors;

/// Language specification loaded from declarative config
/// Enables zero-code language addition via TOML/JSON specs
struct LanguageSpec
{
    /// Language metadata
    struct Metadata
    {
        string name;                    // Language identifier (e.g. "crystal")
        string display;                 // Display name (e.g. "Crystal")
        string category;                // compiled/scripting/jvm/dotnet/web
        string[] extensions;            // File extensions [".cr"]
        string[] aliases;               // Name aliases ["cr"]
    }
    
    /// Detection patterns for language identification
    struct Detection
    {
        string[] shebang;              // Shebang patterns to match
        string[] manifestFiles;        // Project files (e.g. "shard.yml")
        string versionCmd;             // Command to check version
    }
    
    /// Build configuration with command templates
    struct Build
    {
        string compiler;                // Compiler/runtime command
        string compileCmd;              // Template: "crystal build {{sources}} -o {{output}} {{flags}}"
        string testCmd;                 // Template for running tests
        string formatCmd;               // Template for code formatting
        string lintCmd;                 // Template for linting
        string checkCmd;                // Template for type checking
        string[string] env;             // Environment variables
        bool incremental;               // Supports incremental compilation
        bool caching;                   // Supports build caching
    }
    
    /// Dependency analysis configuration
    struct Dependencies
    {
        string pattern;                 // Regex pattern for imports
        string resolver;                // How to resolve (module_path, package, etc.)
        string manifest;                // Dependency manifest file
        string installCmd;              // Command to install dependencies
    }
    
    Metadata metadata;
    Detection detection;
    Build build;
    Dependencies deps;
    
    /// Load spec from JSON file
    static BuildResult!LanguageSpec fromJSON(string jsonPath) @system
    {
        try
        {
            auto content = readText(jsonPath);
            auto json = parseJSON(content);
            
            LanguageSpec spec;
            
            // Parse metadata
            if ("language" in json)
            {
                auto lang = json["language"];
                spec.metadata.name = lang["name"].str;
                spec.metadata.display = ("display" in lang) ? lang["display"].str : spec.metadata.name;
                spec.metadata.category = ("category" in lang) ? lang["category"].str : "scripting";
                
                if ("extensions" in lang)
                {
                    foreach (ext; lang["extensions"].array)
                        spec.metadata.extensions ~= ext.str;
                }
                
                if ("aliases" in lang)
                {
                    foreach (alias_; lang["aliases"].array)
                        spec.metadata.aliases ~= alias_.str;
                }
            }
            
            // Parse detection
            if ("detection" in json)
            {
                auto det = json["detection"];
                if ("shebang" in det)
                {
                    foreach (sheb; det["shebang"].array)
                        spec.detection.shebang ~= sheb.str;
                }
                if ("files" in det)
                {
                    foreach (file; det["files"].array)
                        spec.detection.manifestFiles ~= file.str;
                }
                if ("version_cmd" in det)
                    spec.detection.versionCmd = det["version_cmd"].str;
            }
            
            // Parse build
            if ("build" in json)
            {
                auto bld = json["build"];
                spec.build.compiler = ("compiler" in bld) ? bld["compiler"].str : "";
                spec.build.compileCmd = ("compile_cmd" in bld) ? bld["compile_cmd"].str : "";
                spec.build.testCmd = ("test_cmd" in bld) ? bld["test_cmd"].str : "";
                spec.build.formatCmd = ("format_cmd" in bld) ? bld["format_cmd"].str : "";
                spec.build.lintCmd = ("lint_cmd" in bld) ? bld["lint_cmd"].str : "";
                spec.build.checkCmd = ("check_cmd" in bld) ? bld["check_cmd"].str : "";
                spec.build.incremental = ("incremental" in bld) ? bld["incremental"].boolean : false;
                spec.build.caching = ("caching" in bld) ? bld["caching"].boolean : true;
                
                if ("env" in bld)
                {
                    foreach (key, value; bld["env"].object)
                        spec.build.env[key] = value.str;
                }
            }
            
            // Parse dependencies
            if ("dependencies" in json)
            {
                auto dep = json["dependencies"];
                spec.deps.pattern = ("pattern" in dep) ? dep["pattern"].str : "";
                spec.deps.resolver = ("resolver" in dep) ? dep["resolver"].str : "module_path";
                spec.deps.manifest = ("manifest" in dep) ? dep["manifest"].str : "";
                spec.deps.installCmd = ("install_cmd" in dep) ? dep["install_cmd"].str : "";
            }
            
            return Ok!(LanguageSpec, BuildError)(spec);
        }
        catch (Exception e)
        {
            auto error = Errors.parse(jsonPath, "Failed to parse language spec: " ~ e.msg, Parse.Failed)
                .withLocation(__FILE__, __LINE__)
                .build();
            return Err!(LanguageSpec, BuildError)(error);
        }
    }
    
    /// Expand command template with variables
    string expandTemplate(string template_, string[string] vars) const pure @safe
    {
        string result = template_;
        foreach (key, value; vars)
        {
            result = result.replace("{{" ~ key ~ "}}", value);
        }
        return result;
    }
    
    /// Check if compiler is available on system
    bool isAvailable() const @system
    {
        import infrastructure.utils.process : isCommandAvailable;
        return !build.compiler.empty && isCommandAvailable(build.compiler);
    }
}

/// Registry for dynamically loaded language specs
final class SpecRegistry
{
    private LanguageSpec[string] specs;
    private string specsDir;
    
    this(string specsDir = "")
    {
        import std.process : environment;
        
        if (specsDir.empty)
        {
            // Default to Builder installation directory
            this.specsDir = buildPath(environment.get("HOME", "."), ".builder", "specs");
        }
        else
        {
            this.specsDir = specsDir;
        }
    }
    
    /// Discover and load all spec files from directory
    BuildResult!size_t loadAll() @system
    {
        if (!exists(specsDir) || !isDir(specsDir))
            return Ok!(size_t, BuildError)(0);
        
        size_t loaded = 0;
        
        try
        {
            foreach (entry; dirEntries(specsDir, "*.json", SpanMode.shallow))
            {
                if (!entry.isFile)
                    continue;
                
                auto specResult = LanguageSpec.fromJSON(entry.name);
                if (specResult.isOk)
                {
                    auto spec = specResult.unwrap();
                    specs[spec.metadata.name] = spec;
                    loaded++;
                }
            }
        }
        catch (Exception e)
        {
            auto error = Errors.build("spec-registry", "Failed to load specs: " ~ e.msg, Internal.Error)
                .withLocation(__FILE__, __LINE__)
                .build();
            return Err!(size_t, BuildError)(error);
        }
        
        return Ok!(size_t, BuildError)(loaded);
    }
    
    /// Get spec by language name
    LanguageSpec* get(string langName) @system
    {
        if (auto spec = langName in specs)
            return spec;
        return null;
    }
    
    /// Check if spec exists
    bool has(string langName) const pure nothrow @safe
    {
        return (langName in specs) !is null;
    }
    
    /// Get all registered spec names
    string[] languages() const @system
    {
        return specs.keys;
    }
}

