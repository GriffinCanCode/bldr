module languages.scripting.gleam.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// Gleam compilation target
enum GleamTarget
{
    Erlang,     // Compile to Erlang (BEAM)
    JavaScript  // Compile to JavaScript
}

/// Gleam project type
enum GleamProjectType
{
    Application,  // Runnable application
    Library       // Reusable library
}

/// Gleam runtime configuration
struct GleamRuntimeConfig
{
    string gleamPath = "gleam";  // Path to gleam binary
    string erlangPath = "";      // Custom Erlang installation
    bool useRebar = false;       // Use rebar3 for Erlang deps
}

/// Gleam format configuration
struct GleamFormatConfig
{
    bool enabled = true;
    bool check = false;          // Check formatting without modifying
    string[] stdin = [];         // Format from stdin
}

/// Gleam test configuration
struct GleamTestConfig
{
    string[] testModules = [];   // Specific test modules to run
    bool allowWarnings = false;  // Allow compilation warnings in tests
    int workers = 0;             // Number of parallel test workers (0 = auto)
}

/// Gleam documentation configuration
struct GleamDocsConfig
{
    bool enabled = false;
    string outputDir = "docs";
    bool open = false;           // Open in browser after generation
}

/// Gleam Hex package configuration
struct GleamHexConfig
{
    bool publish = false;
    string name = "";
    string version_ = "";
    string description = "";
    string[] licenses = [];
    string repository = "";
    string[string] links;
}

/// Unified Gleam configuration
struct GleamConfig
{
    GleamTarget target = GleamTarget.Erlang;
    GleamProjectType projectType = GleamProjectType.Application;
    GleamRuntimeConfig runtime;
    GleamFormatConfig format;
    GleamTestConfig test;
    GleamDocsConfig docs;
    GleamHexConfig hex;
    
    // Build options
    bool warningsAsErrors = false;
    bool verbose = false;
    bool force = false;
    string outputDir = "build";
    string[string] env;
    
    /// Parse from JSON
    static GleamConfig fromJSON(JSONValue json) @system
    {
        GleamConfig config;
        
        // Target
        if (auto target = "target" in json)
        {
            immutable targetStr = target.str.toLower;
            config.target = targetStr == "javascript" || targetStr == "js" 
                ? GleamTarget.JavaScript 
                : GleamTarget.Erlang;
        }
        
        // Project type
        if (auto projectType = "projectType" in json)
        {
            immutable typeStr = projectType.str.toLower;
            config.projectType = typeStr == "library" || typeStr == "lib"
                ? GleamProjectType.Library
                : GleamProjectType.Application;
        }
        
        // Runtime configuration
        if (auto runtime = "runtime" in json)
        {
            if (auto gleamPath = "gleamPath" in *runtime)
                config.runtime.gleamPath = gleamPath.str;
            if (auto erlangPath = "erlangPath" in *runtime)
                config.runtime.erlangPath = erlangPath.str;
            if (auto useRebar = "useRebar" in *runtime)
                config.runtime.useRebar = useRebar.type == JSONType.true_;
        }
        
        // Format configuration
        if (auto format = "format" in json)
        {
            if (auto enabled = "enabled" in *format)
                config.format.enabled = enabled.type == JSONType.true_;
            if (auto check = "check" in *format)
                config.format.check = check.type == JSONType.true_;
        }
        
        // Test configuration
        if (auto test = "test" in json)
        {
            if (auto modules = "modules" in *test)
                config.test.testModules = modules.array.map!(e => e.str).array;
            if (auto allowWarnings = "allowWarnings" in *test)
                config.test.allowWarnings = allowWarnings.type == JSONType.true_;
            if (auto workers = "workers" in *test)
                config.test.workers = cast(int) workers.integer;
        }
        
        // Docs configuration
        if (auto docs = "docs" in json)
        {
            if (auto enabled = "enabled" in *docs)
                config.docs.enabled = enabled.type == JSONType.true_;
            if (auto outputDir = "outputDir" in *docs)
                config.docs.outputDir = outputDir.str;
            if (auto open = "open" in *docs)
                config.docs.open = open.type == JSONType.true_;
        }
        
        // Hex configuration
        if (auto hex = "hex" in json)
        {
            if (auto publish = "publish" in *hex)
                config.hex.publish = publish.type == JSONType.true_;
            if (auto name = "name" in *hex)
                config.hex.name = name.str;
            if (auto version_ = "version" in *hex)
                config.hex.version_ = version_.str;
            if (auto description = "description" in *hex)
                config.hex.description = description.str;
            if (auto licenses = "licenses" in *hex)
                config.hex.licenses = licenses.array.map!(e => e.str).array;
            if (auto repository = "repository" in *hex)
                config.hex.repository = repository.str;
        }
        
        // Build options
        if (auto warningsAsErrors = "warningsAsErrors" in json)
            config.warningsAsErrors = warningsAsErrors.type == JSONType.true_;
        if (auto verbose = "verbose" in json)
            config.verbose = verbose.type == JSONType.true_;
        if (auto force = "force" in json)
            config.force = force.type == JSONType.true_;
        if (auto outputDir = "outputDir" in json)
            config.outputDir = outputDir.str;
        
        // Environment variables
        if (auto env = "env" in json)
        {
            if (env.type == JSONType.object)
            {
                foreach (string key, ref value; env.object)
                    config.env[key] = value.str;
            }
        }
        
        return config;
    }
}

