# Vite + Vue Example

This example demonstrates using Vite as a bundler with Vue 3 in the Builder build system.

## Features

- ⚡️ **Lightning-fast builds** with Vite
- 🖖 **Vue 3** with Composition API
- 🎨 **Scoped CSS** styling
- 🔥 **Hot Module Replacement** (HMR) during development
- 📦 **Optimized production builds**
- 📚 **Library mode** for reusable components

## Project Structure

```
javascript-vite-vue/
├── src/
│   ├── main.js        # Application entry point
│   └── App.vue        # Main Vue component (SFC)
├── index.html         # HTML template
├── package.json       # Dependencies and scripts
├── Builderfile        # Build configuration
├── Builderspace       # Workspace settings
└── README.md          # This file
```

## Build Targets

### Application Target (`app`)
Bundles the entire Vue application for production:
```bash
bldr build :app
```

**Configuration:**
- **Bundler**: Vite with Vue plugin
- **Mode**: Bundle (includes all dependencies)
- **Format**: ESM (ES Modules)
- **Vue**: Single File Component (SFC) support

### Library Target (`lib`)
Builds the App component as a reusable library:
```bash
bldr build :lib
```

**Configuration:**
- **Mode**: Library
- **Externals**: Vue (peer dependency)
- **Format**: ESM

## Installation

Install dependencies before building:
```bash
npm install
```

## Why Vite + Vue?

Vite was originally created for Vue and offers the best developer experience:

1. **Instant Server Start**: Native ESM eliminates bundling in dev mode
2. **Lightning Fast HMR**: Changes reflect instantly with state preservation
3. **First-Class Vue Support**: Built-in SFC compilation
4. **Optimized Builds**: Pre-configured for Vue production builds
5. **Modern by Default**: Latest Vue 3 features work out of the box

## Development Workflow

For development with HMR:
```bash
npm run dev
```

For production builds:
```bash
bldr build :app
```

## Learn More

- [Vite Documentation](https://vitejs.dev/)
- [Vue 3 Documentation](https://vuejs.org/)
- [Vue SFC Specification](https://vuejs.org/guide/scaling-up/sfc.html)

