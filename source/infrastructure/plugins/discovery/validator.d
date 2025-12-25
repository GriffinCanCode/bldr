module infrastructure.plugins.discovery.validator;

import std.algorithm : startsWith;
import std.string : strip;
import std.range : empty;
import std.conv : to;
import std.file : exists, isFile;
import infrastructure.plugins.protocol;
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
            auto parts = ver.strip().split(".");
            if (parts.length < 2 || parts.length > 3) {
                auto err = new PluginError(
                    "Invalid version format: " ~ ver,
                    ErrorCode.InvalidFieldValue
                );
                err.addSuggestion("Use semantic versioning format: MAJOR.MINOR.PATCH");
                return Err!(SemanticVersion, BuildError)(err);
            }
            
            int major = parts[0].to!int;
            int minor = parts[1].to!int;
            int patch = parts.length == 3 ? parts[2].to!int : 0;
            
            return Ok!(SemanticVersion, BuildError)(SemanticVersion(major, minor, patch));
        } catch (Exception e) {
            auto err = new PluginError(
                "Failed to parse version: " ~ ver ~ " - " ~ e.msg,
                ErrorCode.InvalidFieldValue
            );
            return Err!(SemanticVersion, BuildError)(err);
        }
    }
    
    /// Compare versions
    int opCmp(SemanticVersion other) const pure nothrow @nogc @safe {
        if (major != other.major)
            return major - other.major;
        if (minor != other.minor)
            return minor - other.minor;
        return patch - other.patch;
    }
    
    /// Compare versions (for >= checks)
    bool opBinary(string op)(SemanticVersion other) const pure nothrow @nogc @safe
        if (op == ">=" || op == ">" || op == "<=" || op == "<" || op == "==") 
    {
        if (major != other.major) {
            static if (op == ">=") return major >= other.major;
            else static if (op == ">") return major > other.major;
            else static if (op == "<=") return major <= other.major;
            else static if (op == "<") return major < other.major;
            else static if (op == "==") return false;
        }
        
        if (minor != other.minor) {
            static if (op == ">=") return minor >= other.minor;
            else static if (op == ">") return minor > other.minor;
            else static if (op == "<=") return minor <= other.minor;
            else static if (op == "<") return minor < other.minor;
            else static if (op == "==") return false;
        }
        
        static if (op == ">=") return patch >= other.patch;
        else static if (op == ">") return patch > other.patch;
        else static if (op == "<=") return patch <= other.patch;
        else static if (op == "<") return patch < other.patch;
        else static if (op == "==") return patch == other.patch;
    }
    
    string toString() const pure @safe {
        return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
    }
}

/// Plugin validator for checking compatibility and security
class PluginValidator {
    private string builderVersion;
    
    this(string builderVersion) @safe {
        this.builderVersion = builderVersion;
    }
    
    /// Validate plugin info
    VoidBuildResult validate(PluginInfo info) @system {
        // Check required fields
        if (info.name.empty) {
            auto err = new PluginError(
                "Plugin name is required",
                ErrorCode.InvalidFieldValue
            );
            return VoidBuildResult.err(err);
        }
        
        if (info.version_.empty) {
            auto err = new PluginError(
                "Plugin version is required",
                ErrorCode.InvalidFieldValue
            );
            return VoidBuildResult.err(err);
        }
        
        // Validate version format
        auto pluginVerResult = SemanticVersion.parse(info.version_);
        if (pluginVerResult.isErr) {
            return VoidBuildResult.err(pluginVerResult.unwrapErr());
        }
        
        // Check Builder version compatibility
        if (!info.minBuilderVersion.empty) {
            auto compatResult = checkVersionCompatibility(info.minBuilderVersion);
            if (compatResult.isErr) {
                return compatResult;
            }
        }
        
        // Validate capabilities
        foreach (capability; info.capabilities) {
            auto capResult = validateCapability(capability);
            if (capResult.isErr) {
                return capResult;
            }
        }
        
        return Ok!BuildError();
    }
    
    /// Check if plugin is compatible with current Builder version
    private VoidBuildResult checkVersionCompatibility(string minVersion) @system {
        auto minVerResult = SemanticVersion.parse(minVersion);
        if (minVerResult.isErr) {
            return VoidBuildResult.err(minVerResult.unwrapErr());
        }
        
        auto currentVerResult = SemanticVersion.parse(builderVersion);
        if (currentVerResult.isErr) {
            return VoidBuildResult.err(currentVerResult.unwrapErr());
        }
        
        auto minVer = minVerResult.unwrap();
        auto currentVer = currentVerResult.unwrap();
        
        if (currentVer < minVer) {
            auto err = new PluginError(
                "Plugin requires Builder " ~ minVersion ~ " or higher (current: " ~ builderVersion ~ ")",
                ErrorCode.IncompatibleVersion
            );
            err.addSuggestion("Upgrade Builder: brew upgrade builder");
            err.addSuggestion("Or use an older version of the plugin");
            return VoidBuildResult.err(err);
        }
        
        return Ok!BuildError();
    }
    
    /// Validate capability string
    private VoidBuildResult validateCapability(string capability) @system {
        import std.algorithm : among;
        
        // Known capabilities
        static immutable validCapabilities = [
            "build.pre_hook",
            "build.post_hook",
            "target.custom_type",
            "artifact.processor",
            "command.custom"
        ];
        
        // Check if capability starts with known prefix
        bool valid = false;
        foreach (validCap; validCapabilities) {
            if (capability == validCap || capability.startsWith(validCap ~ ".")) {
                valid = true;
                break;
            }
        }
        
        if (!valid) {
            auto err = new PluginError(
                "Unknown capability: " ~ capability,
                ErrorCode.InvalidFieldValue
            );
            err.addSuggestion("Valid capabilities: " ~ validCapabilities.to!string);
            return VoidBuildResult.err(err);
        }
        
        return Ok!BuildError();
    }
    
    /// Validate plugin executable
    static VoidBuildResult validateExecutable(string pluginPath) @system {
        if (!exists(pluginPath)) {
            auto err = new PluginError(
                "Plugin executable not found: " ~ pluginPath,
                ErrorCode.ToolNotFound
            );
            return VoidBuildResult.err(err);
        }
        
        if (!isFile(pluginPath)) {
            auto err = new PluginError(
                "Plugin path is not a file: " ~ pluginPath,
                ErrorCode.InvalidInput
            );
            return VoidBuildResult.err(err);
        }
        
        // Check if executable
        version(Posix) {
            import core.sys.posix.sys.stat;
            import std.string : toStringz;
            
            stat_t statbuf;
            if (stat(pluginPath.toStringz(), &statbuf) == 0) {
                if ((statbuf.st_mode & S_IXUSR) == 0) {
                    auto err = new PluginError(
                        "Plugin is not executable: " ~ pluginPath,
                        ErrorCode.InvalidInput
                    );
                    err.addSuggestion("Make it executable: chmod +x " ~ pluginPath);
                    return VoidBuildResult.err(err);
                }
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
    
    assert(v2 >= v1);
    assert(v3 > v2);
    assert(v1 < v3);
    assert(v1 == SemanticVersion(1, 0, 0));
}

