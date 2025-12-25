# Changelog

## [Unreleased]

### Added

- **LSP Workspace Symbol Search** (`workspace/symbol`) - Ctrl+T now searches all targets across the workspace:
  - Fuzzy matching by target name
  - Results sorted by relevance (exact prefix matches first)
  - Shows file location as container name for easy navigation

- **LSP Cross-File Workspace Scanning** - On initialization, LSP now indexes all Builderfiles in the workspace:
  - Scans `Builderfile`, `Builderspace`, `*.builder`, `*.builderfile` files
  - Enables workspace-wide go-to-definition, find references, and rename
  - Rename refactoring now works across all files in workspace

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

