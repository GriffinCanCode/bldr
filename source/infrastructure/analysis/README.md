# Analysis Package

Dependency resolution, project detection, and build graph analysis for the Builder system.

## Architecture

```
analysis/
├── scanning/        # File and dependency scanning
│   └── scanner.d    # DependencyScanner with parallel processing
├── resolution/      # Dependency resolution
│   └── resolver.d   # Cycle detection, topological sort
├── targets/         # Build target types
│   ├── types.d      # AnalysisTarget, DependencyInfo
│   └── spec.d       # Build specification handling
├── inference/       # Target inference
│   └── analyzer.d   # Build target analysis and inference
├── metadata/        # Artifact metadata
│   └── metagen.d    # Metadata generation for caching
├── detection/       # Project detection and templates
│   ├── detector.d   # Language and project type detection
│   ├── enhanced.d   # Enhanced detection with heuristics
│   ├── generator.d  # Builderfile generation from detection
│   ├── inference.d  # Target inference from project structure
│   └── templates.d  # Init templates for various languages
├── manifests/       # Package manifest parsing
│   ├── cargo.d      # Rust Cargo.toml
│   ├── composer.d   # PHP composer.json
│   ├── go.d         # Go go.mod
│   ├── maven.d      # Maven pom.xml
│   ├── npm.d        # Node package.json
│   ├── python.d     # Python pyproject.toml, setup.py
│   └── types.d      # Common manifest types
├── incremental/     # Incremental analysis
│   ├── analyzer.d   # Incremental dependency analysis
│   ├── interface.d  # Analysis interface definitions
│   └── watcher.d    # File change watching for analysis
├── caching/         # Analysis result caching
│   ├── interface.d  # Cache interface
│   └── store.d      # Analysis cache storage
├── tracking/        # Dependency tracking
│   ├── interface.d  # Tracking interface
│   └── tracker.d    # Runtime dependency tracker
└── ast/             # AST-level analysis
    └── parser.d     # Cross-language AST parsing
```

## Usage

```d
import infrastructure.analysis;

// Scan for dependencies
auto scanner = new DependencyScanner();
auto deps = scanner.scan(sourceFiles);

// Resolve dependency graph
auto resolver = new DependencyResolver();
auto resolved = resolver.resolve(deps);

// Detect project type
auto detector = new ProjectDetector();
auto projectInfo = detector.detect(projectPath);

// Parse package manifests
auto manifest = parseCargoToml("Cargo.toml");
```

## Key Features

- **Parallel scanning**: Multi-threaded dependency detection
- **Cycle detection**: Topological sort with cycle reporting
- **Project detection**: Auto-detect 17+ languages and build systems
- **Manifest parsing**: npm, Cargo, Maven, Go mod, pip, Composer
- **Incremental analysis**: Only re-analyze changed files
- **Template generation**: Init templates for all supported languages

