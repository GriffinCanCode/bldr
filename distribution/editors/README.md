# Builder Editor Integrations

Official editor integrations and extensions for Builder build system.

## Available Editors

### Visual Studio Code

**Status**: ✅ Production Ready

Full-featured extension with LSP integration.

- **Location**: `vscode/`
- **Current Version**: 2.0.0
- **Installation**: `code --install-extension vscode/builder-lang-2.0.0.vsix`
- **Documentation**: [vscode/README.md](vscode/README.md)
- **Marketplace**: [Builder Language Support](https://marketplace.visualstudio.com/)

**Features**:
- Syntax highlighting
- LSP integration (completion, go-to-definition, etc.)
- Custom file icons
- Build command integration
- Real-time diagnostics

## Future Editor Support

### Neovim

**Status**: 📝 Planned

Native LSP support via nvim-lspconfig.

**Configuration** (available now):
```lua
require('lspconfig').builder_lsp.setup{
  cmd = { "builder-lsp" },
  filetypes = { "builder" },
}
```

**Future enhancements**:
- Treesitter grammar for better syntax highlighting
- Dedicated Neovim plugin for builder-specific features
- Telescope integration for target selection

### Vim

**Status**: 📝 Planned

Support via vim-lsp or coc.nvim.

**Planned features**:
- Syntax highlighting file (`.vim`)
- LSP integration via vim-lsp
- Build command shortcuts
- Target completion

### Emacs

**Status**: 📝 Planned

Major mode with lsp-mode integration.

**Planned features**:
- `builder-mode` major mode
- LSP integration via lsp-mode
- Syntax highlighting
- Interactive build commands
- Compilation mode integration

### Sublime Text

**Status**: 📝 Planned

Package with LSP support.

**Planned features**:
- Syntax definition
- LSP integration via LSP package
- Build systems integration
- Color schemes

### IntelliJ IDEA / JetBrains IDEs

**Status**: 📝 Planned

Plugin for IntelliJ platform (IntelliJ IDEA, PyCharm, WebStorm, etc.).

**Planned features**:
- Full language support
- Custom LSP integration
- Build tool window
- Target run configurations
- Dependency graph visualization

### Eclipse

**Status**: 📝 Planned

Eclipse plugin with LSP4E integration.

**Planned features**:
- Builder nature and perspective
- LSP integration via LSP4E
- Build integration
- Project templates

## Adding New Editor Support

### Requirements

1. **Syntax Highlighting**: Define Builder syntax grammar
2. **LSP Integration**: Connect to builder-lsp server
3. **File Type Detection**: Register Builderfile, Builderspace, .builder files
4. **Build Integration**: Execute Builder commands from editor
5. **Documentation**: Usage guide and configuration examples

### Development Process

1. **Create editor-specific directory**:
   ```bash
   mkdir -p distribution/editors/<editor-name>
   ```

2. **Implement basic features**:
   - File type recognition
   - Syntax highlighting
   - LSP client integration

3. **Add Builder-specific features**:
   - Build commands
   - Target selection
   - Cache management
   - Watch mode integration

4. **Package for distribution**:
   - Create distributable package
   - Add to editor's package registry
   - Document installation process

5. **Documentation**:
   - Create README in editor directory
   - Add configuration examples
   - Include troubleshooting guide

### LSP Integration Guide

All editors can use the Builder LSP server. See [LSP Documentation](../lsp/README.md) for:
- Installation instructions
- Configuration examples
- Supported capabilities
- Troubleshooting guide

### Contributing

To add support for a new editor:

1. Fork the Builder repository
2. Create editor integration in `tools/<editor>/`
3. Add distributable to `distribution/editors/<editor>/`
4. Include comprehensive documentation
5. Test on multiple platforms
6. Submit pull request

See [Contributing Guide](../../CONTRIBUTING.md)

## Editor Feature Matrix

| Feature | VSCode | Neovim | Vim | Emacs | Sublime | IntelliJ | Eclipse |
|---------|--------|--------|-----|-------|---------|----------|---------|
| Syntax Highlighting | ✅ | 📝 | 📝 | 📝 | 📝 | 📝 | 📝 |
| LSP Support | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| Code Completion | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| Go to Definition | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| Find References | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| Hover Info | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| Diagnostics | ✅ | ✅* | ✅* | ✅* | ✅* | 📝 | 📝 |
| File Icons | ✅ | ❌ | ❌ | ❌ | 📝 | 📝 | 📝 |
| Build Commands | ✅ | 📝 | 📝 | 📝 | 📝 | 📝 | 📝 |

Legend:
- ✅ Implemented
- ✅* Available via LSP (manual configuration required)
- 📝 Planned
- ❌ Not applicable

## Support and Resources

- [Builder Documentation](../../docs/README.md)
- [LSP Server Documentation](../lsp/README.md)
- [Issue Tracker](https://github.com/GriffinCanCode/bldr/issues)
- [Development Guide](../../docs/development/TESTING.md)

## Community Contributions

We welcome community contributions for editor support! If you've created an integration:

1. Share in GitHub Discussions
2. Submit PR to include in official distribution
3. We'll help with packaging and distribution

### Community Plugins

| Editor | Plugin | Author | Status |
|--------|--------|--------|--------|
| - | - | - | - |

*Submit your plugin to be listed here!*

