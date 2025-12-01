# Vite + React Example

This example demonstrates using Vite as a bundler with React in the Builder build system.

## Features

- ⚡️ **Lightning-fast builds** with Vite
- ⚛️ **React 18** with JSX support
- 🎨 **CSS styling** with modern features
- 🔥 **Hot Module Replacement** (HMR) during development
- 📦 **Optimized production builds**
- 📚 **Library mode** for reusable components

## Project Structure

```
javascript-vite-react/
├── src/
│   ├── main.jsx       # Application entry point
│   ├── App.jsx        # Main React component
│   └── App.css        # Component styles
├── index.html         # HTML template
├── package.json       # Dependencies and scripts
├── Builderfile        # Build configuration
├── Builderspace       # Workspace settings
└── README.md          # This file
```

## Build Targets

### Application Target (`app`)
Bundles the entire React application for production:
```bash
bldr build :app
```

**Configuration:**
- **Bundler**: Vite
- **Mode**: Bundle (includes all dependencies)
- **Platform**: Browser
- **Format**: ESM (ES Modules)
- **Minification**: Enabled
- **Source Maps**: Enabled

### Library Target (`lib`)
Builds the App component as a reusable library:
```bash
bldr build :lib
```

**Configuration:**
- **Bundler**: Vite (library mode)
- **Mode**: Library
- **Externals**: React and ReactDOM (peer dependencies)
- **Format**: ESM
- **Minification**: Disabled (for debugging)

## Installation

Before building, install dependencies:
```bash
npm install
```

Or let Builder install them automatically by setting `installDeps: true` in the Builderfile.

## Why Vite?

Vite offers several advantages for modern web development:

1. **Fast Cold Start**: Native ESM-based dev server starts instantly
2. **Lightning HMR**: Changes reflect immediately without full reload
3. **Optimized Builds**: Uses Rollup under the hood for production
4. **Framework Support**: First-class support for React, Vue, Svelte
5. **Modern Defaults**: Out-of-the-box TypeScript, JSX, CSS support
6. **Smart Bundling**: Automatically splits code and optimizes assets

## Vite vs Other Bundlers

| Feature | Vite | esbuild | Webpack | Rollup |
|---------|------|---------|---------|--------|
| Dev Server | ⚡️ Fast | ❌ No | 🐌 Slow | ❌ No |
| HMR | ✅ Best | ❌ | ✅ Good | ❌ |
| Production | ✅ Rollup | ⚡️ Fastest | ✅ Full | ✅ Best |
| Framework | ✅ Built-in | ❌ Manual | ✅ Complex | ❌ Manual |
| Library Mode | ✅ Easy | ❌ | ⚠️ Complex | ✅ Best |

## Configuration Options

The Builder system supports comprehensive Vite configuration:

```javascript
config: {
    // Build mode: "bundle", "library", or "node"
    "mode": "bundle",
    
    // Bundler: "vite", "esbuild", "webpack", "rollup", or "auto"
    "bundler": "vite",
    
    // Entry point for bundling
    "entry": "src/main.jsx",
    
    // Target platform: "browser", "node", or "neutral"
    "platform": "browser",
    
    // Output format: "esm", "cjs", "iife", or "umd"
    "format": "esm",
    
    // Minify output
    "minify": true,
    
    // Generate source maps
    "sourcemap": true,
    
    // Target ES version
    "target": "es2020",
    
    // Enable JSX
    "jsx": true,
    
    // External dependencies (don't bundle)
    "external": ["react", "react-dom"],
    
    // Custom Vite config file (optional)
    "configFile": "vite.config.js",
    
    // Auto-install dependencies
    "installDeps": false
}
```

## Advanced Usage

### Custom Vite Config

Create a `vite.config.js` file for advanced configuration:

```javascript
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: true,
    rollupOptions: {
      output: {
        manualChunks: {
          vendor: ['react', 'react-dom']
        }
      }
    }
  }
});
```

Then reference it in your Builderfile:
```javascript
config: {
    "bundler": "vite",
    "configFile": "vite.config.js"
}
```

### Framework Detection

The Builder system automatically detects frameworks:
- **React**: `.jsx` or `.tsx` files with React imports
- **Vue**: `.vue` files
- **Svelte**: `.svelte` files
- **Preact**: `preact` in package.json

The appropriate Vite plugin is automatically configured.

## Development Workflow

For development with HMR:
```bash
npm run dev
```

For production builds:
```bash
bldr build :app
```

For library builds:
```bash
bldr build :lib
```

## Output

After building, outputs are in the `dist/` directory:
- `bundle.js` - Main application bundle
- `bundle.js.map` - Source map
- `app-lib.esm.js` - Library ESM format
- `*.css` - Extracted stylesheets

## Learn More

- [Vite Documentation](https://vitejs.dev/)
- [React Documentation](https://react.dev/)
- [Builder System Documentation](../../docs/)

