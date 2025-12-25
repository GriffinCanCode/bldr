# Language Server Protocol (LSP)

## Overview

Builder provides an LSP server for IDE support when editing Builderfiles.

**Features:**
- Autocomplete for fields, types, languages, and dependencies
- Real-time diagnostics (parse errors, validation warnings)
- Go to definition (F12)
- Hover documentation
- Find all references (Shift+F12)
- Rename refactoring (F2)
- Workspace symbols (Ctrl+T / Cmd+T)
- CodeLens (inline dependency counts)
- Document formatting

## Quick Start

### VS Code

**From Marketplace:**
1. Open VS Code
2. Go to Extensions (Cmd+Shift+X)
3. Search "Builder Language Support"
4. Install

The extension includes pre-built LSP binaries for macOS (Apple Silicon & Intel), Linux (x86_64), and Windows (x64).

**Manual Installation:**
```bash
code --install-extension builder-lang-*.vsix
```

**From Source:**
```bash
git clone https://github.com/GriffinCanCode/Builder.git
cd Builder
make build-all
sudo make install-all
make install-extension
```

### Configuration

The extension finds `builder-lsp` automatically at:
- `/usr/local/bin/bldr-lsp`
- `/opt/homebrew/bin/bldr-lsp`
- `~/.local/bin/bldr-lsp`
- Anywhere in `$PATH`

Custom path:
```json
{
  "builder.lsp.serverPath": "/custom/path/to/bldr-lsp"
}
```

## Features

### Autocomplete

Context-aware suggestions:

```d
target("app") {
    ty|  // Suggests: type, sources, deps, flags, env, output, includes, config
}

target("app") {
    type: e|  // Suggests: executable, library, test, custom
}

target("app") {
    language: py|  // Suggests: python, php, perl, ...
}

target("app") {
    deps: ["|"]  // Suggests all targets in workspace
}
```

**Suggested fields:**
- `type` — Target type (executable, library, test, custom)
- `language` — Programming language (optional, inferred from sources)
- `sources` — Source files (glob patterns supported)
- `deps` — Dependencies on other targets
- `flags` — Compiler/build flags
- `env` — Environment variables
- `output` — Output file name
- `includes` — Include directories
- `config` — Additional configuration

### Diagnostics

Real-time error detection:

```d
target("app") {
    // Error: Missing required field 'type'
    sources: ["main.py"];
}

target("app") {  // Error: Duplicate target name
    type: executable;
}

target("test") {
    deps: [":nonexistent"];  // Error: Invalid reference
}
```

### Hover Documentation

Hover over elements for documentation:

```d
target("my-app") {  // Hover shows:
                    //   Target: my-app
                    //   Type: executable
                    //   Language: python
                    //   Sources: 5 file(s)
                    //   Dependencies: 2 target(s)
}
```

### Go to Definition

Navigate to target definitions:

```d
target("lib") {
    type: library;
}

target("app") {
    deps: [":lib"];  // Ctrl/Cmd+Click jumps to lib definition
}
```

### Find All References

1. Place cursor on target name
2. Press Shift+F12
3. View all uses in sidebar

### Rename Refactoring

1. Place cursor on target name
2. Press F2
3. Enter new name
4. All references across workspace are updated

### Workspace Symbols (Ctrl+T)

Search for any target:

```
Type: "app" → Finds: my-app, webapp, app-server, ...
Type: "lib" → Finds: mylib, core-lib, utils-lib, ...
```

Results are sorted by relevance (prefix matches first, shorter names ranked higher).

### CodeLens

Inline dependency visualization above each target:

```
⬇ 3 dependencies (8 transitive)  🟢 2 dependents  🟢 Impact: Low (~1s rebuild)
target("my-lib") {
    type: library;
    deps: [":utils", ":core", ":config"];
}
```

**Impact severity levels:**
- 🟢 Low — Affects < 5 targets
- 🟡 Medium — Affects 5-20 targets
- 🟠 High — Affects 20-50 targets
- 🔴 Critical — Affects 50+ targets

### Document Formatting

Format Builderfiles:

1. Press Shift+Alt+F (or right-click → Format Document)
2. Applies:
   - Consistent indentation (4 spaces)
   - Proper spacing around colons
   - Blank lines between targets
   - Trailing whitespace removed
   - Final newline ensured

## Other Editors

### Neovim

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.builder then
  configs.builder = {
    default_config = {
      cmd = {'builder-lsp'},
      filetypes = {'builder'},
      root_dir = function(fname)
        return lspconfig.util.find_git_ancestor(fname) or vim.fn.getcwd()
      end,
    },
  }
end

lspconfig.builder.setup{
  on_attach = on_attach,
  capabilities = capabilities,
}
```

Set filetype in `~/.config/nvim/ftdetect/builder.vim`:
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

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(builder-mode . "builder"))
  
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection "builder-lsp")
    :activation-fn (lsp-activate-on "builder")
    :server-id 'builder-lsp)))

(define-derived-mode builder-mode prog-mode "Builder"
  "Major mode for editing Builderfiles.")

(add-to-list 'auto-mode-alist '("Builderfile\\'" . builder-mode))
(add-to-list 'auto-mode-alist '("Builderspace\\'" . builder-mode))
```

### Sublime Text (with LSP package)

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

### IntelliJ IDEA / CLion

1. Install [LSP4IJ plugin](https://plugins.jetbrains.com/plugin/lsp4ij)
2. Settings → Languages & Frameworks → Language Servers
3. Add server: `builder-lsp`
4. File patterns: `**/Builderfile`, `**/Builderspace`

## VS Code Settings

```json
{
  "builder.lsp.enabled": true,
  "builder.lsp.serverPath": "",
  "builder.lsp.trace.server": "off"  // off, messages, verbose
}
```

## Logging

```bash
# Run manually
builder-lsp 2> lsp-debug.log
```

In VS Code: View → Output → "Builder LSP"

## Building from Source

**LSP Server:**
```bash
make build-lsp
sudo make install-lsp
```

**VS Code Extension:**
```bash
make extension
code --install-extension tools/vscode/builder-lang/builder-lang-*.vsix
```

**Manual Extension Build:**
```bash
cd tools/vscode/builder-lang
npm install
npm install -g vsce
vsce package
```

## Troubleshooting

**Extension not activating:**
1. Check Output panel: View → Output → "Builder LSP"
2. Verify language mode in status bar (should say "Builder")
3. Reload window: Cmd+Shift+P → "Developer: Reload Window"

**LSP server not found:**
```bash
which builder-lsp

# Reinstall if needed
cd /path/to/Builder
make install-lsp
```

**Autocomplete not working:**
1. Extension is activated (check status bar)
2. No parse errors in file
3. Cursor is in valid position for completion
4. LSP server is running (check Output panel)

## Architecture

```
frontend/lsp/
├── core/
│   ├── transport.d    - Async message queue, StdioReader/Writer
│   ├── dispatch.d     - Message routing and handler registration
│   ├── server.d       - LSP server orchestration (JSON-RPC 2.0)
│   ├── protocol.d     - LSP protocol types
│   └── main.d         - Entry point
├── workspace/
│   ├── workspace.d    - Document and workspace state
│   ├── index.d        - Symbol indexing
│   └── analysis.d     - Semantic analysis
└── providers/
    ├── completion.d   - Code completion
    ├── hover.d        - Hover information
    ├── definition.d   - Go-to-definition
    ├── references.d   - Find all references
    ├── rename.d       - Rename refactoring
    ├── symbols.d      - Document/workspace symbols
    ├── codelens.d     - Inline dependency visualization
    ├── graph.d        - Build dependency navigation
    └── formatting.d   - Document formatting
```

## Known Limitations

- **Dynamic workspace updates**: Externally created files require LSP restart to be indexed
- **Complex expressions**: Some advanced Builderfile expressions may not be fully analyzed
