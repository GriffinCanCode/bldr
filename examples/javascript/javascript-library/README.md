# JavaScript Library Example

Demonstrates building a distributable JavaScript library with multiple output formats.

## Features

- Multiple output formats (ESM, CommonJS, UMD)
- Rollup for optimal tree-shaking
- Library-optimized builds
- Separate targets for each format
- npm-compatible package structure

## Build

```bash
# Build all formats
../../bin/bldr build //.:lib-esm //.:lib-cjs //.:lib-umd

# Or build individually
../../bin/bldr build //.:lib-esm
../../bin/bldr build //.:lib-cjs
../../bin/bldr build //.:lib-umd
```

## Output

- `dist/math-utils.esm.js` - ES modules (for bundlers)
- `dist/math-utils.cjs.js` - CommonJS (for Node.js)
- `dist/math-utils.umd.js` - UMD (for browsers, minified)

## Usage

```javascript
// ES modules
import { add, Calculator } from 'math-utils';

// CommonJS
const { add, Calculator } = require('math-utils');

// Browser (UMD)
<script src="math-utils.umd.js"></script>
<script>
  console.log(MathUtils.add(2, 3));
</script>
```

## Configuration

Each target builds a different format:
- ESM: `format: "esm"` with Rollup
- CJS: `format: "cjs"` with Rollup
- UMD: `format: "umd"` with Rollup + minification

The package.json specifies which file to use for each environment.

