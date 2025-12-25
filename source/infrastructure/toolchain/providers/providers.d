module infrastructure.toolchain.providers.providers;

import std.algorithm : map, filter;
import std.array : array, empty;
import std.path : buildPath, baseName;
import std.file : exists, dirEntries, SpanMode;
import std.string : startsWith, endsWith, strip;
import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.repository;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Toolchain provider interface
interface ToolchainProvider
{
    /// Provide toolchains (fetch if necessary)
    BuildResult!(Toolchain[]) provide() @system;
    
    /// Get provider name
    string name() const @safe;
    
    /// Check if provider is available
    bool available() @safe;
}

/// Local filesystem toolchain provider
class LocalToolchainProvider : ToolchainProvider
{
    private string path;
    private Toolchain toolchain;
    
    this(string path) @safe
    {
        this.path = path;
    }
    
    override BuildResult!(Toolchain[]) provide() @system
    {
        if (!exists(path))
        {
            return Err!(Toolchain[], BuildError)(
                new SystemError("Toolchain path does not exist: " ~ path, ErrorCode.ToolNotFound));
        }
        
        // Detect toolchain from local path
        auto tc = detectFromPath(path);
        if (tc.tools.empty)
        {
            return Err!(Toolchain[], BuildError)(
                new SystemError("No tools found in path: " ~ path, ErrorCode.ToolNotFound));
        }
        
        return Ok!(Toolchain[], BuildError)([tc]);
    }
    
    override string name() const @safe
    {
        return "local-provider";
    }
    
    override bool available() @safe
    {
        return exists(path);
    }
    
    private Toolchain detectFromPath(string rootPath) @system
    {
        Toolchain tc;
        tc.name = baseName(rootPath);
        tc.id = "local-" ~ tc.name;
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        // Scan bin/ directory for executables
        auto binPath = buildPath(rootPath, "bin");
        if (!exists(binPath))
            binPath = rootPath;
        
        try
        {
            foreach (entry; dirEntries(binPath, SpanMode.shallow))
            {
                if (!entry.isFile)
                    continue;
                
                auto tool = detectTool(entry.name);
                if (tool.type != ToolchainType.Compiler)
                    tc.tools ~= tool;
            }
        }
        catch (Exception e)
        {
            Logger.warning("Failed to scan toolchain directory: " ~ e.msg);
        }
        
        return tc;
    }
    
    private Tool detectTool(string path) @system
    {
        import std.process : execute;
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        
        Tool tool;
        tool.path = path;
        auto name = baseName(path);
        tool.name = name;
        
        // Detect tool type from name
        if (name.startsWith("gcc") || name.startsWith("g++") || name.startsWith("clang"))
            tool.type = ToolchainType.Compiler;
        else if (name.startsWith("ld") || name == "lld")
            tool.type = ToolchainType.Linker;
        else if (name == "ar" || name.endsWith("-ar"))
            tool.type = ToolchainType.Archiver;
        else if (name.startsWith("as"))
            tool.type = ToolchainType.Assembler;
        else
            tool.type = ToolchainType.BuildTool;
        
        // Detect version
        // Version detection would require executing the tool
        tool.version_ = Version();
        
        return tool;
    }
}

/// Repository-based toolchain provider
/// Fetches toolchains from external repositories
class RepositoryToolchainProvider : ToolchainProvider
{
    private RepositoryRule rule;
    private RepositoryResolver resolver;
    private ToolchainManifest manifest;
    
    this(RepositoryRule rule) @safe
    {
        this.rule = rule;
        
        // Initialize resolver with cache
        import infrastructure.repository.storage.cache : RepositoryCache;
        import infrastructure.repository.acquisition.fetcher : RepositoryFetcher;
        
        string cacheDir = ".builder-cache/repositories";
        string workspaceRoot = ".";
        this.resolver = new RepositoryResolver(cacheDir, workspaceRoot);
    }
    
    override BuildResult!(Toolchain[]) provide() @system
    {
        // Register repository rule
        auto registerResult = resolver.registerRule(rule);
        if (registerResult.isErr)
            return Err!(Toolchain[], BuildError)(
                new SystemError("Failed to register repository: " ~ registerResult.unwrapErr().message(), 
                    ErrorCode.RepositoryError));
        
        // Resolve repository (fetch if needed)
        auto resolveResult = resolver.resolve("@" ~ rule.name);
        if (resolveResult.isErr)
        {
            auto err = resolveResult.unwrapErr();
            return Err!(Toolchain[], BuildError)(
                new SystemError("Failed to fetch toolchain: " ~ err.message(), ErrorCode.RepositoryError));
        }
        
        auto resolved = resolveResult.unwrap();
        
        // Load toolchain manifest
        auto manifestPath = buildPath(resolved.path, "toolchain.json");
        if (!exists(manifestPath))
        {
            // Try auto-detection if no manifest
            return autoDetectFromPath(resolved.path);
        }
        
        // Parse manifest
        auto manifestResult = ToolchainManifest.load(manifestPath);
        if (manifestResult.isErr)
        {
            return Err!(Toolchain[], BuildError)(manifestResult.unwrapErr());
        }
        
        manifest = manifestResult.unwrap();
        
        // Build toolchain from manifest
        return buildFromManifest(manifest, resolved.path);
    }
    
    override string name() const @safe
    {
        return "repository-provider";
    }
    
    override bool available() @safe
    {
        return true; // Always available (will fetch if needed)
    }
    
    private BuildResult!(Toolchain[]) autoDetectFromPath(string rootPath) @system
    {
        auto provider = new LocalToolchainProvider(rootPath);
        return provider.provide();
    }
    
    private BuildResult!(Toolchain[]) buildFromManifest(
        ToolchainManifest manifest, string rootPath) @system
    {
        Toolchain[] toolchains;
        
        foreach (ref tcDef; manifest.toolchains)
        {
            Toolchain tc;
            tc.name = tcDef.name;
            tc.id = tcDef.id.empty ? tcDef.name ~ "-" ~ tcDef.version_.toString() : tcDef.id;
            
            // Parse platform
            auto hostResult = Platform.parse(tcDef.host);
            if (hostResult.isErr)
                tc.host = Platform.host();
            else
                tc.host = hostResult.unwrap();
            
            auto targetResult = Platform.parse(tcDef.target);
            if (targetResult.isErr)
                tc.target = Platform.host();
            else
                tc.target = targetResult.unwrap();
            
            // Build tools
            foreach (ref toolDef; tcDef.tools)
            {
                Tool tool;
                tool.name = toolDef.name;
                tool.path = buildPath(rootPath, toolDef.path);
                tool.version_ = tcDef.version_;
                tool.type = toolDef.type;
                tool.capabilities = toolDef.capabilities;
                
                tc.tools ~= tool;
            }
            
            tc.env = tcDef.env;
            tc.sysroot = tcDef.sysroot.empty ? "" : buildPath(rootPath, tcDef.sysroot);
            
            toolchains ~= tc;
        }
        
        return Ok!(Toolchain[], BuildError)(toolchains);
    }
}

/// Toolchain manifest structure
struct ToolchainManifest
{
    ToolchainDefinition[] toolchains;
    
    /// Load manifest from file
    static BuildResult!ToolchainManifest load(string path) @system
    {
        import std.file : readText;
        import std.json : parseJSON, JSONException;
        
        try
        {
            auto content = readText(path);
            auto json = parseJSON(content);
            
            ToolchainManifest manifest;
            
            foreach (ref tcJson; json["toolchains"].array)
            {
                ToolchainDefinition tc;
                tc.name = tcJson["name"].str;
                
                if ("id" in tcJson.object)
                    tc.id = tcJson["id"].str;
                
                if ("host" in tcJson.object)
                    tc.host = tcJson["host"].str;
                
                if ("target" in tcJson.object)
                    tc.target = tcJson["target"].str;
                
                // Parse version
                if ("version" in tcJson.object)
                {
                    auto verResult = Version.parse(tcJson["version"].str);
                    if (verResult.isOk)
                        tc.version_ = verResult.unwrap();
                }
                
                // Parse tools
                if ("tools" in tcJson.object)
                {
                    foreach (ref toolJson; tcJson["tools"].array)
                    {
                        ToolDefinition tool;
                        tool.name = toolJson["name"].str;
                        tool.path = toolJson["path"].str;
                        tool.type = parseToolchainType(toolJson["type"].str);
                        
                        if ("capabilities" in toolJson.object)
                        {
                            foreach (ref capJson; toolJson["capabilities"].array)
                            {
                                tool.capabilities |= parseCapability(capJson.str);
                            }
                        }
                        
                        tc.tools ~= tool;
                    }
                }
                
                // Parse environment
                if ("env" in tcJson.object)
                {
                    foreach (key, ref value; tcJson["env"].object)
                    {
                        tc.env[key] = value.str;
                    }
                }
                
                if ("sysroot" in tcJson.object)
                    tc.sysroot = tcJson["sysroot"].str;
                
                manifest.toolchains ~= tc;
            }
            
            return Ok!(ToolchainManifest, BuildError)(manifest);
        }
        catch (JSONException e)
        {
            return Err!(ToolchainManifest, BuildError)(
                new SystemError("Invalid toolchain manifest: " ~ e.msg, ErrorCode.InvalidConfiguration));
        }
        catch (Exception e)
        {
            return Err!(ToolchainManifest, BuildError)(
                new SystemError("Failed to load manifest: " ~ e.msg, ErrorCode.FileNotFound));
        }
    }
}

/// Toolchain definition in manifest
struct ToolchainDefinition
{
    string name;
    string id;
    string host;
    string target;
    Version version_;
    ToolDefinition[] tools;
    string[string] env;
    string sysroot;
}

/// Tool definition in manifest
struct ToolDefinition
{
    string name;
    string path;
    ToolchainType type;
    Capability capabilities;
}

/// Parse ToolchainType from string
private ToolchainType parseToolchainType(string str) @safe
{
    import std.uni : toLower;
    
    switch (str.toLower)
    {
        case "compiler": return ToolchainType.Compiler;
        case "linker": return ToolchainType.Linker;
        case "archiver": return ToolchainType.Archiver;
        case "assembler": return ToolchainType.Assembler;
        case "interpreter": return ToolchainType.Interpreter;
        case "runtime": return ToolchainType.Runtime;
        case "buildtool": return ToolchainType.BuildTool;
        case "packagemanager": return ToolchainType.PackageManager;
        default: return ToolchainType.Compiler;
    }
}

/// Parse Capability from string
private Capability parseCapability(string str) @safe
{
    import std.uni : toLower;
    
    switch (str.toLower)
    {
        case "crosscompile": return Capability.CrossCompile;
        case "lto": return Capability.LTO;
        case "pgo": return Capability.PGO;
        case "incremental": return Capability.Incremental;
        case "modernstd": return Capability.ModernStd;
        case "debugging": return Capability.Debugging;
        case "optimization": return Capability.Optimization;
        case "sanitizers": return Capability.Sanitizers;
        case "codecoverage": return Capability.CodeCoverage;
        case "staticanalysis": return Capability.StaticAnalysis;
        case "parallel": return Capability.Parallel;
        case "distcc": return Capability.DistCC;
        case "colordiag": return Capability.ColorDiag;
        case "json": return Capability.JSON;
        case "modules": return Capability.Modules;
        case "hermetic": return Capability.Hermetic;
        default: return Capability.None;
    }
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing toolchain providers...");
    
    // Test manifest parsing
    auto manifest = `{
        "toolchains": [{
            "name": "gcc",
            "version": "11.3.0",
            "host": "x86_64-unknown-linux-gnu",
            "target": "x86_64-unknown-linux-gnu",
            "tools": [
                {
                    "name": "gcc",
                    "path": "bin/gcc",
                    "type": "compiler",
                    "capabilities": ["lto", "optimization"]
                }
            ]
        }]
    }`;
    
    // Write temp manifest
    import std.file : write, remove, tempDir;
    auto tempPath = buildPath(tempDir(), "test-toolchain.json");
    write(tempPath, manifest);
    
    auto result = ToolchainManifest.load(tempPath);
    assert(result.isOk);
    
    auto loaded = result.unwrap();
    assert(loaded.toolchains.length == 1);
    assert(loaded.toolchains[0].name == "gcc");
    
    remove(tempPath);
    
    writeln("Toolchain providers tests passed");
}

