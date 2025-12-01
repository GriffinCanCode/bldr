# Builder Language Server Protocol (LSP)

Official Language Server Protocol implementation for Builder build system.

## Overview

The Builder LSP provides intelligent code editing features for Builderfile and Builderspace configuration files across all LSP-compatible editors.

## Features

- **Code Completion** - Intelligent suggestions for targets, actions, variables
- **Go to Definition** - Jump to target/variable definitions
- **Find References** - Find all uses of targets and variables
- **Hover Information** - Documentation and type information on hover
- **Rename Refactoring** - Safely rename targets and variables across files
- **Diagnostics** - Real-time error detection and validation
- **Document Symbols** - Outline view of targets and variables

## Distribution

### Binaries

Platform-specific binaries are provided in the `binaries/` directory:

```
binaries/
├── builder-lsp-darwin-arm64      # macOS Apple Silicon
├── builder-lsp-darwin-x86_64     # macOS Intel
├── builder-lsp-linux-x86_64      # Linux x86_64
├── builder-lsp-linux-aarch64     # Linux ARM64
└── builder-lsp-windows-x86_64.exe # Windows x86_64
```

### Installation Methods

#### 1. Standalone Binary

Download the appropriate binary for your platform:

```bash
# macOS ARM64
curl -L -o builder-lsp https://github.com/GriffinCanCode/Builder/releases/latest/download/bldr-lsp-darwin-arm64
chmod +x builder-lsp
sudo mv builder-lsp /usr/local/bin/
```

```bash
# Linux x86_64
curl -L -o builder-lsp https://github.com/GriffinCanCode/Builder/releases/latest/download/bldr-lsp-linux-x86_64
chmod +x builder-lsp
sudo mv builder-lsp /usr/local/bin/
```

```powershell
# Windows (PowerShell)
curl -L -o builder-lsp.exe https://github.com/GriffinCanCode/Builder/releases/latest/download/bldr-lsp-windows-x86_64.exe
# Add to PATH or place in system directory
```

#### 2. Via Homebrew (macOS/Linux)

```bash
brew install bldr
# LSP is included with Builder installation
```

#### 3. Via Package Managers

```bash
# NPM (cross-platform)
npm install -g builder-lsp

# Cargo (Rust)
cargo install builder-lsp

# AUR (Arch Linux)
yay -S builder-lsp
```

#### 4. From Source

```bash
git clone https://github.com/GriffinCanCode/Builder.git
cd Builder
dub build --build=release
# Binary will be in bin/bldr-lsp
```

## Editor Integration

### Visual Studio Code

Install the official extension:
- See [VSCode Extension Documentation](../editors/vscode/README.md)
- LSP is bundled with the extension
- Alternatively, install standalone and configure path

### Neovim

Using nvim-lspconfig:

```lua
-- ~/.config/nvim/init.lua or lua/lsp-config.lua
local lspconfig = require('lspconfig')

lspconfig.builder_lsp.setup{
  cmd = { "builder-lsp" },
  filetypes = { "builder" },
  root_dir = lspconfig.util.root_pattern("Builderspace", "Builderfile"),
  settings = {},
}

-- Configure filetype detection
vim.filetype.add({
  filename = {
    ['Builderfile'] = 'builder',
    ['Builderspace'] = 'builder',
  },
  extension = {
    builder = 'builder',
  },
})
```

### Vim (with vim-lsp)

```vim
" ~/.vimrc or ~/.vim/after/ftplugin/builder.vim
if executable('builder-lsp')
    au User lsp_setup call lsp#register_server({
        \ 'name': 'builder-lsp',
        \ 'cmd': {server_info->['builder-lsp']},
        \ 'whitelist': ['builder'],
        \ })
endif

" Filetype detection
au BufRead,BufNewFile Builderfile,Builderspace setfiletype builder
au BufRead,BufNewFile *.builder setfiletype builder
```

### Emacs (with lsp-mode)

```elisp
;; ~/.emacs.d/init.el or builder-mode.el
(require 'lsp-mode)

(add-to-list 'lsp-language-id-configuration '(builder-mode . "builder"))

(lsp-register-client
 (make-lsp-client :new-connection (lsp-stdio-connection "builder-lsp")
                  :major-modes '(builder-mode)
                  :server-id 'builder-lsp))

;; Define builder-mode
(define-derived-mode builder-mode prog-mode "Builder"
  "Major mode for editing Builder configuration files."
  (setq-local comment-start "# "))

;; Filetype associations
(add-to-list 'auto-mode-alist '("Builderfile\\'" . builder-mode))
(add-to-list 'auto-mode-alist '("Builderspace\\'" . builder-mode))
(add-to-list 'auto-mode-alist '("\\.builder\\'" . builder-mode))

;; Enable LSP
(add-hook 'builder-mode-hook #'lsp)
```

### Sublime Text (with LSP package)

1. Install LSP package via Package Control
2. Add to LSP settings (`Preferences` → `Package Settings` → `LSP` → `Settings`):

```json
{
  "clients": {
    "builder-lsp": {
      "enabled": true,
      "command": ["builder-lsp"],
      "selector": "source.builder",
      "languageId": "builder"
    }
  }
}
```

3. Add syntax highlighting in `Packages/User/Builder.sublime-syntax`

### Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "builder"
scope = "source.builder"
file-types = ["Builderfile", "Builderspace", "builder"]
comment-token = "#"
language-servers = ["builder-lsp"]

[language-server.builder-lsp]
command = "builder-lsp"
```

### Kate/KWrite

1. Enable LSP Client plugin in Settings
2. Configure in `Settings` → `Configure Kate` → `LSP Client`:

```json
{
  "servers": {
    "builder": {
      "command": ["builder-lsp"],
      "url": "https://github.com/GriffinCanCode/Builder",
      "highlightingModeRegex": "^Builder$"
    }
  }
}
```

## Protocol Specification

The Builder LSP implements the Language Server Protocol 3.17 specification.

### Supported Methods

#### Lifecycle
- `initialize`
- `initialized`
- `shutdown`
- `exit`

#### Text Document Synchronization
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didSave`
- `textDocument/didClose`

#### Language Features
- `textDocument/completion`
- `textDocument/hover`
- `textDocument/definition`
- `textDocument/references`
- `textDocument/rename`
- `textDocument/documentSymbol`
- `textDocument/publishDiagnostics`

### Server Capabilities

```json
{
  "completionProvider": {
    "resolveProvider": false,
    "triggerCharacters": [".", ":", "$"]
  },
  "hoverProvider": true,
  "definitionProvider": true,
  "referencesProvider": true,
  "renameProvider": true,
  "documentSymbolProvider": true,
  "textDocumentSync": {
    "openClose": true,
    "change": 2,
    "save": true
  }
}
```

## Configuration

The LSP server accepts configuration through initialization options:

```json
{
  "builder": {
    "trace": "off",           // off | messages | verbose
    "maxNumberOfProblems": 100,
    "cacheDir": "~/.builder/cache",
    "validateOnSave": true,
    "validateOnType": true
  }
}
```

## Building from Source

### Prerequisites

- D compiler (ldc2 or dmd)
- dub (D package manager)

### Build

```bash
cd Builder
dub build :lsp --build=release --compiler=ldc2
```

The binary will be output to `bin/bldr-lsp`.

### Cross-compilation

For different platforms:

```bash
# macOS ARM64
dub build :lsp --build=release --compiler=ldc2 --arch=arm64-apple-macos

# Linux x86_64
dub build :lsp --build=release --compiler=ldc2 --arch=x86_64-linux-gnu

# Windows x86_64
dub build :lsp --build=release --compiler=ldc2 --arch=x86_64-windows-msvc
```

## Testing

Test the LSP server:

```bash
# Run unit tests
dub test :lsp

# Manual testing with stdio
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' | builder-lsp

# Integration tests
cd tests
./test-lsp-integration.sh
```

## Troubleshooting

### LSP Not Starting

1. Verify installation:
   ```bash
   which builder-lsp
   builder-lsp --version
   ```

2. Check permissions:
   ```bash
   chmod +x $(which builder-lsp)
   ```

3. Test manually:
   ```bash
   builder-lsp --stdio
   # Should wait for input, Ctrl+C to exit
   ```

### LSP Not Responding

1. Enable trace logging in your editor
2. Check LSP output/logs
3. Verify file paths are correct
4. Ensure Builderfile/Builderspace are in workspace root

### Performance Issues

- Reduce `maxNumberOfProblems` in configuration
- Disable `validateOnType`, keep only `validateOnSave`
- Ensure cache directory is on fast storage

## Performance

- **Startup time**: < 100ms
- **Completion latency**: < 50ms
- **Memory usage**: ~10-20MB per workspace
- **CPU usage**: < 1% idle, ~5-10% during active editing

## Release Process

1. Build binaries for all platforms:
   ```bash
   ./tools/build-lsp-binaries.sh
   ```

2. Copy binaries to distribution folder:
   ```bash
   cp bin/bldr-lsp-* distribution/lsp/binaries/
   ```

3. Create release on GitHub with binaries attached

4. Update package managers (npm, Homebrew, etc.)

## Support

- [Builder Documentation](https://github.com/GriffinCanCode/Builder/tree/master/docs)
- [LSP Source Code](../../source/lsp/)
- [Report Issues](https://github.com/GriffinCanCode/Builder/issues)
- [LSP Specification](https://microsoft.github.io/language-server-protocol/)

## Contributing

See [LSP Development Guide](../../source/lsp/README.md)

## License

See LICENSE file in the Builder repository.

