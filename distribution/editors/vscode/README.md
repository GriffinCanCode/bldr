# Builder VSCode Extension

Official Visual Studio Code extension for Builder build system - the complete IDE experience.

## Available Versions

- `builder-lang-3.0.0.vsix` - **Latest**: Full IDE with Dashboard, Graph Visualizer, Build-as-Code
- `builder-lang-2.0.0.vsix` - LSP support with code intelligence
- `builder-lang-1.0.0.vsix` - Legacy (syntax highlighting only)

## Installation

### Quick Install

```bash
code --install-extension builder-lang-3.0.0.vsix
```

Then reload VS Code:
- Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
- Type "Reload Window" and press Enter

### From VS Code UI

1. Open VS Code
2. Press `Cmd+Shift+P` / `Ctrl+Shift+P`
3. Type "Extensions: Install from VSIX"
4. Select the `builder-lang-3.0.0.vsix` file
5. Reload window when prompted

## Features

### Version 3.0.0 (Current)

**Build-as-Code Generator**
- 🔍 Automatic project structure analysis
- 🎯 Smart language/framework detection
- ⚡ One-click Builderfile generation
- 📦 Entry point and test file detection

**Interactive Dashboard**
- 📊 Real-time build target overview
- 💾 Cache statistics with hit rate
- ⚡ Quick action buttons
- 📈 Build performance tracking

**Dependency Graph Visualizer**
- 🌳 Interactive DAG visualization
- 🔗 Click to navigate to targets
- ⚡ Double-click to build
- 🔄 Auto-updates on changes

**Build Explorer Sidebar**
- 📁 Tree view of all targets
- ⚡ Quick actions panel
- 💾 Cache status monitoring
- 🎯 Click-to-build

**Full CLI Integration**
- ▶️ Build all or specific targets
- 🧪 Test execution
- 👁️ Watch mode
- 🧹 Clean artifacts
- 🔍 Query targets
- 📊 Analytics view

**LSP Intelligence**
- ✅ Code completion
- 🔍 Go to definition
- 📍 Find all references
- 📝 Hover documentation
- ✏️ Rename refactoring
- ⚠️ Real-time diagnostics

### Version 2.0.0

- ✅ Full syntax highlighting for Builderfile and Builderspace
- ✅ Language Server Protocol (LSP) integration
- ✅ Custom file icons for Builder files
- ✅ Build command integration
- ✅ Configurable LSP settings

### Version 1.0.0 (Legacy)

- ✅ Basic syntax highlighting
- ✅ Custom file icons
- ✅ Auto-closing brackets
- ✅ Comment toggling

## Configuration

```json
{
  // LSP
  "builder.lsp.enabled": true,
  "builder.lsp.trace.server": "off",
  "builder.lsp.serverPath": "",
  
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
| `Cmd+Shift+B` / `Ctrl+Shift+B` | Build (in Builderfile) |
| `Cmd+Shift+D` / `Ctrl+Shift+D` | Open Dashboard |

## Commands

All commands accessible via Command Palette (`Cmd/Ctrl+Shift+P`):

| Command | Description |
|---------|-------------|
| Builder: Run Build | Build all targets |
| Builder: Build Specific Target | Build selected target |
| Builder: Run Tests | Execute test targets |
| Builder: Watch Mode | Auto-rebuild on changes |
| Builder: Clean Build Artifacts | Remove build outputs |
| Builder: Open Dashboard | Open interactive dashboard |
| Builder: Show Dependency Graph | Visualize target dependencies |
| Builder: Generate Builderfile | Auto-generate from project |
| Builder: Preview Auto-detected Targets | Preview before generating |
| Builder: Run Setup Wizard | Interactive configuration |
| Builder: Query Targets | Query build graph |
| Builder: View Build Analytics | Performance insights |

## Supported File Types

- `Builderfile` - Main build configuration
- `Builderspace` - Workspace/monorepo configuration
- `*.builder` - Builder configuration files
- `.builderignore` - Ignore patterns

## Publishing to Marketplace

### Prerequisites

```bash
npm install -g @vscode/vsce
```

### Build New Version

1. Update version in `package.json`
2. Update `CHANGELOG.md`
3. Build the extension:
   ```bash
   cd tools/vscode/builder-lang
   npm install
   npm run compile
   vsce package
   ```
4. Copy `.vsix` to this distribution folder
5. Tag the release

### Publish to VS Code Marketplace

```bash
vsce publish
```

### Publish to Open VSX (for VSCodium, etc.)

```bash
npx ovsx publish builder-lang-3.0.0.vsix -p YOUR_TOKEN
```

## Development

To develop the extension locally:

```bash
cd tools/vscode/builder-lang
npm install
npm run watch
```

Then press F5 in VS Code to launch Extension Development Host.

## Changelog

See [CHANGELOG.md](../../../tools/vscode/builder-lang/CHANGELOG.md) for full version history.

## Requirements

- VS Code 1.85.0 or higher
- Builder build system installed
- For LSP features: builder-lsp executable

## Troubleshooting

### Extension Not Activating

- Ensure file is named `Builderfile`, `Builderspace`, or has `.builder` extension
- Check VS Code version is 1.85.0 or higher
- Try reloading window (`Cmd+Shift+P` → "Reload Window")

### LSP Not Working

1. Check LSP is enabled:
   ```json
   "builder.lsp.enabled": true
   ```

2. Verify LSP server path:
   - Open Command Palette
   - Type "Developer: Show Running Extensions"
   - Check output for LSP connection errors

3. Enable verbose logging:
   ```json
   "builder.lsp.trace.server": "verbose"
   ```

4. Check LSP output channel:
   - View → Output
   - Select "Builder LSP" from dropdown

### Dashboard Not Loading

1. Check Output panel → "Builder" for errors
2. Ensure workspace contains valid Builderfile
3. Try refreshing: Command Palette → "Builder: Refresh Explorer"

## Support

- [Builder Documentation](https://github.com/GriffinCanCode/bldr/tree/master/docs)
- [Extension Issues](https://github.com/GriffinCanCode/bldr/issues)
- [LSP Documentation](../../lsp/README.md)

## License

See LICENSE file in the Builder repository.
