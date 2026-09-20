# Changelog

## [Unreleased]

## [2.1.0] - 2026-09-20

### Added

- **Dependency link propagation** - `deps` now contributes to the link line, not just build order:
  - Transitive closure of library dependencies, ordered dependents-first for the linker's single left-to-right pass
  - Static vs shared decided by the dependency's own declared `outputType`; shared deps also carry an rpath
  - A dependency's `includes` propagate to dependents' include path
  - Traversal stops at non-library targets, which remain ordering edges only
  - Wired into C/C++, D and Zig; Rust, Nim and Go still treat `deps` as ordering only
  - A dependency artifact that is not on disk is skipped with a warning rather than failing, so workspaces that relied on ordering alone keep building

- **`workspace "name"` declarations** parse in Builderfiles, in both the bare and
  parenthesized (`workspace("name") { … }`) spellings

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


### Fixed

- **Builds did not rebuild on source change** once any warm cache existed. Three
  separate persistence layers each dropped state they were standing in for:
  - The config cache serialized 6 of `Target`'s 15 fields, losing `includes`, `flags`, `env`, `langConfig`, `command`, `workdir`, `root`, `platform` and `toolchain` on every warm build
  - Graph restore rebuilt forward edges but never `dependentIds`, so a finished dependency released none of its dependents and they were dropped from the build silently
  - The analyzer treated the mmap-restored graph as authoritative for target definitions, but that format stores topology only — restored targets reported no sources, which reads as "nothing changed"

- **Language config blocks did not parse at all.** `cpp: { … }`, `cuda: { … }` and
  friends were unreadable, leaving `langConfig` permanently empty:
  - Map literals accepted only comma separators; blocks are written with semicolons
  - A brace-delimited field value is now self-terminating, so no trailing `;` is required

- **Language inference never ran.** The guard tested for `TargetLanguage.Generic`,
  but an omitted `language` field defaults to the first enum member, so a C++
  target without an explicit `language` was handed to the D handler

- **`dub test` never terminated.** Worker pool threads were non-daemon, and
  druntime joins all threads before module destructors, so a pool that was never
  explicitly shut down hung process exit ahead of any cleanup hook
