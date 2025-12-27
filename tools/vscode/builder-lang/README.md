# Builder IDE - VS Code Extension

The complete IDE experience for the Builder build system. Go beyond basic LSP support with a full dashboard, dependency visualizer, Build-as-Code generator, and integrated CLI.

## Features

### 🚀 Build-as-Code Generator

Automatically generate `Builderfile` configurations from your project structure:

- **Smart Detection**: Detects languages, frameworks, entry points, and test files
- **Multi-Language Support**: Python, JavaScript/TypeScript, Rust, Go, C/C++, Java, Ruby, Elixir, and more
- **Framework Awareness**: Recognizes React, Vue, Next.js, Django, Flask, FastAPI, Express, Rails, Phoenix, etc.
- **One-Click Setup**: Generate complete build configurations instantly

```
Command Palette: "Builder: Generate Builderfile from Project"
```

### 📊 Interactive Dashboard

Real-time build status and project insights:

- **Target Overview**: See all build targets at a glance
- **Cache Statistics**: Monitor cache size, entries, and hit rate
- **Quick Actions**: Build, test, clean, and watch with one click
- **Build History**: Track recent build performance

```
Command Palette: "Builder: Open Dashboard"
Keyboard: Cmd+Shift+D (Mac) / Ctrl+Shift+D (Windows/Linux)
```

### 📈 Dependency Graph Visualizer

Interactive DAG visualization of your build targets:

- **Hierarchical Layout**: Clear visualization of dependency relationships
- **Click to Navigate**: Jump directly to target definitions
- **Double-Click to Build**: Build individual targets from the graph
- **Real-time Updates**: Graph updates as you modify Builderfile

```
Command Palette: "Builder: Show Dependency Graph"
```

### 🎯 Build Explorer Sidebar

Dedicated sidebar panel for build management:

- **Target Tree**: Browse all targets organized by type
- **Quick Actions**: Common commands always accessible
- **Cache Status**: Real-time cache monitoring
- **Click to Build**: Build individual targets directly

### 🔧 Full CLI Integration

Execute any Builder CLI command from VS Code:

| Command | Description |
|---------|-------------|
| `builder.build` | Build all targets |
| `builder.buildTarget` | Build specific target |
| `builder.test` | Run test targets |
| `builder.watch` | Enable watch mode |
| `builder.clean` | Clean build artifacts |
| `builder.query` | Query targets and dependencies |
| `builder.explore` | Interactive TUI explorer |
| `builder.telemetry` | View build analytics |

### 💡 Language Server Protocol (LSP)

Full IDE intelligence for Builderfile editing:

- **Code Completion**: Smart suggestions for targets, actions, variables
- **Go to Definition**: Jump to target/variable definitions
- **Find References**: Find all uses across files
- **Hover Information**: Documentation on hover
- **Rename Refactoring**: Safely rename targets and variables
- **Real-time Diagnostics**: Error detection as you type
- **Document Symbols**: Outline view of all targets

### ⚡ Zero-Config Detection

No Builderfile? No problem:

- Automatically detects project structure on workspace open
- Suggests Builderfile generation for detected languages
- Preview detected targets before committing

## Installation

### From VS Code Marketplace

1. Open VS Code
2. Go to Extensions (Cmd+Shift+X / Ctrl+Shift+X)
3. Search for "Builder"
4. Click Install

### From VSIX

```bash
code --install-extension builder-lang-3.0.0.vsix
```

## Configuration

### Extension Settings

```json
{
  // LSP
  "builder.lsp.enabled": true,
  "builder.lsp.trace.server": "off",
  "builder.lsp.serverPath": "",
  
  // CLI
  "builder.cli.path": "",
  
  // Dashboard
  "builder.dashboard.autoOpen": false,
  "builder.dashboard.showCacheStats": true,
  
  // Graph
  "builder.graph.layout": "hierarchical",
  
  // Auto Detection
  "builder.autoDetect.enabled": true,
  "builder.autoDetect.showNotification": true,
  
  // Build
  "builder.build.parallel": true,
  "builder.build.verbose": false,
  
  // Watch
  "builder.watch.clearOnRebuild": false
}
```

## Keyboard Shortcuts

| Shortcut | Command |
|----------|---------|
| `Cmd+Shift+B` / `Ctrl+Shift+B` | Build (when editing Builderfile) |
| `Cmd+Shift+D` / `Ctrl+Shift+D` | Open Dashboard |

## Supported File Types

- `Builderfile` - Main build configuration
- `Builderspace` - Workspace/monorepo configuration
- `*.builder` - Additional builder files
- `.builderignore` - File ignore patterns

## Activity Bar

The Builder icon in the activity bar provides:

- **Build Targets**: Tree view of all targets
- **Quick Actions**: Common operations
- **Cache Status**: Real-time cache info

## Task Provider

Integrates with VS Code's task system:

```json
{
  "type": "builder",
  "target": "main",
  "watch": false,
  "verbose": false
}
```

## Requirements

- VS Code 1.85.0 or higher
- Builder CLI installed (`bldr`)
- For LSP features: builder-lsp executable

## Troubleshooting

### LSP Not Working

1. Check LSP is enabled in settings
2. Verify builder-lsp is installed:
   ```bash
   which builder-lsp
   ```
3. Enable trace logging:
   ```json
   "builder.lsp.trace.server": "verbose"
   ```
4. Check Output panel → "Builder LSP"

### Build Commands Not Working

1. Verify Builder CLI is installed:
   ```bash
   which bldr
   ```
2. Check custom path setting if using non-standard location

### Dashboard Not Loading

1. Check Output panel → "Builder" for errors
2. Ensure workspace contains valid Builderfile
3. Try refreshing: Command Palette → "Builder: Refresh Explorer"

## Contributing

See [CONTRIBUTING.md](https://github.com/GriffinCanCode/bldr/blob/master/CONTRIBUTING.md) for development setup.

## License

See [LICENSE](https://github.com/GriffinCanCode/bldr/blob/master/LICENSE) in the bldr repository.
