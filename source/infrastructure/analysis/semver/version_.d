module infrastructure.analysis.semver.version_;

import std.conv : to;
import std.string : split, strip, indexOf;
import std.algorithm : map, all, cmp;
import std.array : array;
import std.ascii : isDigit;
import infrastructure.errors;

/// Semantic version following SemVer 2.0.0 spec
/// Immutable, hashable, comparable
struct SemVer
{
    uint major;
    uint minor;
    uint patch;
    string prerelease;  // e.g., "alpha.1", "beta", "rc.2"
    string build;       // e.g., "20130313144700"
    
    /// Zero version (0.0.0)
    static immutable SemVer zero = SemVer(0, 0, 0);
    
    /// Maximum version for unbounded ranges
    static immutable SemVer max = SemVer(uint.max, uint.max, uint.max);
    
    /// Parse version string (e.g., "1.2.3-alpha+build")
    static BuildResult!SemVer parse(string s) @trusted
    {
        if (s.length == 0)
            return Err!(SemVer, BuildError)(parseError("Empty version string"));
        
        // Strip leading 'v' if present
        if (s[0] == 'v' || s[0] == 'V')
            s = s[1 .. $];
        
        // Split off build metadata first (+...)
        string build;
        auto buildIdx = s.indexOf('+');
        if (buildIdx >= 0)
        {
            build = s[buildIdx + 1 .. $];
            s = s[0 .. buildIdx];
        }
        
        // Split off prerelease (-...)
        string prerelease;
        auto preIdx = s.indexOf('-');
        if (preIdx >= 0)
        {
            prerelease = s[preIdx + 1 .. $];
            s = s[0 .. preIdx];
        }
        
        // Parse major.minor.patch
        auto parts = s.split(".");
        if (parts.length == 0 || parts.length > 3)
            return Err!(SemVer, BuildError)(parseError("Invalid version format: " ~ s));
        
        // Validate and parse numeric parts
        uint[3] nums;
        foreach (i, part; parts)
        {
            if (part.length == 0 || !part.all!isDigit)
                return Err!(SemVer, BuildError)(parseError("Invalid version component: " ~ part));
            
            try
                nums[i] = part.to!uint;
            catch (Exception)
                return Err!(SemVer, BuildError)(parseError("Version overflow: " ~ part));
        }
        
        return Ok!(SemVer, BuildError)(SemVer(nums[0], nums[1], nums[2], prerelease, build));
    }
    
    /// Comparison (prerelease < release, lexicographic prerelease comparison)
    int opCmp(const SemVer other) const pure @safe
    {
        // Compare major.minor.patch
        if (auto c = cmp([major, minor, patch], [other.major, other.minor, other.patch]))
            return c;
        
        // Both have prerelease: compare lexicographically by components
        if (prerelease.length > 0 && other.prerelease.length > 0)
            return comparePrerelease(prerelease, other.prerelease);
        
        // Prerelease < release
        if (prerelease.length > 0) return -1;
        if (other.prerelease.length > 0) return 1;
        
        return 0;
    }
    
    /// Equality (ignores build metadata per SemVer spec)
    bool opEquals(const SemVer other) const pure nothrow @safe
        => major == other.major && minor == other.minor && 
           patch == other.patch && prerelease == other.prerelease;
    
    /// Hash for use in associative arrays
    size_t toHash() const pure nothrow @safe
    {
        size_t h = major;
        h = h * 31 + minor;
        h = h * 31 + patch;
        foreach (c; prerelease)
            h = h * 31 + c;
        return h;
    }
    
    /// Format as string (e.g., "1.2.3-alpha+build")
    string toString() const pure @safe
    {
        string s = major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
        if (prerelease.length > 0)
            s ~= "-" ~ prerelease;
        if (build.length > 0)
            s ~= "+" ~ build;
        return s;
    }
    
    /// Check if this is a prerelease version
    bool isPrerelease() const pure nothrow @safe => prerelease.length > 0;
    
    /// Increment major version (resets minor, patch, prerelease)
    SemVer bumpMajor() const pure nothrow @safe => SemVer(major + 1, 0, 0);
    
    /// Increment minor version (resets patch, prerelease)
    SemVer bumpMinor() const pure nothrow @safe => SemVer(major, minor + 1, 0);
    
    /// Increment patch version (resets prerelease)
    SemVer bumpPatch() const pure nothrow @safe => SemVer(major, minor, patch + 1);
    
private:
    /// Compare prerelease identifiers per SemVer spec
    static int comparePrerelease(string a, string b) pure @safe
    {
        auto aParts = splitSafe(a, '.');
        auto bParts = splitSafe(b, '.');
        
        size_t len = aParts.length < bParts.length ? aParts.length : bParts.length;
        
        foreach (i; 0 .. len)
        {
            auto ap = aParts[i];
            auto bp = bParts[i];
            
            bool aNum = ap.length > 0 && ap.all!isDigit;
            bool bNum = bp.length > 0 && bp.all!isDigit;
            
            // Numeric < alphanumeric
            if (aNum && !bNum) return -1;
            if (!aNum && bNum) return 1;
            
            if (aNum && bNum)
            {
                // Compare numerically
                uint aVal, bVal;
                try { aVal = ap.to!uint; bVal = bp.to!uint; } catch (Exception) {}
                if (aVal != bVal) return aVal < bVal ? -1 : 1;
            }
            else
            {
                // Compare lexicographically
                if (auto c = cmp(ap, bp))
                    return c;
            }
        }
        
        // Longer prerelease has higher precedence
        return cmp([aParts.length], [bParts.length]);
    }
    
    /// Safe split without allocating on empty
    static string[] splitSafe(string s, char delim) pure nothrow @safe
    {
        if (s.length == 0) return [];
        
        string[] parts;
        size_t start = 0;
        
        foreach (i, c; s)
        {
            if (c == delim)
            {
                parts ~= s[start .. i];
                start = i + 1;
            }
        }
        parts ~= s[start .. $];
        return parts;
    }
    
    static BuildError parseError(string msg) @trusted
        => Errors.parse("", msg, Parse.InvalidConfiguration).build();
}

/// Package identifier with optional source
struct PackageId
{
    string name;
    string source;  // "npm", "cargo", "pypi", etc.
    
    bool opEquals(const PackageId other) const pure nothrow @safe
        => name == other.name && source == other.source;
    
    size_t toHash() const pure nothrow @safe
    {
        size_t h = 0;
        foreach (c; name) h = h * 31 + c;
        foreach (c; source) h = h * 31 + c;
        return h;
    }
    
    string toString() const pure @safe
        => source.length > 0 ? source ~ ":" ~ name : name;
}

/// Package version - unique identifier for a specific release
struct PackageVersion
{
    PackageId pkg;
    SemVer ver;
    
    bool opEquals(const PackageVersion other) const pure nothrow @safe
        => pkg == other.pkg && ver == other.ver;
    
    size_t toHash() const pure nothrow @safe
        => pkg.toHash() * 31 + ver.toHash();
    
    string toString() const pure @safe
        => pkg.toString() ~ "@" ~ ver.toString();
}

unittest
{
    // Basic parsing
    auto v1 = SemVer.parse("1.2.3").unwrap();
    assert(v1.major == 1 && v1.minor == 2 && v1.patch == 3);
    
    // With prerelease
    auto v2 = SemVer.parse("1.0.0-alpha").unwrap();
    assert(v2.isPrerelease);
    assert(v2.prerelease == "alpha");
    
    // With build metadata
    auto v3 = SemVer.parse("1.0.0+build123").unwrap();
    assert(v3.build == "build123");
    
    // Full version
    auto v4 = SemVer.parse("v2.1.0-rc.1+20240101").unwrap();
    assert(v4.major == 2 && v4.prerelease == "rc.1" && v4.build == "20240101");
    
    // Comparison
    assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("2.0.0").unwrap());
    assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("1.1.0").unwrap());
    assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("1.0.1").unwrap());
    assert(SemVer.parse("1.0.0-alpha").unwrap() < SemVer.parse("1.0.0").unwrap());
    assert(SemVer.parse("1.0.0-alpha").unwrap() < SemVer.parse("1.0.0-beta").unwrap());
    
    // Equality ignores build
    assert(SemVer.parse("1.0.0+a").unwrap() == SemVer.parse("1.0.0+b").unwrap());
}

