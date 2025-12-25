module infrastructure.analysis;

/// Build Analysis Package
/// Dependency resolution and build graph analysis
/// 
/// Architecture:
///   scanner.d   - File and dependency scanning
///   resolver.d  - Dependency resolution logic
///   types.d     - Type definitions for analysis
///   analyzer.d  - Build target analysis
///   spec.d      - Build specification handling
///   metagen.d   - Metadata generation
///   detection/  - Project detection and init templates
///   manifests/  - Package manifest parsing (npm, cargo, etc.)
///   lockfile/   - Deterministic lockfile generation
///
/// Usage:
///   import analysis;
///   
///   auto scanner = new DependencyScanner();
///   auto deps = scanner.scan(sourceFiles);
///   
///   auto resolver = new DependencyResolver();
///   auto resolved = resolver.resolve(deps);

public import infrastructure.analysis.scanning.scanner;
public import infrastructure.analysis.resolution.resolver;
public import infrastructure.analysis.targets.types;
public import infrastructure.analysis.inference.analyzer;
public import infrastructure.analysis.targets.spec;
public import infrastructure.analysis.metadata.metagen;
public import infrastructure.analysis.detection;
public import infrastructure.analysis.manifests;
public import infrastructure.analysis.lockfile;

