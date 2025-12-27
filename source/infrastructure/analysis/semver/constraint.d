module infrastructure.analysis.semver.constraint;

import std.string : strip, startsWith, indexOf;
import std.algorithm : map, filter, any, all, sort, uniq;
import std.array : array, appender;
import std.conv : to;
import infrastructure.analysis.semver.version_;
import infrastructure.errors;

/// Version range bound type
enum Bound { Inclusive, Exclusive }

/// Single version range (e.g., >=1.0.0 <2.0.0)
struct VersionRange
{
    SemVer min = SemVer.zero;
    SemVer max = SemVer.max;
    Bound minBound = Bound.Inclusive;
    Bound maxBound = Bound.Exclusive;
    
    /// Empty range (matches nothing)
    static immutable VersionRange empty = VersionRange(SemVer(1,0,0), SemVer(0,0,0));
    
    /// Universal range (matches everything)
    static immutable VersionRange any = VersionRange(SemVer.zero, SemVer.max, Bound.Inclusive, Bound.Exclusive);
    
    /// Exact version match
    static VersionRange exact(SemVer v) pure nothrow @safe
        => VersionRange(v, v, Bound.Inclusive, Bound.Inclusive);
    
    /// Greater than or equal
    static VersionRange atLeast(SemVer v) pure nothrow @safe
        => VersionRange(v, SemVer.max, Bound.Inclusive, Bound.Exclusive);
    
    /// Less than
    static VersionRange lessThan(SemVer v) pure nothrow @safe
        => VersionRange(SemVer.zero, v, Bound.Inclusive, Bound.Exclusive);
    
    /// Caret range (^1.2.3 = >=1.2.3 <2.0.0 for major>0)
    static VersionRange caret(SemVer v) pure nothrow @safe
    {
        if (v.major == 0)
        {
            if (v.minor == 0)
                return VersionRange(v, SemVer(0, 0, v.patch + 1));
            return VersionRange(v, SemVer(0, v.minor + 1, 0));
        }
        return VersionRange(v, SemVer(v.major + 1, 0, 0));
    }
    
    /// Tilde range (~1.2.3 = >=1.2.3 <1.3.0)
    static VersionRange tilde(SemVer v) pure nothrow @safe
        => VersionRange(v, SemVer(v.major, v.minor + 1, 0));
    
    /// Check if version satisfies this range
    bool contains(SemVer v) const pure nothrow @safe
    {
        // Check minimum
        int minCmp = v.opCmp(min);
        if (minBound == Bound.Inclusive ? minCmp < 0 : minCmp <= 0)
            return false;
        
        // Check maximum
        int maxCmp = v.opCmp(max);
        if (maxBound == Bound.Inclusive ? maxCmp > 0 : maxCmp >= 0)
            return false;
        
        return true;
    }
    
    /// Check if range is empty (matches nothing)
    bool isEmpty() const pure nothrow @safe
    {
        int cmp = min.opCmp(max);
        if (cmp > 0) return true;
        if (cmp == 0) return minBound == Bound.Exclusive || maxBound == Bound.Exclusive;
        return false;
    }
    
    /// Intersect with another range
    VersionRange intersect(VersionRange other) const pure nothrow @safe
    {
        // Compute new min
        SemVer newMin;
        Bound newMinBound;
        int minCmp = min.opCmp(other.min);
        if (minCmp > 0)
        {
            newMin = min;
            newMinBound = minBound;
        }
        else if (minCmp < 0)
        {
            newMin = other.min;
            newMinBound = other.minBound;
        }
        else
        {
            newMin = min;
            // Exclusive wins over inclusive at same point
            newMinBound = (minBound == Bound.Exclusive || other.minBound == Bound.Exclusive) 
                ? Bound.Exclusive : Bound.Inclusive;
        }
        
        // Compute new max
        SemVer newMax;
        Bound newMaxBound;
        int maxCmp = max.opCmp(other.max);
        if (maxCmp < 0)
        {
            newMax = max;
            newMaxBound = maxBound;
        }
        else if (maxCmp > 0)
        {
            newMax = other.max;
            newMaxBound = other.maxBound;
        }
        else
        {
            newMax = max;
            newMaxBound = (maxBound == Bound.Exclusive || other.maxBound == Bound.Exclusive)
                ? Bound.Exclusive : Bound.Inclusive;
        }
        
        return VersionRange(newMin, newMax, newMinBound, newMaxBound);
    }
    
    /// Check if ranges overlap
    bool overlaps(VersionRange other) const pure nothrow @safe
        => !intersect(other).isEmpty();
    
    /// String representation
    string toString() const pure @safe
    {
        if (isEmpty()) return "empty";
        if (min == SemVer.zero && max == SemVer.max) return "*";
        if (min == max && minBound == Bound.Inclusive && maxBound == Bound.Inclusive)
            return "=" ~ min.toString();
        
        auto result = appender!string;
        if (min != SemVer.zero)
            result ~= (minBound == Bound.Inclusive ? ">=" : ">") ~ min.toString();
        if (max != SemVer.max)
        {
            if (result[].length > 0) result ~= " ";
            result ~= (maxBound == Bound.Inclusive ? "<=" : "<") ~ max.toString();
        }
        return result[];
    }
}

/// Disjunction of version ranges (union)
/// Represents complex constraints like ">=1.0.0 <2.0.0 || >=3.0.0"
struct VersionConstraint
{
    VersionRange[] ranges;
    
    /// Create from single range
    this(VersionRange r) pure nothrow @safe { ranges = [r]; }
    
    /// Create from array of ranges
    this(VersionRange[] rs) pure nothrow @safe { ranges = rs; }
    
    /// Empty constraint (matches nothing)
    static immutable VersionConstraint empty;
    
    /// Universal constraint (matches everything)
    static VersionConstraint any() pure nothrow @safe
        => VersionConstraint(VersionRange.any);
    
    /// Exact version
    static VersionConstraint exact(SemVer v) pure nothrow @safe
        => VersionConstraint(VersionRange.exact(v));
    
    /// Parse constraint from string (npm/cargo/pip compatible)
    static BuildResult!VersionConstraint parse(string s) @safe
    {
        s = s.strip;
        if (s.length == 0 || s == "*" || s == "latest")
            return Ok!(VersionConstraint, BuildError)(VersionConstraint.any());
        
        VersionRange[] ranges;
        
        // Split on || for union
        foreach (part; splitOr(s))
        {
            auto rangeResult = parseRange(part.strip);
            if (rangeResult.isErr)
                return Err!(VersionConstraint, BuildError)(rangeResult.unwrapErr());
            ranges ~= rangeResult.unwrap();
        }
        
        if (ranges.length == 0)
            return Err!(VersionConstraint, BuildError)(
                Errors.parse("", "Empty constraint", Parse.InvalidConfiguration).build());
        
        return Ok!(VersionConstraint, BuildError)(VersionConstraint(ranges));
    }
    
    /// Check if version satisfies constraint
    bool allows(SemVer v) const pure nothrow @safe
        => ranges.any!(r => r.contains(v));
    
    /// Check if any version in other constraint is allowed
    bool allowsAny(VersionConstraint other) const pure nothrow @safe
    {
        foreach (r1; ranges)
            foreach (r2; other.ranges)
                if (r1.overlaps(r2))
                    return true;
        return false;
    }
    
    /// Check if all versions in other constraint are allowed
    bool allowsAll(VersionConstraint other) const pure nothrow @safe
    {
        foreach (r2; other.ranges)
        {
            bool covered;
            foreach (r1; ranges)
                if (r1.intersect(r2) == r2)
                    covered = true;
            if (!covered) return false;
        }
        return true;
    }
    
    /// Intersect with another constraint
    VersionConstraint intersect(VersionConstraint other) const pure nothrow @safe
    {
        VersionRange[] result;
        foreach (r1; ranges)
            foreach (r2; other.ranges)
            {
                auto inter = r1.intersect(r2);
                if (!inter.isEmpty())
                    result ~= inter;
            }
        return VersionConstraint(result);
    }
    
    /// Union with another constraint (logical OR)
    VersionConstraint unite(VersionConstraint other) const pure nothrow @safe
        => VersionConstraint(ranges ~ other.ranges);
    
    /// Check if constraint is empty
    bool isEmpty() const pure nothrow @safe
        => ranges.length == 0 || ranges.all!(r => r.isEmpty());
    
    /// Negate constraint (complement)
    VersionConstraint negate() const pure nothrow @safe
    {
        if (isEmpty()) return VersionConstraint.any();
        if (ranges.length == 0) return VersionConstraint.any();
        
        // For single range, compute complement
        if (ranges.length == 1)
        {
            auto r = ranges[0];
            VersionRange[] neg;
            
            if (r.min != SemVer.zero)
                neg ~= VersionRange(SemVer.zero, r.min, Bound.Inclusive, 
                    r.minBound == Bound.Inclusive ? Bound.Exclusive : Bound.Inclusive);
            
            if (r.max != SemVer.max)
                neg ~= VersionRange(r.max, SemVer.max, 
                    r.maxBound == Bound.Inclusive ? Bound.Exclusive : Bound.Inclusive, Bound.Exclusive);
            
            return VersionConstraint(neg);
        }
        
        // For multiple ranges, use De Morgan's law: ~(A|B) = ~A & ~B
        auto result = ranges[0].toConstraint().negate();
        foreach (r; ranges[1 .. $])
            result = result.intersect(r.toConstraint().negate());
        return result;
    }
    
    /// String representation
    string toString() const pure @safe
    {
        if (isEmpty()) return "empty";
        if (ranges.length == 0) return "empty";
        
        string[] parts;
        foreach (r; ranges)
            parts ~= r.toString();
        
        import std.array : join;
        return parts.join(" || ");
    }
    
private:
    /// Parse single range (e.g., ">=1.0.0 <2.0.0" or "^1.2.3")
    static BuildResult!VersionRange parseRange(string s) @safe
    {
        s = s.strip;
        if (s.length == 0) return Ok!(VersionRange, BuildError)(VersionRange.any);
        
        // Caret range: ^1.2.3
        if (s[0] == '^')
        {
            auto vr = SemVer.parse(s[1 .. $]);
            if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
            return Ok!(VersionRange, BuildError)(VersionRange.caret(vr.unwrap()));
        }
        
        // Tilde range: ~1.2.3
        if (s[0] == '~')
        {
            auto vr = SemVer.parse(s[1 .. $]);
            if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
            return Ok!(VersionRange, BuildError)(VersionRange.tilde(vr.unwrap()));
        }
        
        // Exact: =1.2.3 or 1.2.3
        if (s[0] == '=')
        {
            auto vr = SemVer.parse(s[1 .. $]);
            if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
            return Ok!(VersionRange, BuildError)(VersionRange.exact(vr.unwrap()));
        }
        
        // Comparators: >=, <=, >, <
        SemVer min = SemVer.zero;
        SemVer max = SemVer.max;
        Bound minBound = Bound.Inclusive;
        Bound maxBound = Bound.Exclusive;
        
        foreach (part; splitAnd(s))
        {
            auto p = part.strip;
            if (p.length == 0) continue;
            
            if (p.startsWith(">="))
            {
                auto vr = SemVer.parse(p[2 .. $]);
                if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
                auto v = vr.unwrap();
                if (v.opCmp(min) > 0 || (v == min && minBound == Bound.Exclusive))
                {
                    min = v;
                    minBound = Bound.Inclusive;
                }
            }
            else if (p.startsWith("<="))
            {
                auto vr = SemVer.parse(p[2 .. $]);
                if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
                auto v = vr.unwrap();
                if (v.opCmp(max) < 0 || (v == max && maxBound == Bound.Exclusive))
                {
                    max = v;
                    maxBound = Bound.Inclusive;
                }
            }
            else if (p.startsWith(">"))
            {
                auto vr = SemVer.parse(p[1 .. $]);
                if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
                auto v = vr.unwrap();
                if (v.opCmp(min) >= 0)
                {
                    min = v;
                    minBound = Bound.Exclusive;
                }
            }
            else if (p.startsWith("<"))
            {
                auto vr = SemVer.parse(p[1 .. $]);
                if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
                auto v = vr.unwrap();
                if (v.opCmp(max) <= 0)
                {
                    max = v;
                    maxBound = Bound.Exclusive;
                }
            }
            else
            {
                // Bare version = exact match
                auto vr = SemVer.parse(p);
                if (vr.isErr) return Err!(VersionRange, BuildError)(vr.unwrapErr());
                return Ok!(VersionRange, BuildError)(VersionRange.exact(vr.unwrap()));
            }
        }
        
        return Ok!(VersionRange, BuildError)(VersionRange(min, max, minBound, maxBound));
    }
    
    /// Split on || for union
    static string[] splitOr(string s) pure nothrow @safe
    {
        string[] parts;
        size_t start = 0;
        
        for (size_t i = 0; i + 1 < s.length; i++)
        {
            if (s[i] == '|' && s[i+1] == '|')
            {
                parts ~= s[start .. i];
                start = i + 2;
                i++;
            }
        }
        parts ~= s[start .. $];
        return parts;
    }
    
    /// Split on space/comma for AND within a range
    static string[] splitAnd(string s) pure nothrow @safe
    {
        string[] parts;
        size_t start = 0;
        bool inVersion;
        
        foreach (i, c; s)
        {
            if (c == ' ' || c == ',')
            {
                if (start < i)
                    parts ~= s[start .. i];
                start = i + 1;
            }
        }
        if (start < s.length)
            parts ~= s[start .. $];
        
        return parts;
    }
}

/// Helper: convert range to single-range constraint
VersionConstraint toConstraint(VersionRange r) pure nothrow @safe
    => VersionConstraint(r);

unittest
{
    // Caret ranges
    auto caret = VersionConstraint.parse("^1.2.3").unwrap();
    assert(caret.allows(SemVer.parse("1.2.3").unwrap()));
    assert(caret.allows(SemVer.parse("1.9.9").unwrap()));
    assert(!caret.allows(SemVer.parse("2.0.0").unwrap()));
    
    // Tilde ranges
    auto tilde = VersionConstraint.parse("~1.2.3").unwrap();
    assert(tilde.allows(SemVer.parse("1.2.5").unwrap()));
    assert(!tilde.allows(SemVer.parse("1.3.0").unwrap()));
    
    // Comparators
    auto range = VersionConstraint.parse(">=1.0.0 <2.0.0").unwrap();
    assert(range.allows(SemVer.parse("1.5.0").unwrap()));
    assert(!range.allows(SemVer.parse("2.0.0").unwrap()));
    
    // Union
    auto union_ = VersionConstraint.parse(">=1.0.0 <2.0.0 || >=3.0.0").unwrap();
    assert(union_.allows(SemVer.parse("1.5.0").unwrap()));
    assert(!union_.allows(SemVer.parse("2.5.0").unwrap()));
    assert(union_.allows(SemVer.parse("3.0.0").unwrap()));
    
    // Intersection
    auto c1 = VersionConstraint.parse(">=1.0.0").unwrap();
    auto c2 = VersionConstraint.parse("<2.0.0").unwrap();
    auto inter = c1.intersect(c2);
    assert(inter.allows(SemVer.parse("1.5.0").unwrap()));
    assert(!inter.allows(SemVer.parse("2.5.0").unwrap()));
}

