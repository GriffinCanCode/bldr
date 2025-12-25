module infrastructure.toolchain.registry.registry;

import std.algorithm : canFind, filter;
import std.array : array, empty;
import std.conv : to;
import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.toolchain.detection.detector;
import infrastructure.toolchain.providers.providers;
import infrastructure.toolchain.registry.constraints;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Toolchain registry - central repository for all toolchains
/// Singleton pattern with lazy initialization
class ToolchainRegistry
{
    private static ToolchainRegistry instance_;
    private Toolchain[] toolchains;
    private Toolchain[string] byId;
    private AutoDetector detector;
    private ToolchainProvider[] providers;
    private bool initialized;
    
    private this()
    {
        detector = new AutoDetector();
    }
    
    /// Get registry instance (singleton)
    static ToolchainRegistry instance() @system
    {
        if (instance_ is null)
            instance_ = new ToolchainRegistry();
        return instance_;
    }
    
    /// Initialize registry with toolchain detection
    void initialize() @system
    {
        if (initialized)
            return;
        
        Logger.debugLog("Initializing toolchain registry...");
        
        // Auto-detect toolchains
        auto detected = detector.detectAll();
        
        foreach (tc; detected)
        {
            register(tc);
        }
        
        Logger.debugLog("Registered " ~ toolchains.length.to!string ~ " toolchain(s)");
        initialized = true;
    }
    
    /// Register a toolchain
    void register(Toolchain toolchain) @system
    {
        if (toolchain.id in byId)
        {
            Logger.warning("Toolchain already registered: " ~ toolchain.id);
            return;
        }
        
        toolchains ~= toolchain;
        byId[toolchain.id] = toolchain;
        
        Logger.debugLog("Registered toolchain: " ~ toolchain.id);
    }
    
    /// Get toolchain by ID
    BuildResult!Toolchain get(string id) @system
    {
        if (!initialized)
            initialize();
        
        auto tc = id in byId;
        if (tc is null)
        {
            return Err!(Toolchain, BuildError)(
                new SystemError("Toolchain not found: " ~ id, ErrorCode.ToolNotFound));
        }
        
        return Ok!(Toolchain, BuildError)(*tc);
    }
    
    /// Get toolchain by name (may return multiple versions)
    Toolchain[] getByName(string name) @system
    {
        if (!initialized)
            initialize();
        
        return toolchains.filter!(tc => tc.name == name).array;
    }
    
    /// Find toolchain for platform and type
    BuildResult!Toolchain findFor(
        Platform platform, 
        ToolchainType type = ToolchainType.Compiler
    ) @system
    {
        if (!initialized)
            initialize();
        
        // Look for exact match first
        foreach (tc; toolchains)
        {
            if (tc.target == platform)
            {
                auto tool = tc.getTool(type);
                if (tool !is null)
                    return Ok!(Toolchain, BuildError)(tc);
            }
        }
        
        // Look for compatible match
        foreach (tc; toolchains)
        {
            if (tc.target.compatibleWith(platform))
            {
                auto tool = tc.getTool(type);
                if (tool !is null)
                    return Ok!(Toolchain, BuildError)(tc);
            }
        }
        
        return Err!(Toolchain, BuildError)(
            new SystemError(
                "No toolchain found for platform: " ~ platform.toTriple(), 
                ErrorCode.ToolNotFound));
    }
    
    /// Resolve toolchain reference
    BuildResult!Toolchain resolve(ToolchainRef ref_) @system
    {
        if (!initialized)
            initialize();
        
        if (ref_.isExternal)
        {
            // External toolchains (@toolchains//...)
            // For now, treat as named lookup
            // Future: fetch from external repository
            return get(ref_.name);
        }
        else
        {
            // Local toolchain by name
            auto tcs = getByName(ref_.name);
            if (tcs.empty)
            {
                return Err!(Toolchain, BuildError)(
                    new SystemError("Toolchain not found: " ~ ref_.name, ErrorCode.ToolNotFound));
            }
            
            // Return latest version
            return Ok!(Toolchain, BuildError)(tcs[$ - 1]);
        }
    }
    
    /// List all registered toolchains
    const(Toolchain)[] list() const @safe
    {
        return toolchains;
    }
    
    /// List toolchains for platform
    Toolchain[] listFor(Platform platform) @system
    {
        if (!initialized)
            initialize();
        
        return toolchains.filter!(tc => 
            tc.target == platform || tc.target.compatibleWith(platform)
        ).array;
    }
    
    /// Check if toolchain exists
    bool exists(string id) const @safe
    {
        return (id in byId) !is null;
    }
    
    /// Clear registry (for testing)
    void clear() @system
    {
        toolchains = [];
        byId.clear();
        initialized = false;
    }
    
    /// Add custom detector
    void addDetector(ToolchainDetector detector) @system
    {
        this.detector.register(detector);
        initialized = false; // Force re-detection
    }
    
    /// Add toolchain provider (for fetching remote toolchains)
    void addProvider(ToolchainProvider provider) @system
    {
        providers ~= provider;
        initialized = false; // Force re-provision
    }
    
    /// Provision toolchains from providers (fetch if needed)
    void provision() @system
    {
        Logger.debugLog("Provisioning toolchains from providers...");
        
        foreach (provider; providers)
        {
            if (!provider.available())
                continue;
            
            try
            {
                auto result = provider.provide();
                if (result.isErr)
                {
                    Logger.warning("Provider " ~ provider.name() ~ " failed: " ~ 
                                 result.unwrapErr().message());
                    continue;
                }
                
                auto tcs = result.unwrap();
                foreach (tc; tcs)
                {
                    register(tc);
                }
                
                Logger.debugLog("Provisioned " ~ tcs.length.to!string ~ 
                          " toolchain(s) from " ~ provider.name());
            }
            catch (Exception e)
            {
                Logger.warning("Provider " ~ provider.name() ~ " threw: " ~ e.msg);
            }
        }
    }
    
    /// Find toolchain matching constraint
    BuildResult!Toolchain findMatching(ToolchainConstraint constraint) @system
    {
        if (!initialized)
            initialize();
        
        import infrastructure.toolchain.registry.constraints : ConstraintSolver;
        
        auto result = ConstraintSolver.solve(toolchains, constraint);
        if (result.isErr)
            return Err!(Toolchain, BuildError)(result.unwrapErr());
        
        auto tcPtr = result.unwrap();
        return Ok!(Toolchain, BuildError)(cast(Toolchain)*tcPtr);
    }
    
    /// Find all toolchains matching constraint
    Toolchain[] findAllMatching(ToolchainConstraint constraint) @system
    {
        if (!initialized)
            initialize();
        
        import infrastructure.toolchain.registry.constraints : ConstraintSolver;
        import std.algorithm : map;
        
        auto matches = ConstraintSolver.findAll(toolchains, constraint);
        return matches.map!(m => cast(Toolchain)*m).array;
    }
}

/// Convenience functions for global registry access
BuildResult!Toolchain getToolchain(string id) @system
{
    return ToolchainRegistry.instance().get(id);
}

BuildResult!Toolchain findToolchain(Platform platform, ToolchainType type = ToolchainType.Compiler) @system
{
    return ToolchainRegistry.instance().findFor(platform, type);
}

BuildResult!Toolchain resolveToolchain(ToolchainRef ref_) @system
{
    return ToolchainRegistry.instance().resolve(ref_);
}

BuildResult!Toolchain resolveToolchain(string refStr) @system
{
    auto parseResult = ToolchainRef.parse(refStr);
    if (parseResult.isErr)
        return Err!(Toolchain, BuildError)(parseResult.unwrapErr());
    
    return resolveToolchain(parseResult.unwrap());
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing toolchain registry...");
    
    auto registry = ToolchainRegistry.instance();
    registry.clear();
    registry.initialize();
    
    auto toolchains = registry.list();
    writeln("Found " ~ toolchains.length.to!string ~ " toolchain(s)");
    
    // Test platform lookup
    auto hostPlatform = Platform.host();
    auto result = registry.findFor(hostPlatform);
    
    if (result.isOk)
    {
        auto tc = result.unwrap();
        writeln("Found toolchain for host: " ~ tc.id);
    }
    else
    {
        writeln("No toolchain found for host platform");
    }
}

