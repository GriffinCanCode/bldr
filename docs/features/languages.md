# JavaScript and TypeScript Handler Separation

**Module:** `languages.web.javascript`, `languages.web.typescript`

## Overview

Builder maintains separate handlers for JavaScript and TypeScript to ensure accurate language detection and appropriate toolchain selection. Both languages share bundler implementations but use distinct code paths for validation and compilation.

## File Extension Mapping

The language registry (`languages/registry.d`) defines unambiguous mappings:

### JavaScript
| Extension | Language |
|-----------|----------|
| `.js` | `TargetLanguage.JavaScript` |
| `.jsx` | `TargetLanguage.JavaScript` |
| `.mjs` | `TargetLanguage.JavaScript` |
| `.cjs` | `TargetLanguage.JavaScript` |

### TypeScript
| Extension | Language |
|-----------|----------|
| `.ts` | `TargetLanguage.TypeScript` |
| `.tsx` | `TargetLanguage.TypeScript` |
| `.mts` | `TargetLanguage.TypeScript` |
| `.cts` | `TargetLanguage.TypeScript` |

## Handler Behavior

### JavaScriptHandler (`languages.web.javascript.core.handler`)

**Accepts:**
- `.js`, `.jsx`, `.mjs`, `.cjs` files

**Rejects with error:**
- `.ts`, `.tsx`, `.mts`, `.cts` files

**Validation:**
```d
bool hasTypeScript = target.sources.any!(s => 
    s.endsWith(".ts") || s.endsWith(".tsx") || 
    s.endsWith(".mts") || s.endsWith(".cts")
);
if (hasTypeScript)
{
    result.error = "JavaScript handler received TypeScript files (.ts/.tsx). " ~
                  "Please use language: typescript for this target.";
    return result;
}
```

**Bundlers:**
- ESBuild (default)
- Webpack
- Rollup
- Vite

### TypeScriptHandler (`languages.web.typescript.core.handler`)

**Accepts:**
- `.ts`, `.tsx`, `.mts`, `.cts` files
- `.js`, `.jsx` files only when `allowJs: true`

**Rejects with error:**
- `.js`, `.jsx` files when `allowJs` is not enabled

**Validation:**
```d
bool hasPlainJS = target.sources.any!(s => 
    (s.endsWith(".js") || s.endsWith(".jsx") || 
     s.endsWith(".mjs") || s.endsWith(".cjs")) &&
    !s.endsWith(".d.ts")
);

if (hasPlainJS && !tsConfig.allowJs)
{
    result.error = "TypeScript handler received JavaScript files (.js/.jsx) but allowJs is not enabled. " ~
                  "Either use language: javascript for this target, or enable allowJs in config.";
    return result;
}
```

**Compilers/Bundlers:**
- TSC
- SWC
- ESBuild
- Webpack
- Rollup
- Vite

## Bundler Implementation

Both handlers share bundler implementations but configure them differently:

| Bundler | JavaScript | TypeScript |
|---------|------------|------------|
| Webpack | JavaScript config | Uses `ts-loader` |
| Rollup | Direct bundling | Uses `@rollup/plugin-typescript` |
| Vite | Framework detection | TypeScript support via esbuild |
| ESBuild | Direct bundling | Built-in TypeScript compilation |

## Usage Examples

### JavaScript Project

```d
target("js-app") {
    type: executable;
    language: javascript;
    sources: ["src/**/*.js", "src/**/*.jsx"];
    
    config: {
        "bundler": "vite",
        "mode": "bundle",
        "jsx": true
    };
}
```

### TypeScript Project

```d
target("ts-app") {
    type: executable;
    language: typescript;
    sources: ["src/**/*.ts", "src/**/*.tsx"];
    
    config: {
        "compiler": "vite",
        "mode": "bundle",
        "jsx": "react-jsx"
    };
}
```

### Mixed Project (TypeScript with JavaScript)

```d
target("mixed-app") {
    type: executable;
    language: typescript;
    sources: [
        "src/**/*.ts",
        "src/**/*.tsx",
        "src/legacy/**/*.js"
    ];
    
    config: {
        "compiler": "tsc",
        "allowJs": true,
        "checkJs": false
    };
}
```

## Error Messages

### TypeScript Files in JavaScript Target

```
Error: JavaScript handler received TypeScript files (.ts/.tsx).
Please use language: typescript for this target.
Files: src/app.ts, src/component.tsx
```

### JavaScript Files in TypeScript Target (without allowJs)

```
Error: TypeScript handler received JavaScript files (.js/.jsx) but allowJs is not enabled.
Either use language: javascript for this target, or enable allowJs in config.
Files: src/app.js, src/utils.js
```

## Configuration Keys

| Handler | Primary Key | Legacy Key |
|---------|-------------|------------|
| JavaScript | `"javascript"` | `"jsConfig"` |
| TypeScript | `"typescript"` | `"tsConfig"` |

## Framework Detection

Both handlers detect frameworks from source files:

- **JavaScript:** Scans `.jsx` files and `package.json` for React/Vue/Svelte
- **TypeScript:** Scans `.tsx` files and `package.json` for React/Vue/Svelte

Framework detection auto-enables appropriate Vite plugins.

## Migration

### JavaScript to TypeScript

1. Change language declaration:
```d
// Before
target("app") {
    language: javascript;
    sources: ["src/**/*.js"];
}

// After
target("app") {
    language: typescript;
    sources: ["src/**/*.ts"];  // Rename files
}
```

2. Update configuration:
```d
// Before
config: {
    "bundler": "vite",
    "jsx": true
}

// After
config: {
    "compiler": "vite",
    "jsx": "react-jsx",
    "strict": true
}
```

### Gradual Migration

```d
target("app") {
    language: typescript;
    sources: [
        "src/**/*.ts",
        "src/legacy/*.js"
    ];
    
    config: {
        "compiler": "tsc",
        "allowJs": true,
        "checkJs": false
    };
}
```

## Testing

```bash
# JavaScript handler tests
dub test -- --filter=JavaScriptHandler

# TypeScript handler tests
dub test -- --filter=TypeScriptHandler
```

## See Also

- [Language Registry](../../source/languages/registry.d)
- [JavaScript Handler](../../source/languages/web/javascript/core/handler.d)
- [TypeScript Handler](../../source/languages/web/typescript/core/handler.d)
