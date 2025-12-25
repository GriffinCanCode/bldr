module infrastructure.analysis.lockfile.generators;

/// Lockfile Generators
/// 
/// Deterministic lockfile generation for external dependencies across
/// all supported package managers. Inspired by pnpm's content-addressable
/// approach for efficiency.
/// 
/// ## Supported Package Managers
/// 
/// - **NPM/Yarn/PNPM**: package-lock.json, yarn.lock, pnpm-lock.yaml
/// - **Cargo**: Cargo.lock for Rust
/// - **Go**: go.sum for Go modules
/// - **Maven**: dependency-lock.json for Java/Kotlin
/// 
/// ## Key Features
/// 
/// - **Content-Addressable Caching**: Resolution results cached by manifest hash
/// - **Deterministic Output**: Sorted, canonical lockfile format
/// - **Incremental Updates**: Only re-resolve changed dependencies
/// - **Cross-Platform**: Same lockfile regardless of OS
/// 
/// ## Usage
/// 
/// ```d
/// import infrastructure.analysis.lockfile;
/// 
/// // Create generator with cache
/// auto cache = new LockfileCache();
/// auto generator = LockfileFactory.create("package.json", cache);
/// 
/// // Generate lockfile
/// auto result = generator.generate("package.json");
/// if (result.isOk) {
///     auto lockfile = result.unwrap();
///     generator.write(lockfile, "package-lock.json");
/// }
/// ```

public import infrastructure.analysis.lockfile.generators.npm;
public import infrastructure.analysis.lockfile.generators.cargo;
public import infrastructure.analysis.lockfile.generators.go;
public import infrastructure.analysis.lockfile.generators.maven;

import infrastructure.analysis.lockfile.types;
import infrastructure.analysis.lockfile.cache;
import std.path : baseName;

/// Factory for creating lockfile generators
struct LockfileFactory
{
    /// Create appropriate generator for manifest file
    static ILockfileGenerator create(string manifestPath, LockfileCache cache = null) @system
    {
        immutable name = baseName(manifestPath);
        immutable pm = detectPackageManager(manifestPath);
        
        final switch (pm)
        {
            case PackageManagerType.Npm:
                // Auto-detect npm flavor from existing lockfile
                return new NpmLockfileGenerator(cache, detectNpmFlavor(manifestPath));
            
            case PackageManagerType.Cargo:
                return new CargoLockfileGenerator(cache);
            
            case PackageManagerType.Go:
                return new GoLockfileGenerator(cache);
            
            case PackageManagerType.Maven:
                return new MavenLockfileGenerator(cache);
            
            case PackageManagerType.Pip:
            case PackageManagerType.Composer:
            case PackageManagerType.Unknown:
                return null;
        }
    }
    
    /// Detect npm flavor from existing lockfiles
    private static NpmLockfileGenerator.NpmFlavor detectNpmFlavor(string manifestPath) @safe
    {
        import std.path : dirName, buildPath;
        import std.file : exists;
        
        immutable dir = dirName(manifestPath);
        
        if (exists(buildPath(dir, "pnpm-lock.yaml")))
            return NpmLockfileGenerator.NpmFlavor.Pnpm;
        if (exists(buildPath(dir, "yarn.lock")))
            return NpmLockfileGenerator.NpmFlavor.Yarn;
        
        return NpmLockfileGenerator.NpmFlavor.Npm;
    }
}

