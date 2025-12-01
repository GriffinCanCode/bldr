# React Application Example

React application with JSX support and bundling.

## Features

- React 18 with hooks
- JSX/JSX automatic transformation
- Component architecture
- esbuild for fast bundling
- CSS imports
- Development and production builds

## Requirements

```bash
cd examples/javascript-react
npm install
```

## Build

```bash
../../bin/bldr build
```

## Run

Open `public/index.html` in a web browser.

## Development

For development with live reload, you could use:

```bash
# Build on file changes
../../bin/bldr build --watch
```

## Configuration

The Builderfile specifies:
- `jsx: true` - Enable JSX transformation
- `jsxFactory: "React.createElement"` - React JSX factory
- `bundler: "esbuild"` - Fast bundling with JSX support
- `platform: "browser"` - Browser target
- `format: "iife"` - Self-contained bundle

## Notes

- esbuild handles JSX transformation automatically
- No separate Babel configuration needed
- React and React-DOM are bundled (not external)
- CSS can be imported in JS files

## Production

For production builds with optimization:

```bash
# Already configured for production with minify: true
../../bin/bldr build
```

The bundle is automatically minified and optimized.

