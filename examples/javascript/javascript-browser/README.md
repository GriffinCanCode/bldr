# JavaScript Browser Example

Browser application with ES6 modules and bundling.

## Features

- ES6 module syntax
- esbuild bundling for browser
- IIFE format for browser compatibility
- Minification and source maps
- Modern JavaScript features

## Build

```bash
../../bin/bldr build
```

## Run

Open `index.html` in a web browser.

## Configuration

The Builderfile specifies:
- `mode: "bundle"` - Bundle all modules
- `bundler: "esbuild"` - Use esbuild (fastest)
- `platform: "browser"` - Target browser environment
- `format: "iife"` - Self-executing bundle
- `minify: true` - Optimize for production

This demonstrates how Builder handles browser JavaScript with automatic bundling.

