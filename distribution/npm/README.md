# Builder NPM Packages

NPM packages for distributing Builder and related tools.

## Status

🚧 **Planned** - Not yet implemented

## Planned Packages

### @builder-cli/bldr

Main Builder build system as an NPM package.

**Purpose**: Allow Node.js/JavaScript projects to use Builder without separate installation.

**Installation**:
```bash
npm install -g @builder-cli/bldr
# or project-local
npm install --save-dev @builder-cli/bldr
```

**Usage**:
```bash
npx bldr build
```

**Implementation approach**:
- Platform-specific binary distribution
- Detect OS/architecture at install time
- Download appropriate Builder binary
- Create wrapper script for Node.js

### @builder-cli/lsp

Builder Language Server as standalone NPM package.

**Purpose**: Distribute LSP server for editor integrations that prefer NPM.

**Installation**:
```bash
npm install -g @builder-cli/lsp
```

**Usage**:
```javascript
// VSCode extension
const serverPath = require.resolve('@builder-cli/lsp/bin/bldr-lsp');
```

**Implementation approach**:
- Platform-specific binaries in package
- Post-install script to symlink correct binary
- Fallback to downloading if not included

### @builder-cli/vscode

VSCode extension via NPM (alternative to VSIX).

**Purpose**: Allow installation via NPM for development setups.

**Installation**:
```bash
npm install -g @builder-cli/vscode
```

**Note**: This is supplementary to the official VSCode marketplace distribution.

### @builder/sdk

Node.js SDK for programmatic Builder interaction.

**Purpose**: Allow JavaScript/TypeScript tools to interact with Builder.

**Installation**:
```bash
npm install @builder/sdk
```

**Usage**:
```javascript
const { Builder } = require('@builder/sdk');

const builder = new Builder({
  workspace: '/path/to/project',
  cacheDir: '.builder-cache'
});

// Build targets
await builder.build(['app', 'tests']);

// Get target info
const targets = await builder.listTargets();

// Watch mode
builder.watch(['app'], (event) => {
  console.log('Build event:', event);
});
```

**Features**:
- Programmatic build execution
- Target introspection
- Dependency graph access
- Watch mode with callbacks
- Cache management
- TypeScript definitions included

### @builder/api

High-level API for build tools and CI/CD integrations.

**Installation**:
```bash
npm install @builder/api
```

**Usage**:
```typescript
import { BuildAPI } from '@builder/api';

const api = new BuildAPI();

// CI/CD friendly interface
const result = await api.build({
  targets: ['app', 'tests'],
  clean: true,
  parallel: 4,
  onProgress: (progress) => {
    console.log(`${progress.percent}% - ${progress.message}`);
  }
});

if (result.success) {
  console.log(`Built ${result.targetsBuilt} targets in ${result.duration}ms`);
} else {
  console.error(`Build failed: ${result.error}`);
  process.exit(1);
}
```

## Implementation Plan

### Phase 1: CLI Package (@builder-cli/builder)

1. **Package structure**:
   ```
   @builder-cli/builder/
   ├── bin/
   │   ├── builder        # Wrapper script
   │   ├── darwin-arm64/
   │   ├── darwin-x64/
   │   ├── linux-arm64/
   │   ├── linux-x64/
   │   └── win32-x64/
   ├── lib/
   │   └── installer.js   # Post-install script
   ├── package.json
   └── README.md
   ```

2. **package.json**:
   ```json
   {
     "name": "@builder-cli/builder",
     "version": "1.0.0",
     "description": "Builder build system for mixed-language monorepos",
     "bin": {
       "builder": "./bin/builder"
     },
     "scripts": {
       "postinstall": "node lib/installer.js"
     },
     "files": ["bin/", "lib/"],
     "os": ["darwin", "linux", "win32"],
     "cpu": ["x64", "arm64"]
   }
   ```

3. **Platform detection**:
   ```javascript
   const platform = process.platform;
   const arch = process.arch;
   const binaryPath = `bin/${platform}-${arch}/builder`;
   ```

4. **Testing**:
   - Test on all platforms (macOS, Linux, Windows)
   - Test both global and local installation
   - Test with npx
   - Verify binary permissions

### Phase 2: LSP Package (@builder-cli/lsp)

Similar structure to CLI package but for LSP binaries.

### Phase 3: SDK (@builder/sdk)

1. **Approach**:
   - Native Node.js addon (N-API) OR
   - Spawn Builder CLI and parse output OR
   - JSON-RPC interface to Builder daemon

2. **Recommended**: JSON-RPC daemon approach
   - Builder runs as daemon with JSON-RPC interface
   - SDK communicates via RPC
   - Most flexible and maintainable

3. **Implementation**:
   ```typescript
   // Internal: Spawn builder daemon
   class BuilderDaemon {
     private process: ChildProcess;
     
     async start() {
       this.process = spawn('builder', ['daemon', '--rpc']);
     }
     
     async call(method: string, params: any) {
       // JSON-RPC call
     }
   }
   ```

### Phase 4: High-level API (@builder/api)

Build on top of SDK with CI/CD friendly interface.

## Publishing Strategy

### Scoped Packages

Use NPM organization for official packages:
- `@builder-cli/*` - CLI tools and binaries
- `@builder/*` - Libraries and SDKs

### Versioning

- Follow semantic versioning
- Keep versions in sync with Builder releases
- Use pre-release tags for beta: `1.0.0-beta.1`

### NPM Registry

Publish to:
1. **npm registry** (official) - `npm publish`
2. **GitHub Packages** (mirror) - For GitHub-integrated workflows

### CI/CD Pipeline

```yaml
name: Publish NPM Packages

on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'
          registry-url: 'https://registry.npmjs.org'
      - name: Build packages
        run: ./tools/build-npm-packages.sh
      - name: Publish
        run: |
          cd distribution/npm/@builder-cli/bldr
          npm publish --access public
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

## Benefits of NPM Distribution

1. **Easy installation** - `npm install` familiar to JavaScript developers
2. **Version management** - NPM handles version resolution
3. **Integration** - Works with existing Node.js tooling
4. **CI/CD** - Easy to use in CI pipelines
5. **Platform detection** - NPM handles OS/arch automatically
6. **Dependency management** - Can depend on other packages

## Considerations

### Binary Size

- Platform-specific packages can reduce download size
- Use optional dependencies for platform binaries
- Consider separate packages per platform

### Security

- Verify binaries with checksums
- Sign binaries before packaging
- Use npm provenance for supply chain security

### Licensing

- Ensure package.json includes correct license
- Include LICENSE file in package
- Document third-party dependencies

## Testing Before Publishing

```bash
# Create tarball
npm pack

# Test installation
npm install -g ./builder-cli-builder-1.0.0.tgz

# Test functionality
bldr --version
bldr build

# Test in project
mkdir test-project && cd test-project
npm init -y
npm install ../builder-cli-builder-1.0.0.tgz
npx bldr --help
```

## Maintenance

- Update packages with each Builder release
- Monitor npm for security advisories
- Keep dependencies updated
- Respond to issues on npm package pages

## Resources

- [NPM Documentation](https://docs.npmjs.com/)
- [Publishing Scoped Packages](https://docs.npmjs.com/creating-and-publishing-scoped-public-packages)
- [Platform-specific Packages](https://docs.npmjs.com/cli/v9/configuring-npm/package-json#os)
- [Native Addons](https://nodejs.org/api/addons.html)

## Status Timeline

- ❌ Phase 1: CLI Package - Not started
- ❌ Phase 2: LSP Package - Not started
- ❌ Phase 3: SDK - Not started
- ❌ Phase 4: API - Not started

**Want to contribute?** See [CONTRIBUTING.md](../../CONTRIBUTING.md)

