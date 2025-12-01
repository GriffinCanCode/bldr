# Builder Distribution Files

This directory contains all distribution-related files for Builder, organized by platform and distribution method.

## Structure

```
distribution/
├── homebrew/          # Homebrew distribution files
│   ├── main/         # Main Builder formula
│   │   ├── builder.rb
│   │   └── README.md
│   └── plugins/      # Builder plugins tap
│       ├── Formula/
│       │   └── builder-plugin-example.rb
│       └── README.md
├── editors/           # Editor integrations
│   └── vscode/       # Visual Studio Code extension
│       ├── builder-lang-2.0.0.vsix
│       ├── builder-lang-1.0.0.vsix
│       └── README.md
├── lsp/              # Language Server Protocol
│   ├── binaries/     # LSP binaries for different platforms
│   │   └── builder-lsp-darwin-arm64
│   └── README.md
├── npm/              # NPM packages (future)
└── README.md         # This file
```

## Homebrew Distribution

### Main Formula (`homebrew/main/`)

Contains the official Homebrew formula for installing Builder.

**Location for tap**: This should be placed in a tap repository like:
- `homebrew-builder/Formula/builder.rb`
- Or submitted to Homebrew core

**Install command**:
```bash
# If in a custom tap
brew tap builder/bldr
brew install bldr

# If in Homebrew core
brew install bldr
```

### Plugins Tap (`homebrew/plugins/`)

Contains the Homebrew tap for Builder plugins. This is a separate tap that allows users to install Builder plugins via Homebrew.

**Usage**:
1. Create a separate repository for the plugins tap (e.g., `homebrew-builder-plugins`)
2. Copy contents from `homebrew/plugins/` to the repository root
3. Users can then tap it:
   ```bash
   brew tap builder/builder-plugins
   brew install bldr-plugin-docker
   ```

**Adding new plugins**:
- Add formula to `Formula/` directory
- Name it `builder-plugin-<name>.rb`
- Update the plugins list in `README.md`

## Publishing Releases

### For Main Builder

1. Tag a new release in the Builder repository
2. Update `version` and `sha256` in `homebrew/main/builder.rb`
3. Test the formula:
   ```bash
   brew install --build-from-source homebrew/main/builder.rb
   brew test builder
   ```
4. Submit to tap or Homebrew core

### For Plugins

1. Tag a new release in the plugin repository
2. Create/update the plugin formula in `homebrew/plugins/Formula/`
3. Test the formula
4. Commit to the plugins tap repository

## Editor Integrations

### VSCode Extension (`editors/vscode/`)

Contains distributable VSCode extension packages (.vsix files).

**Current version**: `builder-lang-2.0.0.vsix`

**Features**:
- Syntax highlighting for Builderfile and Builderspace
- Full LSP integration (code completion, go to definition, etc.)
- Custom file icons
- Build command integration

**Installation**:
```bash
code --install-extension editors/vscode/builder-lang-2.0.0.vsix
```

**Publishing**:
1. Build new version: `vsce package` in `tools/vscode/builder-lang/`
2. Copy `.vsix` to `editors/vscode/`
3. Publish to marketplace: `vsce publish`
4. Publish to Open VSX: `npx ovsx publish`

**Documentation**: See [editors/vscode/README.md](editors/vscode/README.md)

### Future Editor Support

Add support for additional editors:
- `editors/vim/` - Vim plugin
- `editors/emacs/` - Emacs package
- `editors/sublime/` - Sublime Text package
- `editors/intellij/` - IntelliJ IDEA plugin

## Language Server Protocol

### LSP Server (`lsp/`)

Contains LSP server binaries for different platforms.

**Supported platforms**:
- macOS (ARM64, x86_64)
- Linux (x86_64, ARM64)
- Windows (x86_64)

**Installation**:
```bash
# Standalone
curl -L -o builder-lsp [URL]
chmod +x builder-lsp
sudo mv builder-lsp /usr/local/bin/

# Via Homebrew
brew install bldr  # LSP included
```

**Editor compatibility**:
- VSCode (bundled with extension)
- Neovim (via nvim-lspconfig)
- Vim (via vim-lsp)
- Emacs (via lsp-mode)
- Sublime Text (via LSP package)
- Helix (native LSP support)
- Any LSP-compatible editor

**Building**:
```bash
dub build :lsp --build=release --compiler=ldc2
```

**Documentation**: See [lsp/README.md](lsp/README.md)

## Future Distribution Methods

Add additional distribution methods to this directory as needed:
- `debian/` - Debian package files (.deb)
- `rpm/` - RPM package files
- `docker/` - Dockerfiles and container images
- `snap/` - Snap package definitions
- `flatpak/` - Flatpak package definitions
- `windows/` - Windows installer scripts/configurations
- `npm/` - NPM package wrapper (if applicable)

## Development

When making changes to distribution files:
1. Test locally first
2. Update version numbers and checksums
3. Test installation from the formula/package
4. Document any new dependencies or requirements

## Resources

- [Homebrew Formula Documentation](https://docs.brew.sh/Formula-Cookbook)
- [Creating Homebrew Taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Builder Documentation](../docs/README.md)

