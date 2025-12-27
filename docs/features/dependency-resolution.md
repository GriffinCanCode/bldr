# Dependency Resolution

**Module:** `infrastructure.analysis.semver`

## Overview

Builder implements a complete PubGrub-based semantic versioning constraint solver for multi-language dependency resolution. This enables accurate dependency resolution across npm, cargo, pip, and other semver-based package ecosystems.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    SemVer Constraint Solver                      │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐    ┌──────────────┐    ┌────────────────────────┐ │
│  │ version  │───▶│  constraint  │───▶│        solver          │ │
│  │ (parse,  │    │  (ranges,    │    │  (PubGrub algorithm,   │ │
│  │ compare) │    │   unions)    │    │   conflict learning)   │ │
│  └──────────┘    └──────────────┘    └────────────────────────┘ │
│        │                │                       │               │
│        ▼                ▼                       ▼               │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                         source                              ││
│  │    IPackageSource → npm, cargo, pip, composite, memory      ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## SemVer 2.0.0 Compliance

**Module:** `infrastructure.analysis.semver.version_`

### Version Parsing

```d
import infrastructure.analysis.semver;

// Basic version
auto v1 = SemVer.parse("1.2.3").unwrap();
assert(v1.major == 1 && v1.minor == 2 && v1.patch == 3);

// With prerelease
auto v2 = SemVer.parse("1.0.0-alpha.1").unwrap();
assert(v2.isPrerelease);
assert(v2.prerelease == "alpha.1");

// With build metadata
auto v3 = SemVer.parse("1.0.0+build123").unwrap();
assert(v3.build == "build123");

// Full version (v prefix stripped)
auto v4 = SemVer.parse("v2.1.0-rc.1+20240101").unwrap();
```

### Version Comparison

```d
// Major.minor.patch ordering
assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("2.0.0").unwrap());
assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("1.1.0").unwrap());
assert(SemVer.parse("1.0.0").unwrap() < SemVer.parse("1.0.1").unwrap());

// Prerelease < release
assert(SemVer.parse("1.0.0-alpha").unwrap() < SemVer.parse("1.0.0").unwrap());
assert(SemVer.parse("1.0.0-alpha").unwrap() < SemVer.parse("1.0.0-beta").unwrap());

// Build metadata ignored for equality
assert(SemVer.parse("1.0.0+a").unwrap() == SemVer.parse("1.0.0+b").unwrap());
```

### Version Operations

```d
auto v = SemVer.parse("1.2.3").unwrap();

v.bumpMajor();  // 2.0.0
v.bumpMinor();  // 1.3.0
v.bumpPatch();  // 1.2.4
```

---

## Version Constraints

**Module:** `infrastructure.analysis.semver.constraint`

### Constraint Syntax

| Syntax | Meaning | Example |
|--------|---------|---------|
| `1.2.3` | Exact match | `=1.2.3` |
| `^1.2.3` | Caret range | `>=1.2.3 <2.0.0` |
| `~1.2.3` | Tilde range | `>=1.2.3 <1.3.0` |
| `>=1.0.0` | At least | Lower bound only |
| `<2.0.0` | Less than | Upper bound only |
| `>=1.0.0 <2.0.0` | Range | Both bounds |
| `*` or `latest` | Any | Matches all versions |
| `||` | Union | `>=1.0.0 <2.0.0 \|\| >=3.0.0` |

### Caret Range Semantics

The caret range allows changes that don't modify the leftmost non-zero digit:

| Constraint | Meaning |
|------------|---------|
| `^1.2.3` | `>=1.2.3 <2.0.0` (major > 0) |
| `^0.2.3` | `>=0.2.3 <0.3.0` (major = 0, minor > 0) |
| `^0.0.3` | `>=0.0.3 <0.0.4` (major = minor = 0) |

### Usage

```d
import infrastructure.analysis.semver;

// Parse constraints
auto caret = VersionConstraint.parse("^1.2.3").unwrap();
assert(caret.allows(SemVer.parse("1.9.9").unwrap()));
assert(!caret.allows(SemVer.parse("2.0.0").unwrap()));

auto tilde = VersionConstraint.parse("~1.2.3").unwrap();
assert(tilde.allows(SemVer.parse("1.2.5").unwrap()));
assert(!tilde.allows(SemVer.parse("1.3.0").unwrap()));

// Range intersection
auto c1 = VersionConstraint.parse(">=1.0.0").unwrap();
auto c2 = VersionConstraint.parse("<2.0.0").unwrap();
auto intersected = c1.intersect(c2);
assert(intersected.allows(SemVer.parse("1.5.0").unwrap()));

// Union (OR)
auto union_ = VersionConstraint.parse(">=1.0.0 <2.0.0 || >=3.0.0").unwrap();
assert(union_.allows(SemVer.parse("1.5.0").unwrap()));
assert(!union_.allows(SemVer.parse("2.5.0").unwrap()));
assert(union_.allows(SemVer.parse("3.0.0").unwrap()));
```

---

## PubGrub Solver

**Module:** `infrastructure.analysis.semver.solver`

### Algorithm Overview

The PubGrub algorithm is a modern SAT-inspired dependency resolver:

1. **Incompatibilities**: Express constraints as clauses (if A then not B)
2. **Unit Propagation**: Derive assignments efficiently from unit clauses
3. **Conflict Resolution**: Learn from failures to avoid repeating
4. **Backtracking**: Jump back to the decision that caused the conflict

### Key Advantages

- **Optimal**: Prefers newest compatible versions
- **Efficient**: Conflict-driven clause learning avoids exponential blowup
- **Explainable**: Can provide clear error messages on conflicts

### Usage

```d
import infrastructure.analysis.semver;

// Create package source
auto source = new MemorySource("test");
source.addVersion("foo", "1.0.0");
source.addVersion("foo", "1.1.0", [
    DependencyReq(PackageId("bar", "test"), VersionConstraint.parse("^1.0.0").unwrap())
]);
source.addVersion("bar", "1.2.0");

// One-shot solving
auto result = solve(source, "foo", "^1.0.0");
if (result.isOk) {
    foreach (pkg; result.unwrap().packages)
        writeln(pkg.toString());  // foo@1.1.0, bar@1.2.0
}

// Or use solver directly for more control
auto solver = new PubGrubSolver(source);
auto resolution = solver.solve(
    PackageId("foo", "test"),
    VersionConstraint.parse("^1.0.0").unwrap()
);
```

---

## Package Sources

**Module:** `infrastructure.analysis.semver.source`

### Interface

```d
interface IPackageSource {
    /// Get available versions for a package (sorted descending)
    BuildResult!(SemVer[]) versions(PackageId pkg) @system;
    
    /// Get dependencies for a specific package version
    BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system;
    
    /// Check if package exists
    bool exists(PackageId pkg) @system;
    
    /// Source identifier (e.g., "npm", "cargo", "pypi")
    string name() const pure nothrow @safe;
}
```

### Built-in Sources

| Source | Ecosystem | Manifest |
|--------|-----------|----------|
| `MemorySource` | Testing | In-memory |
| `ManifestSource` | Local | Any manifest parser |
| `CachedSource` | Wrapper | Caches any source |
| `CompositeSource` | Multi | Combines sources |

### Factory Usage

```d
// Single ecosystem
auto npmSource = SourceFactory.npm("/path/to/project");
auto cargoSource = SourceFactory.cargo("/path/to/project");
auto pipSource = SourceFactory.pip("/path/to/project");

// All ecosystems combined
auto composite = SourceFactory.all("/path/to/project");
```

---

## Registry Sources

**Module:** `infrastructure.analysis.semver.registry`

### Supported Registries

| Registry | Class | Default URL |
|----------|-------|-------------|
| npm | `NpmRegistrySource` | `https://registry.npmjs.org` |
| crates.io | `CratesRegistrySource` | `https://crates.io/api/v1/crates` |
| PyPI | `PyPIRegistrySource` | `https://pypi.org/pypi` |

### Configuration

```d
struct RegistryConfig {
    string url;              // Base URL
    string authToken;        // Optional auth token
    uint timeoutMs = 30_000; // Request timeout
    uint maxRetries = 3;     // Retry count
    bool offline;            // Offline mode (no network)
}
```

### Usage

```d
// Factory methods
auto npm = RegistryFactory.npm();
auto crates = RegistryFactory.crates();
auto pypi = RegistryFactory.pypi();

// Offline mode
auto offlineNpm = RegistryFactory.npm(offline: true);

// All registries combined
auto all = RegistryFactory.all();
```

---

## Cross-Language Resolution

The composite source enables resolving dependencies that span multiple ecosystems:

```d
auto composite = SourceFactory.all("/path/to/project");
auto solver = new PubGrubSolver(composite);

// Resolve npm package that depends on native cargo library
auto result = solver.solve(
    PackageId("my-app", "npm"),
    VersionConstraint.parse("*").unwrap()
);
```

---

## Performance

| Operation | Complexity |
|-----------|------------|
| Version parse | O(n) |
| Constraint parse | O(n) |
| Constraint intersection | O(r₁ × r₂) |
| Resolution (typical) | O(n × d) |
| Resolution (worst) | O(2ⁿ) |

Where:
- n = number of packages
- d = average dependencies per package
- r = number of ranges in constraint

The PubGrub algorithm is dramatically faster than naive backtracking due to conflict-driven clause learning.

---

## Error Handling

### Conflict Detection

```d
auto result = solve(source, "app", "^1.0.0");
if (result.isErr) {
    auto err = result.unwrapErr();
    if (auto analysis = cast(AnalysisError)err) {
        if (analysis.kind == Analysis.VersionConflict) {
            // Incompatible version requirements
        } else if (analysis.kind == Analysis.PackageNotFound) {
            // Package doesn't exist
        }
    }
}
```

### Common Errors

| Error | Cause |
|-------|-------|
| `VersionConflict` | Incompatible version requirements |
| `PackageNotFound` | Package doesn't exist in source |
| `NoVersions` | No versions satisfy constraint |
| `Failed` | Network/parsing failure |

---

## See Also

- [Manifest Parsing](manifests.md)
- [Package Sources](../architecture/package-sources.md)
- [Multi-Language Support](multi-language.md)
- [Caching Architecture](../architecture/cachedesign.md)

