# Builder Language Server Protocol (LSP) Guide

This guide explains how to use the Builder Language Server for enhanced IDE support when working with Builderfiles.

## Overview

The Builder LSP provides rich language features for Builderfile configuration files across multiple editors and IDEs:

- ✅ **Autocomplete** - Smart suggestions for fields, types, and dependencies
- ✅ **Real-time Diagnostics** - Parse errors and validation warnings as you type
- ✅ **Go to Definition** - Jump to target definitions instantly (F12)
- ✅ **Hover Documentation** - Rich documentation on hover
- ✅ **Find All References** - Find where targets are used (Shift+F12)
- ✅ **Rename Refactoring** - Rename targets across all files (F2)

## Quick Start

### 1. Install VS Code Extension

**Option 1: From VS Code Marketplace** (Recommended)
1. Open VS Code
2. Go to Extensions (Cmd+Shift+X)
3. Search for "Builder Language Support"
4. Click Install

**No additional setup required!** The extension includes pre-built LSP binaries for all platforms:
- ✅ macOS (Apple Silicon & Intel)
- ✅ Linux (x86_64)
- ✅ Windows (x64)

**Option 2: Manual Installation**
```bash
# Download from GitHub releases, then:
code --install-extension builder-lang-2.0.0.vsix
```

**Option 3: Build from Source**
```bash
# Clone and build Builder
git clone https://github.com/GriffinCanCode/Builder.git
cd Builder
make build-all

# Install both builder and the LSP server
sudo make install-all

# Build and install the extension
make install-extension
```

### 2. Start Coding!

Open any `Builderfile` and the extension automatically activates. You'll see:
- Syntax highlighting
- Autocomplete suggestions
- Error diagnostics
- And more!

## VS Code Setup

### Automatic Setup (Recommended)

The extension automatically finds `builder-lsp` if it's installed at:
- `/usr/local/bin/bldr-lsp`
- `/opt/homebrew/bin/bldr-lsp`
- `~/.local/bin/bldr-lsp`
- Anywhere in your `$PATH`

### Manual Configuration

If you installed `builder-lsp` to a custom location:

1. Open VS Code Settings (Cmd+,)
2. Search for "Builder"
3. Set `builder.lsp.serverPath` to your custom path

Example:
```json
{
  "builder.lsp.serverPath": "/custom/path/to/bldr-lsp"
}
```

### Troubleshooting

**Extension not activating?**
1. Check Output panel: View → Output → "Builder LSP"
2. Verify file is recognized: Check language mode in status bar (should say "Builder")
3. Reload window: Cmd+Shift+P → "Developer: Reload Window"

**LSP server not found?**
```bash
# Verify installation
which builder-lsp

# Reinstall if needed
cd /path/to/Builder
make install-lsp
```

## Features in Detail

### Autocomplete

Type-aware suggestions based on context:

**Field names:**
```
target("app") {
    ty|  ← Suggests: type, sources, deps, flags, env, ...
}
```

**Type values:**
```
target("app") {
    type: e|  ← Suggests: executable, library, test, custom
}
```

**Languages:**
```
target("app") {
    language: py|  ← Suggests: python, php, perl, ...
}
```

**Dependencies:**
```
target("app") {
    deps: ["|"]  ← Suggests all available targets in workspace
}
```

### Diagnostics

Real-time error detection:

```
target("app") {
    // ❌ Missing required field 'type'
    sources: ["main.py"];
}

target("app") {  // ❌ Duplicate target name
    type: executable;
}

target("test") {
    deps: [":nonexistent"];  // ❌ Invalid reference
}
```

### Hover Documentation

Hover over any element to see documentation:

**Target hover:**
```
target("my-app") {  ← Hover shows:
                      # Target: my-app
                      Type: executable
                      Language: python
                      Sources: 5 file(s)
                      Dependencies: 2 target(s)
}
```

**Field hover:**
```
sources: [...]  ← Hover shows field documentation
```

### Go to Definition

Navigate to target definitions:

```
target("lib") {
    type: library;
}

target("app") {
    deps: [":lib"];  ← Ctrl/Cmd+Click jumps to lib definition
}
```

### Find All References

Find where a target is used:

1. Place cursor on target name
2. Press Shift+F12 (or right-click → Find All References)
3. See all uses in the sidebar

### Rename Refactoring

Rename targets across all Builderfiles:

1. Place cursor on target name
2. Press F2 (or right-click → Rename Symbol)
3. Enter new name
4. All references are updated automatically

## Other Editors

### IntelliJ IDEA / CLion

1. Install [LSP4IJ plugin](https://plugins.jetbrains.com/plugin/lsp4ij)
2. Configure language server:
   - Go to: Settings → Languages & Frameworks → Language Servers
   - Add new server: `builder-lsp`
   - File patterns: `**/Builderfile`, `**/Builderspace`

### Neovim

Add to your LSP config:

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

-- Define builder-lsp
if not configs.builder then
  configs.builder = {
    default_config = {
      cmd = {'builder-lsp'},
      filetypes = {'builder'},
      root_dir = function(fname)
        return lspconfig.util.find_git_ancestor(fname) or vim.fn.getcwd()
      end,
      settings = {},
    },
  }
end

-- Setup builder-lsp
lspconfig.builder.setup{
  on_attach = on_attach,  -- Your on_attach function
  capabilities = capabilities,
}
```

Set filetype detection in `~/.config/nvim/ftdetect/builder.vim`:
```vim
au BufRead,BufNewFile Builderfile,Builderspace set filetype=builder
```

### Vim (with vim-lsp)

```vim
if executable('builder-lsp')
  au User lsp_setup call lsp#register_server({
    \ 'name': 'builder-lsp',
    \ 'cmd': {server_info->['builder-lsp']},
    \ 'whitelist': ['builder'],
    \ })
endif

au BufRead,BufNewFile Builderfile,Builderspace set filetype=builder
```

### Emacs (with lsp-mode)

Add to your config:

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(builder-mode . "builder"))
  
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection "builder-lsp")
    :activation-fn (lsp-activate-on "builder")
    :server-id 'builder-lsp)))

;; Define builder-mode
(define-derived-mode builder-mode prog-mode "Builder"
  "Major mode for editing Builderfiles.")

(add-to-list 'auto-mode-alist '("Builderfile\\'" . builder-mode))
(add-to-list 'auto-mode-alist '("Builderspace\\'" . builder-mode))
```

### Sublime Text (with LSP package)

Install the [LSP package](https://packagecontrol.io/packages/LSP), then add to LSP settings:

```json
{
  "clients": {
    "builder": {
      "enabled": true,
      "command": ["builder-lsp"],
      "selector": "source.builder"
    }
  }
}
```

## Advanced Configuration

### VS Code Settings

```json
{
  // Enable/disable LSP
  "builder.lsp.enabled": true,
  
  // Custom server path
  "builder.lsp.serverPath": "",
  
  // Debug trace (off, messages, verbose)
  "builder.lsp.trace.server": "off"
}
```

### Logging

The LSP server logs to stderr. To debug:

```bash
# Run manually and check output
builder-lsp 2> lsp-debug.log
```

In VS Code:
- View → Output → Select "Builder LSP" or "Builder LSP Trace"

## Performance

The Builder LSP is optimized for speed:

- **Autocomplete**: < 5ms
- **Diagnostics**: < 10ms  
- **Hover**: < 2ms
- **Definition**: < 3ms

Typical memory usage: 5-15 MB per workspace

## Known Limitations

Current version limitations:

1. **Single-file parsing**: Doesn't yet understand cross-file dependencies
2. **No workspace symbols**: Ctrl+T symbol search not yet implemented
3. **Basic rename**: Renames in current file only (workspace rename coming soon)
4. **Simple validation**: Advanced semantic checks coming in future versions

These will be addressed in future releases!

## Building from Source

### LSP Server Only

```bash
cd /path/to/Builder
make build-lsp
sudo make install-lsp
```

### VS Code Extension

```bash
# Build extension with bundled LSP server
make extension

# Install
code --install-extension tools/vscode/builder-lang/builder-lang-*.vsix
```

### Manual Extension Build

```bash
cd tools/vscode/builder-lang
npm install
npm install -g vsce  # If not already installed
vsce package
```

## Contributing

Want to improve the LSP? See:
- [LSP Architecture](../../source/lsp/README.md)
- [Contributing Guide](../../CONTRIBUTING.md)

Areas for contribution:
- Additional language features (workspace symbols, code actions)
- Editor integrations (IntelliJ plugin, etc.)
- Performance optimizations
- Test coverage

## Support

- **Issues**: [GitHub Issues](https://github.com/GriffinCanCode/Builder/issues)
- **Discussions**: [GitHub Discussions](https://github.com/GriffinCanCode/Builder/discussions)
- **Documentation**: [Full Documentation](../README.md)

## FAQ

**Q: Do I need to restart VS Code after installing?**  
A: Yes, reload the window: Cmd+Shift+P → "Developer: Reload Window"

**Q: Can I use the LSP with other languages?**  
A: The LSP only provides features for Builderfile configuration files.

**Q: Does it work with remote development (SSH/Containers)?**  
A: Yes! Install `builder-lsp` on the remote machine and the extension will find it.

**Q: How do I report a bug?**  
A: Open an issue on GitHub with:
  - VS Code version
  - Extension version
  - LSP server version (`builder-lsp --version`)
  - Steps to reproduce

**Q: Why isn't autocomplete working?**  
A: Check that:
  1. Extension is activated (check status bar)
  2. No parse errors in file (check diagnostics)
  3. Cursor is in valid position for completion
  4. LSP server is running (check Output panel)

