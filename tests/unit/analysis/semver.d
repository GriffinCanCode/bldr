module tests.unit.analysis.semver;

import infrastructure.analysis.semver;
import infrastructure.errors;

/// SemVer Parsing Tests
unittest
{
    // Basic version parsing
    auto v = SemVer.parse("1.2.3").unwrap();
    assert(v.major == 1);
    assert(v.minor == 2);
    assert(v.patch == 3);
    assert(!v.isPrerelease);
    
    // Version with leading 'v'
    auto v2 = SemVer.parse("v2.0.0").unwrap();
    assert(v2.major == 2);
    
    // Prerelease version
    auto v3 = SemVer.parse("1.0.0-alpha.1").unwrap();
    assert(v3.isPrerelease);
    assert(v3.prerelease == "alpha.1");
    
    // Build metadata
    auto v4 = SemVer.parse("1.0.0+build.123").unwrap();
    assert(v4.build == "build.123");
    
    // Full version
    auto v5 = SemVer.parse("2.1.0-beta.2+20240101").unwrap();
    assert(v5.major == 2);
    assert(v5.minor == 1);
    assert(v5.patch == 0);
    assert(v5.prerelease == "beta.2");
    assert(v5.build == "20240101");
    
    // Partial versions
    auto v6 = SemVer.parse("1").unwrap();
    assert(v6 == SemVer(1, 0, 0));
    
    auto v7 = SemVer.parse("1.2").unwrap();
    assert(v7 == SemVer(1, 2, 0));
}

/// SemVer Comparison Tests
unittest
{
    auto v100 = SemVer.parse("1.0.0").unwrap();
    auto v110 = SemVer.parse("1.1.0").unwrap();
    auto v101 = SemVer.parse("1.0.1").unwrap();
    auto v200 = SemVer.parse("2.0.0").unwrap();
    
    // Basic comparisons
    assert(v100 < v110);
    assert(v100 < v101);
    assert(v110 > v100);
    assert(v200 > v110);
    assert(v100 == SemVer.parse("1.0.0").unwrap());
    
    // Prerelease ordering
    auto alpha = SemVer.parse("1.0.0-alpha").unwrap();
    auto beta = SemVer.parse("1.0.0-beta").unwrap();
    auto rc = SemVer.parse("1.0.0-rc.1").unwrap();
    auto release = SemVer.parse("1.0.0").unwrap();
    
    assert(alpha < beta);
    assert(beta < rc);
    assert(rc < release);  // Prerelease < release
    
    // Numeric prerelease comparison
    auto alpha1 = SemVer.parse("1.0.0-alpha.1").unwrap();
    auto alpha2 = SemVer.parse("1.0.0-alpha.2").unwrap();
    auto alpha10 = SemVer.parse("1.0.0-alpha.10").unwrap();
    
    assert(alpha1 < alpha2);
    assert(alpha2 < alpha10);  // Numeric comparison
    
    // Build metadata ignored in comparison
    auto a = SemVer.parse("1.0.0+build1").unwrap();
    auto b = SemVer.parse("1.0.0+build2").unwrap();
    assert(a == b);
}

/// Version Bump Tests
unittest
{
    auto v = SemVer.parse("1.2.3-alpha").unwrap();
    
    assert(v.bumpMajor() == SemVer(2, 0, 0));
    assert(v.bumpMinor() == SemVer(1, 3, 0));
    assert(v.bumpPatch() == SemVer(1, 2, 4));
}

/// Version Range Tests
unittest
{
    // Exact match
    auto exact = VersionRange.exact(SemVer(1, 0, 0));
    assert(exact.contains(SemVer(1, 0, 0)));
    assert(!exact.contains(SemVer(1, 0, 1)));
    
    // At least
    auto atLeast = VersionRange.atLeast(SemVer(1, 0, 0));
    assert(atLeast.contains(SemVer(1, 0, 0)));
    assert(atLeast.contains(SemVer(2, 0, 0)));
    assert(!atLeast.contains(SemVer(0, 9, 0)));
    
    // Less than
    auto lessThan = VersionRange.lessThan(SemVer(2, 0, 0));
    assert(lessThan.contains(SemVer(1, 9, 9)));
    assert(!lessThan.contains(SemVer(2, 0, 0)));
    
    // Caret range (^1.2.3)
    auto caret = VersionRange.caret(SemVer(1, 2, 3));
    assert(caret.contains(SemVer(1, 2, 3)));
    assert(caret.contains(SemVer(1, 9, 0)));
    assert(!caret.contains(SemVer(2, 0, 0)));
    
    // Caret with 0.x.y
    auto caret0 = VersionRange.caret(SemVer(0, 2, 3));
    assert(caret0.contains(SemVer(0, 2, 5)));
    assert(!caret0.contains(SemVer(0, 3, 0)));
    
    // Tilde range (~1.2.3)
    auto tilde = VersionRange.tilde(SemVer(1, 2, 3));
    assert(tilde.contains(SemVer(1, 2, 9)));
    assert(!tilde.contains(SemVer(1, 3, 0)));
}

/// Range Intersection Tests
unittest
{
    auto r1 = VersionRange.atLeast(SemVer(1, 0, 0));
    auto r2 = VersionRange.lessThan(SemVer(2, 0, 0));
    
    auto inter = r1.intersect(r2);
    assert(inter.contains(SemVer(1, 5, 0)));
    assert(!inter.contains(SemVer(0, 9, 0)));
    assert(!inter.contains(SemVer(2, 0, 0)));
    
    // Empty intersection
    auto r3 = VersionRange.lessThan(SemVer(1, 0, 0));
    auto r4 = VersionRange.atLeast(SemVer(2, 0, 0));
    auto empty = r3.intersect(r4);
    assert(empty.isEmpty());
}

/// Constraint Parsing Tests
unittest
{
    // Wildcard
    auto any = VersionConstraint.parse("*").unwrap();
    assert(any.allows(SemVer(1, 0, 0)));
    assert(any.allows(SemVer(99, 0, 0)));
    
    // Caret
    auto caret = VersionConstraint.parse("^1.2.3").unwrap();
    assert(caret.allows(SemVer(1, 2, 3)));
    assert(caret.allows(SemVer(1, 9, 9)));
    assert(!caret.allows(SemVer(2, 0, 0)));
    
    // Tilde
    auto tilde = VersionConstraint.parse("~1.2.3").unwrap();
    assert(tilde.allows(SemVer(1, 2, 5)));
    assert(!tilde.allows(SemVer(1, 3, 0)));
    
    // Exact
    auto exact = VersionConstraint.parse("=1.2.3").unwrap();
    assert(exact.allows(SemVer(1, 2, 3)));
    assert(!exact.allows(SemVer(1, 2, 4)));
    
    // Comparators
    auto range = VersionConstraint.parse(">=1.0.0 <2.0.0").unwrap();
    assert(range.allows(SemVer(1, 0, 0)));
    assert(range.allows(SemVer(1, 9, 9)));
    assert(!range.allows(SemVer(2, 0, 0)));
    assert(!range.allows(SemVer(0, 9, 9)));
    
    // Union (||)
    auto union_ = VersionConstraint.parse(">=1.0.0 <2.0.0 || >=3.0.0").unwrap();
    assert(union_.allows(SemVer(1, 5, 0)));
    assert(!union_.allows(SemVer(2, 5, 0)));
    assert(union_.allows(SemVer(3, 0, 0)));
    assert(union_.allows(SemVer(10, 0, 0)));
}

/// Constraint Operations Tests
unittest
{
    auto c1 = VersionConstraint.parse(">=1.0.0").unwrap();
    auto c2 = VersionConstraint.parse("<2.0.0").unwrap();
    
    // Intersection
    auto inter = c1.intersect(c2);
    assert(inter.allows(SemVer(1, 5, 0)));
    assert(!inter.allows(SemVer(0, 5, 0)));
    assert(!inter.allows(SemVer(2, 5, 0)));
    
    // Union
    auto c3 = VersionConstraint.parse(">=3.0.0").unwrap();
    auto union_ = c1.intersect(c2).unite(c3);
    assert(union_.allows(SemVer(1, 5, 0)));
    assert(union_.allows(SemVer(3, 0, 0)));
    
    // allowsAny
    auto c4 = VersionConstraint.parse(">=1.5.0 <1.8.0").unwrap();
    assert(c1.allowsAny(c4));
    
    auto c5 = VersionConstraint.parse("<0.5.0").unwrap();
    assert(!c1.allowsAny(c5));
}

/// Memory Source Tests
unittest
{
    auto src = new MemorySource("test");
    
    // Add versions
    src.addVersion("foo", "1.0.0");
    src.addVersion("foo", "1.1.0");
    src.addVersion("foo", "2.0.0");
    
    // Check versions (should be sorted descending)
    auto vers = src.versions(PackageId("foo", "test")).unwrap();
    assert(vers.length == 3);
    assert(vers[0] == SemVer.parse("2.0.0").unwrap());
    assert(vers[1] == SemVer.parse("1.1.0").unwrap());
    assert(vers[2] == SemVer.parse("1.0.0").unwrap());
    
    // Check existence
    assert(src.exists(PackageId("foo", "test")));
    assert(!src.exists(PackageId("bar", "test")));
    
    // Add with dependencies
    src.addVersion("bar", "1.0.0", [
        DependencyReq(PackageId("foo", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    
    auto deps = src.dependencies(PackageVersion(PackageId("bar", "test"), SemVer.parse("1.0.0").unwrap())).unwrap();
    assert(deps.length == 1);
    assert(deps[0].pkg.name == "foo");
}

/// Cached Source Tests
unittest
{
    auto inner = new MemorySource("test");
    inner.addVersion("pkg", "1.0.0");
    
    auto cached = new CachedSource(inner);
    
    // First call - cache miss
    auto v1 = cached.versions(PackageId("pkg", "test")).unwrap();
    assert(v1.length == 1);
    
    // Second call - should be cached
    auto v2 = cached.versions(PackageId("pkg", "test")).unwrap();
    assert(v2.length == 1);
    
    // Clear and verify
    cached.clear();
}

/// Basic Solver Tests
unittest
{
    auto src = new MemorySource("test");
    
    // Simple dependency chain: A -> B -> C
    src.addVersion("A", "1.0.0", [
        DependencyReq(PackageId("B", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    src.addVersion("B", "1.0.0", [
        DependencyReq(PackageId("C", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    src.addVersion("B", "1.1.0", [
        DependencyReq(PackageId("C", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    src.addVersion("C", "1.0.0");
    src.addVersion("C", "1.1.0");
    
    auto result = solve(src, "A", "^1.0.0");
    assert(result.isOk);
    
    auto resolution = result.unwrap();
    assert(resolution.packages.length == 3);
    
    // Should pick newest compatible versions
    foreach (pkg; resolution.packages)
    {
        if (pkg.pkg.name == "A")
            assert(pkg.ver == SemVer.parse("1.0.0").unwrap());
        else if (pkg.pkg.name == "B")
            assert(pkg.ver == SemVer.parse("1.1.0").unwrap());
        else if (pkg.pkg.name == "C")
            assert(pkg.ver == SemVer.parse("1.1.0").unwrap());
    }
}

/// Diamond Dependency Test
unittest
{
    auto src = new MemorySource("test");
    
    // Diamond: A -> B, A -> C, B -> D, C -> D
    src.addVersion("A", "1.0.0", [
        DependencyReq(PackageId("B", "test"), VersionConstraint.parse("^1.0.0").unwrap()),
        DependencyReq(PackageId("C", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    src.addVersion("B", "1.0.0", [
        DependencyReq(PackageId("D", "test"), VersionConstraint.parse(">=1.0.0 <2.0.0").unwrap())
    ]);
    src.addVersion("C", "1.0.0", [
        DependencyReq(PackageId("D", "test"), VersionConstraint.parse(">=1.1.0").unwrap())
    ]);
    src.addVersion("D", "1.0.0");
    src.addVersion("D", "1.1.0");
    src.addVersion("D", "1.2.0");
    
    auto result = solve(src, "A", "^1.0.0");
    assert(result.isOk);
    
    auto resolution = result.unwrap();
    
    // D should be >=1.1.0 (intersection of constraints)
    foreach (pkg; resolution.packages)
    {
        if (pkg.pkg.name == "D")
            assert(pkg.ver >= SemVer.parse("1.1.0").unwrap());
    }
}

/// PackageId and PackageVersion Tests
unittest
{
    auto id1 = PackageId("foo", "npm");
    auto id2 = PackageId("foo", "npm");
    auto id3 = PackageId("foo", "cargo");
    
    assert(id1 == id2);
    assert(id1 != id3);
    assert(id1.toString() == "npm:foo");
    
    auto pv = PackageVersion(id1, SemVer(1, 2, 3));
    assert(pv.toString() == "npm:foo@1.2.3");
}

/// Edge Cases Tests
unittest
{
    // Empty constraint
    auto empty = VersionConstraint.parse("").unwrap();
    assert(empty.allows(SemVer(1, 0, 0)));  // Empty = any
    
    // "latest" keyword
    auto latest = VersionConstraint.parse("latest").unwrap();
    assert(latest.allows(SemVer(99, 0, 0)));
    
    // Version with lots of components
    auto big = SemVer.parse("999.999.999").unwrap();
    assert(big.major == 999);
}

