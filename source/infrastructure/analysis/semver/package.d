module infrastructure.analysis.semver;

/// Semantic Versioning Constraint Solver
/// 
/// PubGrub-style version resolution for multi-language dependency management.
/// Supports npm, cargo, pip, and other semver-based package managers.
/// 
/// ## Architecture
/// 
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    SemVer Constraint Solver                      │
/// ├─────────────────────────────────────────────────────────────────┤
/// │                                                                  │
/// │  ┌──────────┐    ┌──────────────┐    ┌────────────────────────┐ │
/// │  │ version  │───▶│  constraint  │───▶│        solver          │ │
/// │  │ (parse,  │    │  (ranges,    │    │  (PubGrub algorithm,   │ │
/// │  │ compare) │    │   unions)    │    │   conflict learning)   │ │
/// │  └──────────┘    └──────────────┘    └────────────────────────┘ │
/// │        │                │                       │               │
/// │        │                │                       │               │
/// │        ▼                ▼                       ▼               │
/// │  ┌─────────────────────────────────────────────────────────────┐│
/// │  │                         source                              ││
/// │  │    IPackageSource → npm, cargo, pip, composite, memory      ││
/// │  └─────────────────────────────────────────────────────────────┘│
/// └─────────────────────────────────────────────────────────────────┘
/// ```
/// 
/// ## Key Features
/// 
/// ### PubGrub Algorithm
/// The solver uses PubGrub, a modern SAT-inspired algorithm:
/// - **Incompatibilities**: Express constraints as clauses
/// - **Unit propagation**: Derive assignments efficiently
/// - **Conflict resolution**: Learn from failures to avoid repeating
/// - **Optimal solutions**: Prefers newest compatible versions
/// 
/// ### Multi-Language Support
/// Works across package ecosystems via the `IPackageSource` interface:
/// - npm (package.json)
/// - cargo (Cargo.toml)
/// - pip (pyproject.toml, requirements.txt)
/// - Extensible to any semver-based system
/// 
/// ### Version Constraint DSL
/// Supports common constraint syntaxes:
/// - Exact: `1.2.3`, `=1.2.3`
/// - Caret: `^1.2.3` (>=1.2.3 <2.0.0)
/// - Tilde: `~1.2.3` (>=1.2.3 <1.3.0)
/// - Ranges: `>=1.0.0 <2.0.0`
/// - Unions: `>=1.0.0 <2.0.0 || >=3.0.0`
/// 
/// ## Usage
/// 
/// ### Basic Resolution
/// 
/// ```d
/// import infrastructure.analysis.semver;
/// 
/// // Create package source
/// auto source = new MemorySource("test");
/// source.addVersion("foo", "1.0.0");
/// source.addVersion("foo", "1.1.0", [
///     DependencyReq(PackageId("bar", "test"), VersionConstraint.parse("^1.0.0").unwrap())
/// ]);
/// source.addVersion("bar", "1.2.0");
/// 
/// // Solve
/// auto result = solve(source, "foo", "^1.0.0");
/// if (result.isOk) {
///     foreach (pkg; result.unwrap().packages)
///         writeln(pkg.toString());  // foo@1.1.0, bar@1.2.0
/// }
/// ```
/// 
/// ### Cross-Language Resolution
/// 
/// ```d
/// auto composite = SourceFactory.all("/path/to/project");
/// auto solver = new PubGrubSolver(composite);
/// 
/// // Resolve npm package that depends on native cargo library
/// auto result = solver.solve(
///     PackageId("my-app", "npm"),
///     VersionConstraint.parse("*").unwrap()
/// );
/// ```
/// 
/// ## Performance
/// 
/// | Operation              | Complexity    |
/// |------------------------|---------------|
/// | Version parse          | O(n)          |
/// | Constraint parse       | O(n)          |
/// | Constraint intersection| O(r1 × r2)    |
/// | Resolution (typical)   | O(n × d)      |
/// | Resolution (worst)     | O(2^n)        |
/// 
/// Where n = packages, d = average deps, r = ranges
/// 
/// The PubGrub algorithm is dramatically faster than naive backtracking
/// due to conflict-driven clause learning.

// Core types
public import infrastructure.analysis.semver.version_ : SemVer, PackageId, PackageVersion;
public import infrastructure.analysis.semver.constraint : VersionRange, VersionConstraint, Bound;

// Solver
public import infrastructure.analysis.semver.solver : 
    PubGrubSolver, Term, Incompatibility, Assignment, Resolution, solve;

// Package sources
public import infrastructure.analysis.semver.source : 
    IPackageSource, DependencyReq, CompositeSource, MemorySource, 
    CachedSource, ManifestSource, SourceFactory;

// Registry sources (for network-backed resolution)
public import infrastructure.analysis.semver.registry :
    IRegistrySource, RegistryConfig, PackageMetadata, HttpRegistrySource,
    NpmRegistrySource, CratesRegistrySource, PyPIRegistrySource, RegistryFactory;

