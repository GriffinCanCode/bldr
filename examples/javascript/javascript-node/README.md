# JavaScript Node.js Example

Simple Node.js script demonstrating Builder's JavaScript support without bundling.

## Features

- Direct Node.js execution
- CommonJS modules
- No bundling overhead
- Fast builds with validation only

## Build

```bash
../../bin/bldr build
```

## Run

```bash
node bin/app
```

## Configuration

The Builderfile specifies:
- `mode: "node"` - Node.js script mode
- `bundler: "none"` - Skip bundling, just validate

This is the fastest option for Node.js scripts that don't need bundling.

