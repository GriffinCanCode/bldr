module tests.unit.analysis.lockfile;

import std.stdio;
import std.path;
import std.file;
import std.algorithm;
import std.array;
import std.datetime : Clock;
import infrastructure.analysis.lockfile;
import tests.harness;

/// Test lockfile types and structures
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - ResolvedDependency creation");
    
    ResolvedDependency dep;
    dep.name = "lodash";
    dep.version_ = "4.17.21";
    dep.integrity = "sha512-abc123";
    dep.resolved = "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz";
    dep.dev = false;
    
    Assert.isTrue(dep.isValid());
    Assert.equal(dep.name, "lodash");
    Assert.equal(dep.version_, "4.17.21");
    
    writeln("\x1b[32m  ✓ ResolvedDependency creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - Lockfile structure");
    
    Lockfile lockfile;
    lockfile.meta.format = "npm";
    lockfile.meta.version_ = 3;
    lockfile.meta.manifestHash = "abc123def456";
    
    // Add dependencies
    ResolvedDependency dep1;
    dep1.name = "react";
    dep1.version_ = "18.2.0";
    dep1.integrity = "sha512-xyz";
    
    ResolvedDependency dep2;
    dep2.name = "lodash";
    dep2.version_ = "4.17.21";
    dep2.integrity = "sha512-abc";
    
    lockfile.dependencies = [dep1, dep2];
    
    Assert.equal(lockfile.count(), 2);
    Assert.isFalse(lockfile.empty());
    
    // Test get by name
    auto found = lockfile.get("react");
    Assert.isTrue(found !is null);
    Assert.equal(found.version_, "18.2.0");
    
    auto notFound = lockfile.get("nonexistent");
    Assert.isTrue(notFound is null);
    
    writeln("\x1b[32m  ✓ Lockfile structure works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - Deterministic hashing");
    
    // Two lockfiles with same content should hash identically
    Lockfile lock1, lock2;
    
    lock1.meta.format = "npm";
    lock1.meta.manifestHash = "same-hash";
    
    lock2.meta.format = "npm";
    lock2.meta.manifestHash = "same-hash";
    
    ResolvedDependency dep;
    dep.name = "test";
    dep.version_ = "1.0.0";
    dep.integrity = "sha512-test";
    
    lock1.dependencies = [dep];
    lock2.dependencies = [dep];
    
    auto hash1 = lock1.hash();
    auto hash2 = lock2.hash();
    
    Assert.equal(hash1, hash2);
    Assert.isTrue(hash1.length > 0);
    
    writeln("\x1b[32m  ✓ Deterministic hashing works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - LockfileDiff computation");
    
    Lockfile oldLock, newLock;
    oldLock.meta.format = "npm";
    newLock.meta.format = "npm";
    
    // Old lockfile: lodash@4.17.20, react@17.0.0
    ResolvedDependency lodashOld, reactOld;
    lodashOld.name = "lodash";
    lodashOld.version_ = "4.17.20";
    reactOld.name = "react";
    reactOld.version_ = "17.0.0";
    oldLock.dependencies = [lodashOld, reactOld];
    
    // New lockfile: lodash@4.17.21 (updated), vue@3.0.0 (added), react removed
    ResolvedDependency lodashNew, vue;
    lodashNew.name = "lodash";
    lodashNew.version_ = "4.17.21";
    vue.name = "vue";
    vue.version_ = "3.0.0";
    newLock.dependencies = [lodashNew, vue];
    
    auto diff = LockfileDiff.compute(oldLock, newLock);
    
    Assert.isTrue(diff.hasChanges());
    Assert.equal(diff.added.length, 1);      // vue added
    Assert.equal(diff.removed.length, 1);    // react removed
    Assert.equal(diff.updated.length, 1);    // lodash updated
    
    Assert.equal(diff.added[0].name, "vue");
    Assert.equal(diff.removed[0].name, "react");
    Assert.equal(diff.updated[0].name, "lodash");
    
    writeln("\x1b[32m  ✓ LockfileDiff computation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - Package manager detection");
    
    Assert.equal(detectPackageManager("package.json"), PackageManagerType.Npm);
    Assert.equal(detectPackageManager("Cargo.toml"), PackageManagerType.Cargo);
    Assert.equal(detectPackageManager("go.mod"), PackageManagerType.Go);
    Assert.equal(detectPackageManager("pom.xml"), PackageManagerType.Maven);
    Assert.equal(detectPackageManager("requirements.txt"), PackageManagerType.Pip);
    Assert.equal(detectPackageManager("composer.json"), PackageManagerType.Composer);
    Assert.equal(detectPackageManager("unknown.xyz"), PackageManagerType.Unknown);
    
    writeln("\x1b[32m  ✓ Package manager detection works\x1b[0m");
}

/// Test NPM lockfile generator
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.generators.npm - Lockfile name");
    
    auto generator = new NpmLockfileGenerator(null, NpmLockfileGenerator.NpmFlavor.Npm);
    Assert.equal(generator.lockfileName(), "package-lock.json");
    Assert.equal(generator.type(), PackageManagerType.Npm);
    
    auto yarnGen = new NpmLockfileGenerator(null, NpmLockfileGenerator.NpmFlavor.Yarn);
    Assert.equal(yarnGen.lockfileName(), "yarn.lock");
    
    auto pnpmGen = new NpmLockfileGenerator(null, NpmLockfileGenerator.NpmFlavor.Pnpm);
    Assert.equal(pnpmGen.lockfileName(), "pnpm-lock.yaml");
    
    writeln("\x1b[32m  ✓ NPM lockfile names correct\x1b[0m");
}

/// Test Cargo lockfile generator
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.generators.cargo - Lockfile name");
    
    auto generator = new CargoLockfileGenerator(null);
    Assert.equal(generator.lockfileName(), "Cargo.lock");
    Assert.equal(generator.type(), PackageManagerType.Cargo);
    
    writeln("\x1b[32m  ✓ Cargo lockfile name correct\x1b[0m");
}

/// Test Go lockfile generator
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.generators.go - Lockfile name");
    
    auto generator = new GoLockfileGenerator(null);
    Assert.equal(generator.lockfileName(), "go.sum");
    Assert.equal(generator.type(), PackageManagerType.Go);
    
    writeln("\x1b[32m  ✓ Go lockfile name correct\x1b[0m");
}

/// Test Maven lockfile generator
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.generators.maven - Lockfile name");
    
    auto generator = new MavenLockfileGenerator(null);
    Assert.equal(generator.lockfileName(), "dependency-lock.json");
    Assert.equal(generator.type(), PackageManagerType.Maven);
    
    writeln("\x1b[32m  ✓ Maven lockfile name correct\x1b[0m");
}

/// Test factory creation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.factory - Generator creation");
    
    // Test factory creates correct generators
    auto npmGen = LockfileFactory.create("package.json", null);
    Assert.isTrue(npmGen !is null);
    Assert.equal(npmGen.type(), PackageManagerType.Npm);
    
    auto cargoGen = LockfileFactory.create("Cargo.toml", null);
    Assert.isTrue(cargoGen !is null);
    Assert.equal(cargoGen.type(), PackageManagerType.Cargo);
    
    auto goGen = LockfileFactory.create("go.mod", null);
    Assert.isTrue(goGen !is null);
    Assert.equal(goGen.type(), PackageManagerType.Go);
    
    auto mavenGen = LockfileFactory.create("pom.xml", null);
    Assert.isTrue(mavenGen !is null);
    Assert.equal(mavenGen.type(), PackageManagerType.Maven);
    
    // Unknown manifest returns null
    auto unknownGen = LockfileFactory.create("unknown.xyz", null);
    Assert.isTrue(unknownGen is null);
    
    writeln("\x1b[32m  ✓ Factory creates correct generators\x1b[0m");
}

/// Test cache operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.cache - Basic operations");
    
    // Create temp cache directory
    import std.conv : to;
    string tempDir = "/tmp/builder-lockfile-test-" ~ Clock.currTime.stdTime.to!string;
    
    scope(exit)
    {
        // Cleanup
        if (exists(tempDir))
            rmdirRecurse(tempDir);
    }
    
    auto cache = new LockfileCache(tempDir);
    
    // Test cache miss
    auto result = cache.get("nonexistent-hash");
    Assert.isTrue(result.isErr());
    Assert.isFalse(cache.has("nonexistent-hash"));
    
    // Create and cache a lockfile
    Lockfile lockfile;
    lockfile.meta.format = "npm";
    lockfile.meta.manifestHash = "test-manifest-hash";
    
    ResolvedDependency dep;
    dep.name = "test-pkg";
    dep.version_ = "1.0.0";
    dep.integrity = "sha512-test";
    lockfile.dependencies = [dep];
    
    cache.put("test-manifest-hash", lockfile);
    
    // Test cache hit
    Assert.isTrue(cache.has("test-manifest-hash"));
    
    auto cached = cache.get("test-manifest-hash");
    Assert.isTrue(cached.isOk());
    
    auto retrieved = cached.unwrap();
    Assert.equal(retrieved.meta.format, "npm");
    Assert.equal(retrieved.count(), 1);
    Assert.equal(retrieved.dependencies[0].name, "test-pkg");
    
    // Test invalidation
    cache.invalidate("test-manifest-hash");
    Assert.isFalse(cache.has("test-manifest-hash"));
    
    // Test stats
    auto stats = cache.stats();
    Assert.equal(stats.entryCount, 0);
    
    writeln("\x1b[32m  ✓ Cache operations work\x1b[0m");
}

/// Test GenerateOptions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.types - GenerateOptions");
    
    // Default options
    auto defaults = GenerateOptions.init;
    Assert.isFalse(defaults.frozen);
    Assert.isFalse(defaults.update);
    Assert.isFalse(defaults.production);
    
    // CI options
    auto ci = GenerateOptions.ci();
    Assert.isTrue(ci.frozen);
    
    writeln("\x1b[32m  ✓ GenerateOptions work\x1b[0m");
}

/// Integration test with real package.json parsing
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.integration - NPM generation flow");
    
    // Create temp directory with package.json
    import std.conv : to;
    string tempDir = "/tmp/builder-lockfile-npm-test-" ~ Clock.currTime.stdTime.to!string;
    
    scope(exit)
    {
        if (exists(tempDir))
            rmdirRecurse(tempDir);
    }
    
    mkdirRecurse(tempDir);
    
    // Write minimal package.json
    string packageJson = `{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "lodash": "^4.17.21"
  },
  "devDependencies": {
    "jest": "^29.0.0"
  }
}`;
    
    std.file.write(buildPath(tempDir, "package.json"), packageJson);
    
    // Generate lockfile
    auto cache = new LockfileCache(buildPath(tempDir, ".cache"));
    auto generator = new NpmLockfileGenerator(cache);
    
    auto result = generator.generate(buildPath(tempDir, "package.json"), GenerateOptions.init);
    Assert.isTrue(result.isOk());
    
    auto lockfile = result.unwrap();
    Assert.equal(lockfile.meta.format, "npm");
    Assert.isTrue(lockfile.count() >= 2);  // lodash + jest
    
    // Verify dependencies exist
    auto lodash = lockfile.get("lodash");
    Assert.isTrue(lodash !is null);
    Assert.equal(lodash.version_, "4.17.21");
    Assert.isFalse(lodash.dev);
    
    auto jest = lockfile.get("jest");
    Assert.isTrue(jest !is null);
    Assert.isTrue(jest.dev);
    
    // Test write
    auto lockPath = buildPath(tempDir, "package-lock.json");
    auto writeResult = generator.write(lockfile, lockPath);
    Assert.isTrue(writeResult.isOk());
    Assert.isTrue(exists(lockPath));
    
    // Test cache hit on second generation
    auto result2 = generator.generate(buildPath(tempDir, "package.json"), GenerateOptions.init);
    Assert.isTrue(result2.isOk());
    
    writeln("\x1b[32m  ✓ NPM generation flow works\x1b[0m");
}

/// Test sorting for determinism
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lockfile.determinism - Dependency sorting");
    
    Lockfile lock1, lock2;
    lock1.meta.format = "npm";
    lock1.meta.manifestHash = "same";
    lock2.meta.format = "npm";
    lock2.meta.manifestHash = "same";
    
    // Add deps in different orders
    ResolvedDependency a, b, c;
    a.name = "a-pkg"; a.version_ = "1.0.0"; a.integrity = "sha-a";
    b.name = "b-pkg"; b.version_ = "2.0.0"; b.integrity = "sha-b";
    c.name = "c-pkg"; c.version_ = "3.0.0"; c.integrity = "sha-c";
    
    lock1.dependencies = [c, a, b];  // Unsorted
    lock2.dependencies = [b, c, a];  // Different unsorted order
    
    // Hashes should be equal despite different insertion order
    // (because hash() sorts internally)
    auto hash1 = lock1.hash();
    auto hash2 = lock2.hash();
    
    Assert.equal(hash1, hash2);
    
    writeln("\x1b[32m  ✓ Dependency sorting is deterministic\x1b[0m");
}

