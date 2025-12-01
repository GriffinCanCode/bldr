# Builder VSCode Extension

Official Visual Studio Code extension for Builder build system.

## Available Versions

- `builder-lang-2.0.0.vsix` - Latest version with LSP support
- `builder-lang-1.0.0.vsix` - Legacy version (syntax highlighting only)

## Installation

### Quick Install

```bash
code --install-extension builder-lang-2.0.0.vsix
```

Then reload VS Code:
- Press `Cmd+Shift+P` (Mac) or `Ctrl+Shift+P` (Windows/Linux)
- Type "Reload Window" and press Enter

### From VS Code UI

1. Open VS Code
2. Press `Cmd+Shift+P` / `Ctrl+Shift+P`
3. Type "Extensions: Install from VSIX"
4. Select the `builder-lang-2.0.0.vsix` file
5. Reload window when prompted

## Features

### Version 2.0.0 (Current)

- ✅ Full syntax highlighting for Builderfile and Builderspace
- ✅ Language Server Protocol (LSP) integration
  - Intelligent code completion
  - Go to definition
  - Find all references
  - Hover information
  - Rename refactoring
  - Real-time diagnostics
- ✅ Custom file icons for Builder files
- ✅ Auto-closing brackets and quotes
- ✅ Comment toggling (`Cmd+/` or `Ctrl+/`)
- ✅ Code folding
- ✅ Build command integration
- ✅ Configurable LSP settings

### Version 1.0.0 (Legacy)

- ✅ Basic syntax highlighting
- ✅ Custom file icons
- ✅ Auto-closing brackets
- ✅ Comment toggling

## Configuration

The extension can be configured via VS Code settings:

```json
{
  // Enable/disable LSP support
  "builder.lsp.enabled": true,
  
  // LSP trace level (off, messages, verbose)
  "builder.lsp.trace.server": "off",
  
  // Custom path to builder-lsp executable
  // Leave empty for auto-detection
  "builder.lsp.serverPath": ""
}
```

### LSP Server Detection

The extension will automatically detect the LSP server in this order:

1. Custom path specified in `builder.lsp.serverPath` setting
2. Bundled LSP server (included in extension)
3. System-wide installation (`builder-lsp` in PATH)
4. Homebrew installation (`/opt/homebrew/bin/bldr-lsp`)

## Commands

Available commands (accessible via Command Palette):

- **Builder: Run Build** - Execute build in current workspace

## Supported File Types

The extension activates for:

- `Builderfile` - Main build configuration
- `Builderspace` - Workspace/monorepo configuration
- `*.builder` - Builder configuration files

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
   vsce package
   ```
4. Copy `.vsix` to this distribution folder
5. Tag the release

### Publish to VS Code Marketplace

```bash
vsce publish
```

Or publish manually:
1. Go to [Visual Studio Marketplace Publishing Portal](https://marketplace.visualstudio.com/manage)
2. Upload the `.vsix` file
3. Fill in metadata and publish

### Publish to Open VSX (for VSCodium, etc.)

```bash
npx ovsx publish builder-lang-2.0.0.vsix -p YOUR_TOKEN
```

## Development

To develop the extension locally:

```bash
cd tools/vscode/builder-lang
npm install
```

Then press F5 in VS Code to launch Extension Development Host.

## Changelog

### v2.0.0
- Added full LSP integration
- Intelligent code completion
- Go to definition, find references
- Hover documentation
- Rename refactoring
- Real-time diagnostics
- Build command integration
- Configurable LSP settings

### v1.0.0
- Initial release
- Syntax highlighting
- Custom file icons
- Basic editor support

## Requirements

- VS Code 1.75.0 or higher
- Builder build system installed
- For LSP features: builder-lsp executable (bundled or installed separately)

## Troubleshooting

### LSP Not Working

1. Check LSP is enabled:
   ```json
   "builder.lsp.enabled": true
   ```

2. Verify LSP server path:
   - Open Command Palette
   - Type "Developer: Show Running Extensions"
   - Look for "Builder Language Support"
   - Check output for LSP connection errors

3. Enable verbose logging:
   ```json
   "builder.lsp.trace.server": "verbose"
   ```

4. Check LSP output channel:
   - View → Output
   - Select "Builder Language Server" from dropdown

### Extension Not Activating

- Ensure file is named `Builderfile`, `Builderspace`, or has `.builder` extension
- Check VS Code version is 1.75.0 or higher
- Try reloading window (`Cmd+Shift+P` → "Reload Window")

## Support

- [Builder Documentation](https://github.com/GriffinCanCode/Builder/tree/master/docs)
- [Extension Issues](https://github.com/GriffinCanCode/Builder/issues)
- [LSP Documentation](../../lsp/README.md)

## License

See LICENSE file in the Builder repository.

