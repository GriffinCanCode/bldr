# SemVer Constraint Solver

PubGrub-style version resolution for multi-language dependency management.

## Modules

| Module | Purpose |
|--------|---------|
| `version_` | SemVer 2.0.0 parsing and comparison |
| `constraint` | Version ranges and constraint unions |
| `solver` | PubGrub dependency resolution algorithm |
| `source` | Package source interfaces and adapters |
| `registry` | Network-backed registry sources |

## Quick Start

```d
import infrastructure.analysis.semver;

// Create package source
auto source = new MemorySource("test");
source.addVersion("foo", "1.0.0");
source.addVersion("foo", "1.1.0", [
    DependencyReq(PackageId("bar", "test"), VersionConstraint.parse("^1.0.0").unwrap())
]);
source.addVersion("bar", "1.2.0");

// Solve dependencies
auto result = solve(source, "foo", "^1.0.0");
if (result.isOk)
    foreach (pkg; result.unwrap().packages)
        writeln(pkg.toString());  // foo@1.1.0, bar@1.2.0
```

## Constraint Syntax

| Syntax | Meaning |
|--------|---------|
| `1.2.3` | Exact match |
| `^1.2.3` | `>=1.2.3 <2.0.0` |
| `~1.2.3` | `>=1.2.3 <1.3.0` |
| `>=1.0.0 <2.0.0` | Range |
| `*` | Any version |
| `\|\|` | Union |

## PubGrub Algorithm

The solver uses PubGrub, a modern SAT-inspired algorithm:

- **Incompatibilities**: Express constraints as clauses
- **Unit propagation**: Derive assignments efficiently
- **Conflict resolution**: Learn from failures to avoid repeating
- **Optimal solutions**: Prefers newest compatible versions

## Package Sources

| Source | Use Case |
|--------|----------|
| `MemorySource` | Testing |
| `ManifestSource` | Local manifests |
| `CachedSource` | Reduce network |
| `CompositeSource` | Cross-language |

### Registry Sources

| Registry | URL |
|----------|-----|
| npm | `registry.npmjs.org` |
| crates.io | `crates.io/api/v1/crates` |
| PyPI | `pypi.org/pypi` |

## Performance

| Operation | Complexity |
|-----------|------------|
| Version parse | O(n) |
| Constraint parse | O(n) |
| Resolution (typical) | O(n × d) |
| Resolution (worst) | O(2^n) |

PubGrub is dramatically faster than naive backtracking due to conflict-driven clause learning.

## Cross-Language Resolution

```d
auto composite = SourceFactory.all("/path/to/project");
auto solver = new PubGrubSolver(composite);

auto result = solver.solve(
    PackageId("my-app", "npm"),
    VersionConstraint.parse("*").unwrap()
);
```

## See Also

- [Dependency Resolution](../../../docs/features/dependency-resolution.md)
- [AI Concept: SemVer](../../../docs/ai/concepts/core/semver.yaml)

