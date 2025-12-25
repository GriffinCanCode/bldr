# Changelog

## [Unreleased]

### Added

- **Deterministic Lockfile Generation** - Reproducible builds through unified lockfile generation for all supported package managers:
  - **npm/yarn/pnpm**: Generates `package-lock.json`, `yarn.lock`, or `pnpm-lock.yaml`
  - **Cargo**: Generates `Cargo.lock` for Rust projects
  - **Go modules**: Generates `go.sum` checksums
  - **Maven**: Generates `dependency-lock.json` for Java/Kotlin projects
  
  Key features:
  - Content-addressable caching (pnpm-inspired) - resolution results cached by manifest hash
  - Deterministic output - sorted alphabetically, canonical formatting, platform-independent
  - Incremental diff tracking - `LockfileDiff.compute()` shows added/removed/updated deps
  - CI mode (`frozen = true`) - fails if lockfile would change
  
  ```d
  import infrastructure.analysis.lockfile;
  
  auto cache = new LockfileCache();
  auto generator = LockfileFactory.create("package.json", cache);
  auto result = generator.generate("package.json");
  ```

