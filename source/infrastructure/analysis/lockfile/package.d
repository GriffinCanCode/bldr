module infrastructure.analysis.lockfile;

/// Deterministic Lockfile Generation
/// 
/// Provides reproducible builds through lockfile generation for all supported
/// package managers. Inspired by pnpm's efficient content-addressable approach.
/// 
/// ## Architecture
/// 
/// ```
/// ┌───────────────────────────────────────────────────────────────┐
/// │                    Lockfile System                             │
/// ├───────────────────────────────────────────────────────────────┤
/// │                                                               │
/// │  ┌─────────────┐     ┌─────────────────┐     ┌────────────┐ │
/// │  │   Types     │────▶│    Generators    │────▶│   Cache    │ │
/// │  │ (lockfile,  │     │ (npm,cargo,go,  │     │ (content-  │ │
/// │  │  resolved)  │     │  maven)         │     │  addressed)│ │
/// │  └─────────────┘     └─────────────────┘     └────────────┘ │
/// │         │                    │                     │        │
/// │         │                    │                     │        │
/// │         ▼                    ▼                     ▼        │
/// │  ┌────────────────────────────────────────────────────────┐ │
/// │  │              Manifest Parsers (existing)                │ │
/// │  │       npm.d, cargo.d, go.d, maven.d, etc.              │ │
/// │  └────────────────────────────────────────────────────────┘ │
/// └───────────────────────────────────────────────────────────────┘
/// ```
/// 
/// ## Key Features
/// 
/// ### Content-Addressable Caching
/// Resolution results are cached by manifest content hash. If the manifest
/// hasn't changed, the cached lockfile is returned instantly.
/// 
/// ```d
/// // Cache hit path (O(1) hash lookup)
/// auto cached = cache.get(manifestHash);  // <1ms
/// 
/// // Cache miss path (full resolution)
/// auto lockfile = generator.generate(path);  // ~100ms-10s
/// cache.put(manifestHash, lockfile);
/// ```
/// 
/// ### Deterministic Output
/// Lockfiles are always:
/// - Sorted alphabetically by dependency name
/// - Formatted canonically (consistent whitespace)
/// - Platform-independent (same output on Windows/Mac/Linux)
/// 
/// ### Incremental Updates
/// When updating, only changed dependencies are re-resolved:
/// 
/// ```d
/// auto diff = LockfileDiff.compute(oldLock, newLock);
/// // diff.added, diff.removed, diff.updated
/// ```
/// 
/// ## Supported Package Managers
/// 
/// | Manager | Manifest        | Lockfile            |
/// |---------|-----------------|---------------------|
/// | npm     | package.json    | package-lock.json   |
/// | yarn    | package.json    | yarn.lock           |
/// | pnpm    | package.json    | pnpm-lock.yaml      |
/// | cargo   | Cargo.toml      | Cargo.lock          |
/// | go      | go.mod          | go.sum              |
/// | maven   | pom.xml         | dependency-lock.json|
/// 
/// ## Usage
/// 
/// ### Generate Lockfile
/// 
/// ```d
/// import infrastructure.analysis.lockfile;
/// 
/// auto cache = new LockfileCache(".builder-cache/lockfiles");
/// auto generator = LockfileFactory.create("package.json", cache);
/// 
/// auto result = generator.generate("package.json");
/// if (result.isOk) {
///     generator.write(result.unwrap(), "package-lock.json");
/// }
/// ```
/// 
/// ### CI Mode (Frozen)
/// 
/// ```d
/// auto options = GenerateOptions.ci();  // frozen = true
/// auto result = generator.generate("package.json", options);
/// // Fails if lockfile would change
/// ```
/// 
/// ### Check If Up-to-Date
/// 
/// ```d
/// if (!generator.isUpToDate("package.json", "package-lock.json")) {
///     // Lockfile needs regeneration
/// }
/// ```
/// 
/// ## Performance
/// 
/// | Operation              | Time       |
/// |------------------------|------------|
/// | Cache hit              | <1ms       |
/// | Parse existing lock    | 5-50ms     |
/// | Generate (no network)  | 50-200ms   |
/// | Full resolution        | 1-30s      |

public import infrastructure.analysis.lockfile.types;
public import infrastructure.analysis.lockfile.cache;
public import infrastructure.analysis.lockfile.generators;

