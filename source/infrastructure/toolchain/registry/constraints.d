module infrastructure.toolchain.registry.constraints;

import std.algorithm : canFind, all, any, count;
import std.array : array, empty;
import std.string : strip;
import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.errors;

/// Toolchain constraint for selecting appropriate toolchains
struct ToolchainConstraint
{
    string name;                    // Required toolchain name (empty = any)
    VersionConstraint version_;     // Version constraint
    Platform platform;              // Required platform (optional)
    Capability requiredCaps;        // Required capabilities
    Capability forbiddenCaps;       // Forbidden capabilities
    
    /// Check if toolchain satisfies constraint
    bool satisfies(ref const Toolchain tc) const @trusted
    {
        // Name check
        if (!name.empty && tc.name != name)
            return false;
        
        // Version check
        if (!version_.satisfies(tc.compiler().version_))
            return false;
        
        // Platform check
        if (platform != Platform.init && tc.target != platform)
            return false;
        
        // Capability checks
        auto compiler = tc.compiler();
        if (compiler is null)
            return false;
        
        // Must have all required capabilities
        if ((compiler.capabilities & requiredCaps) != requiredCaps)
            return false;
        
        // Must not have any forbidden capabilities
        if ((compiler.capabilities & forbiddenCaps) != 0)
            return false;
        
        return true;
    }
    
    /// Parse constraint from string
    /// Format: "name@version" or "name@>=1.0.0" or "name@1.x"
    static BuildResult!ToolchainConstraint parse(string str) @system
    {
        import std.string : indexOf;
        
        if (str.empty)
            return Ok!(ToolchainConstraint, BuildError)(ToolchainConstraint.init);
        
        str = str.strip();
        ToolchainConstraint constraint;
        
        // Split on @ for version constraint
        auto atIdx = str.indexOf("@");
        if (atIdx >= 0)
        {
            constraint.name = str[0 .. atIdx].strip();
            auto versionStr = str[atIdx + 1 .. $].strip();
            
            auto verResult = VersionConstraint.parse(versionStr);
            if (verResult.isErr)
                return Err!(ToolchainConstraint, BuildError)(verResult.unwrapErr());
            
            constraint.version_ = verResult.unwrap();
        }
        else
        {
            // Just a name
            constraint.name = str;
        }
        
        return Ok!(ToolchainConstraint, BuildError)(constraint);
    }
    
    /// Create constraint requiring specific capabilities
    static ToolchainConstraint withCapabilities(Capability caps) pure @safe
    {
        ToolchainConstraint constraint;
        constraint.requiredCaps = caps;
        return constraint;
    }
    
    /// Create constraint for platform
    static ToolchainConstraint forPlatform(Platform platform) pure @safe
    {
        ToolchainConstraint constraint;
        constraint.platform = platform;
        return constraint;
    }
}

/// Version constraint system supporting semver ranges
struct VersionConstraint
{
    ConstraintType type;
    Version version_;
    Version maxVersion;     // For range constraints
    
    enum ConstraintType
    {
        Any,           // No constraint (*)
        Exact,         // Exact match (1.2.3)
        GreaterOrEq,   // Greater or equal (>=1.2.3)
        LessThan,      // Less than (<2.0.0)
        Range,         // Range (>=1.0.0 <2.0.0)
        Wildcard       // Wildcard (1.x, 1.2.x)
    }
    
    /// Check if version satisfies constraint
    bool satisfies(Version ver) const pure @safe
    {
        final switch (type)
        {
            case ConstraintType.Any:
                return true;
            
            case ConstraintType.Exact:
                return ver == version_;
            
            case ConstraintType.GreaterOrEq:
                return ver >= version_;
            
            case ConstraintType.LessThan:
                return ver < version_;
            
            case ConstraintType.Range:
                return ver >= version_ && ver < maxVersion;
            
            case ConstraintType.Wildcard:
                return matchesWildcard(ver);
        }
    }
    
    /// Parse version constraint from string
    static BuildResult!VersionConstraint parse(string str) @system
    {
        import std.string : startsWith, indexOf, split, strip;
        import std.algorithm : canFind;
        
        str = str.strip();
        
        if (str.empty || str == "*")
            return Ok!(VersionConstraint, BuildError)(VersionConstraint(ConstraintType.Any));
        
        // Check for wildcard (1.x or 1.2.x)
        if (str.canFind("x") || str.canFind("X"))
            return parseWildcard(str);
        
        // Check for range (>=1.0.0 <2.0.0) BEFORE checking for >= alone
        // Count occurrences manually since std.algorithm.count doesn't work with string needles
        {
            import std.string : indexOf;
            auto gePos = str.indexOf(">=");
            auto ltPos = str.indexOf("<");
            
            if (gePos >= 0 && ltPos > gePos)
            {
                // Check there's only one of each by looking for duplicates
                auto gePos2 = str.indexOf(">=", gePos + 2);
                auto ltPos2 = str.indexOf("<", ltPos + 1);
                if (gePos2 < 0 && ltPos2 < 0)
                {
                    return parseRange(str);
                }
            }
        }
        
        // Check for >= constraint
        if (str.startsWith(">="))
        {
            auto verStr = str[2 .. $].strip();
            auto verResult = Version.parse(verStr);
            if (verResult.isErr)
                return Err!(VersionConstraint, BuildError)(verResult.unwrapErr());
            
            return Ok!(VersionConstraint, BuildError)(
                VersionConstraint(ConstraintType.GreaterOrEq, verResult.unwrap()));
        }
        
        // Check for < constraint
        if (str.startsWith("<"))
        {
            auto verStr = str[1 .. $].strip();
            auto verResult = Version.parse(verStr);
            if (verResult.isErr)
                return Err!(VersionConstraint, BuildError)(verResult.unwrapErr());
            
            return Ok!(VersionConstraint, BuildError)(
                VersionConstraint(ConstraintType.LessThan, verResult.unwrap()));
        }
        
        // Exact version
        auto verResult = Version.parse(str);
        if (verResult.isErr)
            return Err!(VersionConstraint, BuildError)(verResult.unwrapErr());
        
        return Ok!(VersionConstraint, BuildError)(
            VersionConstraint(ConstraintType.Exact, verResult.unwrap()));
    }
    
    private bool matchesWildcard(Version ver) const pure @safe
    {
        // Match major version
        if (version_.major != ver.major)
            return false;
        
        // If minor is 0, only major matters (1.x)
        if (version_.minor == 0)
            return true;
        
        // Match minor version
        if (version_.minor != ver.minor)
            return false;
        
        // If patch is 0, only major.minor matters (1.2.x)
        return version_.patch == 0 || version_.patch == ver.patch;
    }
    
    private static BuildResult!VersionConstraint parseWildcard(string str) @system
    {
        import std.string : split, strip, toLower;
        import std.conv : to;
        
        str = str.toLower.strip();
        auto parts = str.split(".");
        
        VersionConstraint constraint;
        constraint.type = ConstraintType.Wildcard;
        
        // Parse major
        if (parts.length >= 1 && parts[0] != "x")
        {
            try { constraint.version_.major = parts[0].to!uint; }
            catch (Exception)
            {
                return Err!(VersionConstraint, BuildError)(
                    new SystemError("Invalid wildcard version: " ~ str, ErrorCode.InvalidInput));
            }
        }
        
        // Parse minor (if not x)
        if (parts.length >= 2 && parts[1] != "x")
        {
            try { constraint.version_.minor = parts[1].to!uint; }
            catch (Exception)
            {
                return Err!(VersionConstraint, BuildError)(
                    new SystemError("Invalid wildcard version: " ~ str, ErrorCode.InvalidInput));
            }
        }
        
        return Ok!(VersionConstraint, BuildError)(constraint);
    }
    
    private static BuildResult!VersionConstraint parseRange(string str) @system
    {
        import std.string : split, strip, startsWith;
        
        // Split on whitespace
        auto parts = str.split();
        if (parts.length != 2)
        {
            return Err!(VersionConstraint, BuildError)(
                new SystemError("Invalid range format: " ~ str, ErrorCode.InvalidInput));
        }
        
        // Parse min version (>=X.Y.Z)
        if (!parts[0].startsWith(">="))
        {
            return Err!(VersionConstraint, BuildError)(
                new SystemError("Range must start with >=", ErrorCode.InvalidInput));
        }
        
        auto minStr = parts[0][2 .. $].strip();
        auto minResult = Version.parse(minStr);
        if (minResult.isErr)
            return Err!(VersionConstraint, BuildError)(minResult.unwrapErr());
        
        // Parse max version (<X.Y.Z)
        if (!parts[1].startsWith("<"))
        {
            return Err!(VersionConstraint, BuildError)(
                new SystemError("Range must have < for upper bound", ErrorCode.InvalidInput));
        }
        
        auto maxStr = parts[1][1 .. $].strip();
        auto maxResult = Version.parse(maxStr);
        if (maxResult.isErr)
            return Err!(VersionConstraint, BuildError)(maxResult.unwrapErr());
        
        VersionConstraint constraint;
        constraint.type = ConstraintType.Range;
        constraint.version_ = minResult.unwrap();
        constraint.maxVersion = maxResult.unwrap();
        
        return Ok!(VersionConstraint, BuildError)(constraint);
    }
}

/// Constraint solver for finding best toolchain match
struct ConstraintSolver
{
    /// Find best toolchain matching constraints
    static BuildResult!(const(Toolchain)*) solve(
        const Toolchain[] toolchains,
        ToolchainConstraint constraint
    ) @system
    {
        // Filter toolchains by constraint
        const(Toolchain)*[] candidates;
        
        foreach (ref tc; toolchains)
        {
            if (constraint.satisfies(tc))
                candidates ~= &tc;
        }
        
        if (candidates.empty)
        {
            return Err!(const(Toolchain)*, BuildError)(
                new SystemError("No toolchain satisfies constraints", ErrorCode.ToolNotFound));
        }
        
        // Sort by version (newest first)
        import std.algorithm : sort;
        candidates = candidates.dup.sort!((a, b) {
            auto aComp = a.compiler();
            auto bComp = b.compiler();
            if (aComp is null || bComp is null)
                return false;
            return aComp.version_ > bComp.version_;
        }).array;
        
        // Return best match (newest version)
        return Ok!(const(Toolchain)*, BuildError)(candidates[0]);
    }
    
    /// Find all toolchains matching constraints
    static const(Toolchain)*[] findAll(
        const Toolchain[] toolchains,
        ToolchainConstraint constraint
    ) @system
    {
        const(Toolchain)*[] matches;
        
        foreach (ref tc; toolchains)
        {
            if (constraint.satisfies(tc))
                matches ~= &tc;
        }
        
        return matches;
    }
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing version constraints...");
    
    // Test exact version
    auto exact = VersionConstraint.parse("1.2.3");
    assert(exact.isOk);
    assert(exact.unwrap().satisfies(Version(1, 2, 3)));
    assert(!exact.unwrap().satisfies(Version(1, 2, 4)));
    
    // Test >= constraint
    auto gte = VersionConstraint.parse(">=1.0.0");
    assert(gte.isOk);
    assert(gte.unwrap().satisfies(Version(1, 0, 0)));
    assert(gte.unwrap().satisfies(Version(2, 0, 0)));
    assert(!gte.unwrap().satisfies(Version(0, 9, 0)));
    
    // Test wildcard
    auto wildcard = VersionConstraint.parse("1.2.x");
    assert(wildcard.isOk);
    assert(wildcard.unwrap().satisfies(Version(1, 2, 0)));
    assert(wildcard.unwrap().satisfies(Version(1, 2, 999)));
    assert(!wildcard.unwrap().satisfies(Version(1, 3, 0)));
    
    // Test range
    auto range = VersionConstraint.parse(">=1.0.0 <2.0.0");
    assert(range.isOk);
    assert(range.unwrap().satisfies(Version(1, 0, 0)));
    assert(range.unwrap().satisfies(Version(1, 9, 9)));
    assert(!range.unwrap().satisfies(Version(2, 0, 0)));
    
    writeln("Version constraint tests passed");
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing toolchain constraints...");
    
    // Create test toolchain
    Toolchain tc;
    tc.name = "gcc";
    
    Tool tool;
    tool.name = "gcc";
    tool.version_ = Version(11, 3, 0);
    tool.type = ToolchainType.Compiler;
    tool.capabilities = Capability.LTO | Capability.Optimization;
    tc.tools ~= tool;
    
    // Test name constraint
    auto nameConstraint = ToolchainConstraint.parse("gcc@>=11.0.0");
    assert(nameConstraint.isOk);
    assert(nameConstraint.unwrap().satisfies(tc));
    
    // Test capability constraint
    auto capConstraint = ToolchainConstraint.withCapabilities(Capability.LTO);
    assert(capConstraint.satisfies(tc));
    
    auto missingCap = ToolchainConstraint.withCapabilities(Capability.PGO);
    assert(!missingCap.satisfies(tc));
    
    writeln("Toolchain constraint tests passed");
}

