# Changelog

All notable changes to the Builder VS Code Extension.

## [3.0.0] - 2024-12-26

### Added

- **Build-as-Code Generator**: Automatically generate Builderfile from project structure
  - Smart language detection (Python, JS/TS, Rust, Go, C/C++, Java, Ruby, Elixir, etc.)
  - Framework awareness (React, Vue, Next.js, Django, Flask, FastAPI, Express, Rails, Phoenix)
  - Entry point and test file detection
  - One-click Builderfile generation

- **Interactive Dashboard**: Real-time project insights
  - Target overview with counts and types
  - Cache statistics (size, entries, hit rate)
  - Quick action buttons (build, test, clean, watch)
  - Build history tracking

- **Dependency Graph Visualizer**: Interactive DAG visualization
  - Hierarchical layout of build targets
  - Click to navigate to target definitions
  - Double-click to build individual targets
  - Real-time updates on Builderfile changes

- **Build Explorer Sidebar**: Dedicated activity bar panel
  - Tree view of all targets organized by type
  - Quick actions panel
  - Cache status monitoring
  - Click-to-build functionality

- **Enhanced CLI Integration**:
  - Build specific targets with quick pick
  - Query targets and dependencies
  - Interactive TUI explorer
  - Telemetry and analytics viewer
  - Watch mode with configurable options

- **Zero-Config Detection**:
  - Automatic project structure detection on workspace open
  - Notification with Builderfile generation suggestion
  - Preview detected targets before committing

- **New Commands**:
  - `builder.generateBuilderfile` - Generate Builderfile from project
  - `builder.previewTargets` - Preview auto-detected targets
  - `builder.runWizard` - Run interactive setup wizard
  - `builder.showDashboard` - Open dashboard panel
  - `builder.showGraph` - Show dependency graph
  - `builder.buildTarget` - Build specific target
  - `builder.query` - Query targets
  - `builder.explore` - Interactive explorer
  - `builder.telemetry` - Build analytics
  - `builder.cacheStats` - Cache statistics

- **Task Provider**: Integration with VS Code task system

- **Keyboard Shortcuts**:
  - `Cmd/Ctrl+Shift+D` - Open Dashboard
  - `Cmd/Ctrl+Shift+B` - Build (when editing Builderfile)

### Changed

- Migrated to TypeScript for better type safety
- Modular architecture with separate providers, commands, and webviews
- Improved LSP server detection with platform-specific binary support
- Enhanced status bar with dashboard access

### Technical

- esbuild bundling for faster builds
- Proper Content Security Policy for webviews
- Tree data providers for sidebar views
- File system watchers for auto-refresh

## [2.0.3] - 2024-12-01

### Fixed
- LSP server path detection on Apple Silicon

## [2.0.2] - 2024-11-15

### Fixed
- Build command terminal handling

## [2.0.1] - 2024-11-01

### Fixed
- Extension activation on startup

## [2.0.0] - 2024-10-15

### Added
- Full LSP integration
- Intelligent code completion
- Go to definition, find references
- Hover documentation
- Rename refactoring
- Real-time diagnostics
- Build command integration

## [1.0.0] - 2024-09-01

### Added
- Initial release
- Syntax highlighting
- Custom file icons
- Basic editor support
