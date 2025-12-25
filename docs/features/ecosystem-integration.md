# Ecosystem Integration

Builder integrates with language ecosystems through manifest parsing (package.json, Cargo.toml, pyproject.toml, etc.). When you run `bldr init`, it:

1. Scans for package manifests across supported languages
2. Extracts project metadata: entry points, dependencies, scripts, framework hints
3. Generates a Builderfile with appropriate defaults based on project structure

## Architecture

### Manifest Parsing

**Location**: `source/infrastructure/analysis/manifests/`

```
manifests/
├── types.d          # Common types (ManifestInfo, Dependency, Script, IManifestParser)
├── npm.d            # package.json parser (JS/TS)
├── cargo.d          # Cargo.toml parser (Rust)
├── python.d         # pyproject.toml, setup.py, requirements.txt (Python)
├── go.d             # go.mod parser (Go)
├── maven.d          # pom.xml parser (Java)
└── composer.d       # composer.json parser (PHP)
```

### Core Types

```d
/// Parsed manifest information
struct ManifestInfo
{
    string name;              // Package/project name
    string version_;          // Version string
    string[] entryPoints;     // Main entry points
    string[] sources;         // Source file patterns
    string[] tests;           // Test file patterns
    Dependency[] dependencies;// Direct dependencies
    Script[string] scripts;   // Build/run scripts
    TargetLanguage language;  // Detected language
    TargetType suggestedType; // Suggested target type
    string[string] metadata;  // Additional metadata
}

/// Manifest parser interface
interface IManifestParser
{
    BuildResult!ManifestInfo parse(string filePath) @system;
    bool canParse(string filePath) const @safe;
    string name() const pure nothrow @safe;
}
```

### Enhanced Detection

**Location**: `source/infrastructure/analysis/detection/enhanced.d`

The `EnhancedProjectDetector` extends base detection with manifest parsing:

```d
auto detector = new EnhancedProjectDetector(".");
auto enhanced = detector.detectEnhanced();
// enhanced.manifestInfo contains parsed data for each language
```

### Template Generation

**Location**: `source/infrastructure/analysis/detection/generator.d`

`EnhancedTemplateGenerator` uses manifest data to generate context-aware targets with:

- Entry points from package.json `main`, Cargo.toml `[[bin]]`, etc.
- Framework detection (React, Django, Gin) with appropriate configs
- Test patterns based on project conventions
- Dependency hints as comments

## Supported Ecosystems

### JavaScript/TypeScript (npm/yarn/pnpm)

Parses `package.json` to extract:
- Entry points: `main`, `module`, `browser` fields
- TypeScript detection via dependencies
- Framework detection: React, Vue, Angular, Next.js, Vite
- Scripts mapped to Builder targets
- Dependencies (runtime, dev, peer, optional)

**Generated Output**:
```d
target("my-app") {
    type: executable;
    language: typescript;
    sources: ["src/index.ts"];
    
    config: {
        "mode": "bundle",
        "bundler": "esbuild",
        "platform": "browser"
    };
    
    // Dependencies: react, react-dom, axios
}
```

### Rust (Cargo)

Parses `Cargo.toml` to extract:
- Package name and edition
- Binary vs library detection
- Dependencies (runtime, dev, build)
- Framework detection: actix-web, rocket, axum

**Generated Output**:
```d
target("my-rust-app") {
    type: executable;
    language: rust;
    sources: ["src/main.rs"];
    
    config: {
        "mode": "compile",
        "edition": "2021"
    };
}
```

### Python

Parses `pyproject.toml`, `setup.py`, `requirements.txt`:
- Project name, version, description
- Entry points: main.py, app.py, __main__.py
- Framework detection: Django, Flask, FastAPI
- Dependencies with dev/runtime separation

**Generated Output**:
```d
target("my-python-app") {
    type: executable;
    language: python;
    sources: ["main.py"];
    
    config: {
        "virtualenv": true,
        "requirements": "requirements.txt"
    };
    
    // Dependencies: flask, requests, sqlalchemy
}
```

### Go

Parses `go.mod`:
- Module name and Go version
- Main package detection
- Framework detection: gin, echo, fiber
- Dependency extraction from require blocks

### PHP (Composer)

Parses `composer.json`:
- Package name and version
- Dependencies (require, require-dev)
- Entry point detection

### Java (Maven)

Parses `pom.xml`:
- GroupId, artifactId, version
- Dependencies from `<dependencies>` section
- Source/output directories from build configuration
- Packaging type mapping to target type

## Integration Points

### Init Command

`bldr init` uses manifest parsing:

```bash
$ cd my-react-app
$ bldr init

🔍 Scanning project directory...
✨ Detected Languages
  ▸ TypeScript (100% confidence) [vite-react]
    → Found: package.json
✓ Created Builderfile
✓ Created Builderspace
✓ Created .builderignore
```

### Migration System

The migration system reuses manifest parsers. Migrators call `parser.parse(filePath)` to extract dependency information from existing build configurations.

### Zero-Config Builds

Manifest parsing enhances zero-config: if no Builderfile exists, Builder parses manifests to infer targets.

## Design Principles

### Interface Consistency

All parsers implement `IManifestParser`:

```d
interface IManifestParser {
    BuildResult!ManifestInfo parse(string filePath) @system;
    bool canParse(string filePath) const @safe;
    string name() const pure nothrow @safe;
}
```

### Type Safety

All manifest data flows through strongly-typed structures:
- `ManifestInfo`: Parsed manifest data
- `Dependency`: Typed dependencies (Runtime, Development, Peer, Build, Optional)
- `Script`: Build/test scripts with inferred target types

### Error Handling

Uses Builder's Result type for error propagation:
```d
auto result = parser.parse("package.json");
if (result.isErr)
    return result.unwrapErr();
auto manifest = result.unwrap();
```

## Performance

- Manifest parsing: <5ms per file
- Enhanced detection: +10ms over base detection
- Template generation: <1ms

## Future Enhancements

### Lockfile Parsing

Next phase adds transitive dependency resolution:
- `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml`
- `Cargo.lock`
- `go.sum`
- `poetry.lock`

### Workspace/Monorepo Support

Enhanced manifest parsing for:
- npm workspaces (`workspaces` field in package.json)
- Cargo workspaces (`[workspace]` in Cargo.toml)
- Go workspaces (go.work)

### Framework-Specific Optimizations

Specialized configs for:
- Next.js: SSR/SSG detection, API routes as separate targets
- Django: App identification, migration targets
- Gin/Echo: Route definitions, OpenAPI targets
