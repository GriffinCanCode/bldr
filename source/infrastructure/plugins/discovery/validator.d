module infrastructure.plugins.discovery.validator;

import std.algorithm : canFind, splitter, startsWith;
import std.string : strip;
import std.range : empty;
import std.conv : to;
import std.file : exists, isFile;
import std.array : array;
import infrastructure.plugins.protocol;
import infrastructure.utils.simd.strings : SIMDStrings;
import infrastructure.errors;

/// Semantic version structure
struct SemanticVersion {
    int major;
    int minor;
    int patch;
    
    this(int major, int minor, int patch) pure nothrow @nogc @safe {
        this.major = major;
        this.minor = minor;
        this.patch = patch;
    }
    
    /// Parse semantic version from string
    static BuildResult!SemanticVersion parse(string ver) @system {
        import std.array : split;
        
        try {
            auto cleaned = ver.strip();
            // Strip leading operators for parsing (SIMD-accelerated)
            foreach (prefix; [">=", "<=", ">", "<", "=", "^", "~"])
                if (SIMDStrings.startsWith(cleaned, prefix))
                    cleaned = cleaned[prefix.length .. $].strip();
            
            auto parts = cleaned.split(".");
            if (parts.length < 2 || parts.length > 3)
                return Err!(SemanticVersion, BuildError)(
                    Errors.plugin("Invalid version format: " ~ ver, ErrorCode.InvalidFieldValue)
                        .withSuggestion("Use semantic versioning format: MAJOR.MINOR.PATCH"));
            
            int major = parts[0].to!int;
            int minor = parts[1].to!int;
            int patch = parts.length == 3 ? parts[2].to!int : 0;
            
            return Ok!(SemanticVersion, BuildError)(SemanticVersion(major, minor, patch));
        } catch (Exception e) {
            return Err!(SemanticVersion, BuildError)(
                Errors.plugin("Failed to parse version: " ~ ver ~ " - " ~ e.msg, ErrorCode.InvalidFieldValue));
        }
    }
    
    /// Compare versions
    int opCmp(SemanticVersion other) const pure nothrow @nogc @safe {
        if (major != other.major) return major - other.major;
        if (minor != other.minor) return minor - other.minor;
        return patch - other.patch;
    }
    
    /// Equality comparison
    bool opEquals(SemanticVersion other) const pure nothrow @nogc @safe {
        return major == other.major && minor == other.minor && patch == other.patch;
    }
    
    string toString() const pure @safe {
        return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
    }
}

/// Version range constraint for flexible version matching
struct VersionRange {
    SemanticVersion minVersion;
    SemanticVersion maxVersion;
    bool minInclusive = true;
    bool maxInclusive = false;
    bool hasMin = false;
    bool hasMax = false;
    
    /// Parse version range from string (e.g., ">=1.0.0 <2.0.0", "^1.0.0", "~1.2.0")
    static BuildResult!VersionRange parse(string range) @system {
        VersionRange result;
        auto trimmed = range.strip();
        
        if (trimmed.empty) {
            // Empty range matches all versions
            return Ok!(VersionRange, BuildError)(result);
        }
        
        // Handle caret (^) - compatible with version (same major) (SIMD-accelerated)
        if (SIMDStrings.startsWith(trimmed, "^")) {
            auto verResult = SemanticVersion.parse(trimmed[1 .. $]);
            if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
            auto ver = verResult.unwrap();
            result.minVersion = ver;
            result.maxVersion = SemanticVersion(ver.major + 1, 0, 0);
            result.hasMin = result.hasMax = true;
            result.minInclusive = true;
            result.maxInclusive = false;
            return Ok!(VersionRange, BuildError)(result);
        }
        
        // Handle tilde (~) - compatible with minor version (SIMD-accelerated)
        if (SIMDStrings.startsWith(trimmed, "~")) {
            auto verResult = SemanticVersion.parse(trimmed[1 .. $]);
            if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
            auto ver = verResult.unwrap();
            result.minVersion = ver;
            result.maxVersion = SemanticVersion(ver.major, ver.minor + 1, 0);
            result.hasMin = result.hasMax = true;
            result.minInclusive = true;
            result.maxInclusive = false;
            return Ok!(VersionRange, BuildError)(result);
        }
        
        // Handle space-separated constraints (e.g., ">=1.0.0 <2.0.0")
        foreach (part; trimmed.splitter(" ")) {
            auto p = part.strip();
            if (p.empty) continue;
            
            if (SIMDStrings.startsWith(p, ">=")) {
                auto verResult = SemanticVersion.parse(p[2 .. $]);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.minVersion = verResult.unwrap();
                result.hasMin = true;
                result.minInclusive = true;
            } else if (SIMDStrings.startsWith(p, ">")) {
                auto verResult = SemanticVersion.parse(p[1 .. $]);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.minVersion = verResult.unwrap();
                result.hasMin = true;
                result.minInclusive = false;
            } else if (SIMDStrings.startsWith(p, "<=")) {
                auto verResult = SemanticVersion.parse(p[2 .. $]);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.maxVersion = verResult.unwrap();
                result.hasMax = true;
                result.maxInclusive = true;
            } else if (SIMDStrings.startsWith(p, "<")) {
                auto verResult = SemanticVersion.parse(p[1 .. $]);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.maxVersion = verResult.unwrap();
                result.hasMax = true;
                result.maxInclusive = false;
            } else if (SIMDStrings.startsWith(p, "=")) {
                auto verResult = SemanticVersion.parse(p[1 .. $]);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.minVersion = result.maxVersion = verResult.unwrap();
                result.hasMin = result.hasMax = true;
                result.minInclusive = result.maxInclusive = true;
            } else {
                // Plain version - exact match
                auto verResult = SemanticVersion.parse(p);
                if (verResult.isErr) return Err!(VersionRange, BuildError)(verResult.unwrapErr());
                result.minVersion = result.maxVersion = verResult.unwrap();
                result.hasMin = result.hasMax = true;
                result.minInclusive = result.maxInclusive = true;
            }
        }
        
        return Ok!(VersionRange, BuildError)(result);
    }
    
    /// Check if a version satisfies this range
    bool satisfies(SemanticVersion ver) const pure nothrow @nogc @safe {
        if (hasMin) {
            int cmp = ver.opCmp(minVersion);
            if (minInclusive ? cmp < 0 : cmp <= 0) return false;
        }
        if (hasMax) {
            int cmp = ver.opCmp(maxVersion);
            if (maxInclusive ? cmp > 0 : cmp >= 0) return false;
        }
        return true;
    }
}

/// Plugin validator for checking compatibility and security
class PluginValidator {
    private string builderVersion;
    private PluginInfo[string] knownPlugins;  // For dependency validation
    
    this(string builderVersion) @safe {
        this.builderVersion = builderVersion;
    }
    
    /// Register known plugin for dependency validation
    void registerPlugin(PluginInfo info) @safe {
        knownPlugins[info.name] = info;
    }
    
    /// Validate plugin info
    VoidBuildResult validate(PluginInfo info) @system {
        // Check required fields
        if (info.name.empty)
            return VoidBuildResult.err(
                Errors.plugin("Plugin name is required", ErrorCode.InvalidFieldValue));
        
        if (info.version_.empty)
            return VoidBuildResult.err(
                Errors.plugin("Plugin version is required", ErrorCode.InvalidFieldValue));
        
        // Validate version format
        auto pluginVerResult = SemanticVersion.parse(info.version_);
        if (pluginVerResult.isErr)
            return VoidBuildResult.err(pluginVerResult.unwrapErr());
        
        // Check Builder version compatibility (min and max)
        auto compatResult = checkBuilderCompatibility(info);
        if (compatResult.isErr)
            return compatResult;
        
        // Validate capabilities
        foreach (capability; info.capabilities) {
            auto capResult = validateCapability(capability);
            if (capResult.isErr)
                return capResult;
        }
        
        // Validate plugin dependencies
        auto depResult = validateDependencies(info);
        if (depResult.isErr)
            return depResult;
        
        return Ok!BuildError();
    }
    
    /// Check if plugin is compatible with current Builder version
    private VoidBuildResult checkBuilderCompatibility(PluginInfo info) @system {
        auto currentVerResult = SemanticVersion.parse(builderVersion);
        if (currentVerResult.isErr)
            return VoidBuildResult.err(currentVerResult.unwrapErr());
        auto currentVer = currentVerResult.unwrap();
        
        // Check minimum version
        if (!info.minBuilderVersion.empty) {
            auto minVerResult = SemanticVersion.parse(info.minBuilderVersion);
            if (minVerResult.isErr)
                return VoidBuildResult.err(minVerResult.unwrapErr());
            auto minVer = minVerResult.unwrap();
            
            if (currentVer.opCmp(minVer) < 0)
                return VoidBuildResult.err(
                    Errors.plugin("Plugin '" ~ info.name ~ "' requires Builder " ~ info.minBuilderVersion ~ 
                        " or higher (current: " ~ builderVersion ~ ")", ErrorCode.IncompatibleVersion)
                        .withSuggestion("Upgrade Builder: brew upgrade builder")
                        .withSuggestion("Or use an older version of the plugin"));
        }
        
        // Check maximum version
        if (!info.maxBuilderVersion.empty) {
            auto maxVerResult = SemanticVersion.parse(info.maxBuilderVersion);
            if (maxVerResult.isErr)
                return VoidBuildResult.err(maxVerResult.unwrapErr());
            auto maxVer = maxVerResult.unwrap();
            
            if (currentVer.opCmp(maxVer) > 0)
                return VoidBuildResult.err(
                    Errors.plugin("Plugin '" ~ info.name ~ "' is not compatible with Builder " ~ builderVersion ~ 
                        " (max supported: " ~ info.maxBuilderVersion ~ ")", ErrorCode.IncompatibleVersion)
                        .withSuggestion("Downgrade Builder or upgrade the plugin")
                        .withSuggestion("Check for a newer version: brew upgrade builder-plugin-" ~ info.name));
        }
        
        return Ok!BuildError();
    }
    
    /// Validate plugin dependencies
    private VoidBuildResult validateDependencies(PluginInfo info) @system {
        foreach (dep; info.dependencies) {
            auto known = dep.name in knownPlugins;
            
            if (known is null) {
                if (!dep.optional)
                    return VoidBuildResult.err(
                        Errors.plugin("Plugin '" ~ info.name ~ "' requires plugin '" ~ dep.name ~ 
                            "' which is not installed", ErrorCode.PluginNotFound)
                            .withSuggestion("Install the dependency: brew install builder-plugin-" ~ dep.name));
                continue;
            }
            
            // Validate version constraint
            auto rangeResult = VersionRange.parse(dep.versionRange);
            if (rangeResult.isErr)
                return VoidBuildResult.err(rangeResult.unwrapErr());
            
            auto verResult = SemanticVersion.parse((*known).version_);
            if (verResult.isErr)
                return VoidBuildResult.err(verResult.unwrapErr());
            
            if (!rangeResult.unwrap().satisfies(verResult.unwrap()))
                return VoidBuildResult.err(
                    Errors.plugin("Plugin '" ~ info.name ~ "' requires '" ~ dep.name ~ "' " ~ 
                        dep.versionRange ~ " but found " ~ (*known).version_, ErrorCode.PluginVersionMismatch)
                        .withSuggestion("Upgrade plugin: brew upgrade builder-plugin-" ~ dep.name));
        }
        
        return Ok!BuildError();
    }
    
    /// Validate capability string
    private VoidBuildResult validateCapability(string capability) @system {
        static immutable validCapabilities = [
            "build.pre_hook", "build.post_hook", "target.custom_type",
            "artifact.processor", "command.custom", "config.provider"
        ];
        
        bool valid = false;
        foreach (validCap; validCapabilities) {
            if (capability == validCap || SIMDStrings.startsWith(capability, validCap ~ ".")) {
                valid = true;
                break;
            }
        }
        
        if (!valid)
            return VoidBuildResult.err(
                Errors.plugin("Unknown capability: " ~ capability, ErrorCode.InvalidFieldValue)
                    .withSuggestion("Valid capabilities: " ~ validCapabilities.to!string));
        
        return Ok!BuildError();
    }
    
    /// Validate plugin executable
    static VoidBuildResult validateExecutable(string pluginPath) @system {
        if (!exists(pluginPath))
            return VoidBuildResult.err(
                Errors.plugin("Plugin executable not found: " ~ pluginPath, ErrorCode.ToolNotFound));
        
        if (!isFile(pluginPath))
            return VoidBuildResult.err(
                Errors.plugin("Plugin path is not a file: " ~ pluginPath, ErrorCode.InvalidInput));
        
        version(Posix) {
            import core.sys.posix.sys.stat;
            import std.string : toStringz;
            
            stat_t statbuf;
            if (stat(pluginPath.toStringz(), &statbuf) == 0) {
                if ((statbuf.st_mode & S_IXUSR) == 0)
                    return VoidBuildResult.err(
                        Errors.plugin("Plugin is not executable: " ~ pluginPath, ErrorCode.InvalidInput)
                            .withSuggestion("Make it executable: chmod +x " ~ pluginPath));
            }
        }
        
        return Ok!BuildError();
    }
}

// Unit tests
unittest {
    // Test semantic version parsing
    auto v1 = SemanticVersion.parse("1.2.3");
    assert(v1.isOk);
    assert(v1.unwrap().major == 1);
    assert(v1.unwrap().minor == 2);
    assert(v1.unwrap().patch == 3);
    
    auto v2 = SemanticVersion.parse("2.0");
    assert(v2.isOk);
    assert(v2.unwrap().major == 2);
    assert(v2.unwrap().minor == 0);
    assert(v2.unwrap().patch == 0);
}

unittest {
    // Test version comparison
    auto v1 = SemanticVersion(1, 0, 0);
    auto v2 = SemanticVersion(1, 5, 0);
    auto v3 = SemanticVersion(2, 0, 0);
    
    assert(v2.opCmp(v1) > 0);  // v2 > v1
    assert(v3.opCmp(v2) > 0);  // v3 > v2
    assert(v1.opCmp(v3) < 0);  // v1 < v3
    assert(v1 == SemanticVersion(1, 0, 0));
}

unittest {
    // Test version range parsing - caret notation
    auto caretRange = VersionRange.parse("^1.2.3");
    assert(caretRange.isOk);
    auto range = caretRange.unwrap();
    assert(range.satisfies(SemanticVersion(1, 2, 3)));
    assert(range.satisfies(SemanticVersion(1, 9, 0)));
    assert(!range.satisfies(SemanticVersion(2, 0, 0)));
    assert(!range.satisfies(SemanticVersion(1, 2, 2)));
}

unittest {
    // Test version range parsing - tilde notation
    auto tildeRange = VersionRange.parse("~1.2.0");
    assert(tildeRange.isOk);
    auto range = tildeRange.unwrap();
    assert(range.satisfies(SemanticVersion(1, 2, 0)));
    assert(range.satisfies(SemanticVersion(1, 2, 9)));
    assert(!range.satisfies(SemanticVersion(1, 3, 0)));
}

unittest {
    // Test version range parsing - explicit range
    auto explicitRange = VersionRange.parse(">=1.0.0 <2.0.0");
    assert(explicitRange.isOk);
    auto range = explicitRange.unwrap();
    assert(range.satisfies(SemanticVersion(1, 0, 0)));
    assert(range.satisfies(SemanticVersion(1, 5, 0)));
    assert(range.satisfies(SemanticVersion(1, 9, 9)));
    assert(!range.satisfies(SemanticVersion(0, 9, 9)));
    assert(!range.satisfies(SemanticVersion(2, 0, 0)));
}

unittest {
    // Test empty range matches all
    auto emptyRange = VersionRange.parse("");
    assert(emptyRange.isOk);
    auto range = emptyRange.unwrap();
    assert(range.satisfies(SemanticVersion(0, 0, 1)));
    assert(range.satisfies(SemanticVersion(999, 0, 0)));
}

