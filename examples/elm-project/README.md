# Elm Project Example

This example demonstrates Builder's support for Elm - a delightful language for reliable webapps.

## Features Demonstrated

- **Elm Compilation**: Compiles `.elm` files to JavaScript or HTML
- **Debug/Optimize Modes**: Toggle between development and production builds
- **Output Targets**: JavaScript or standalone HTML output
- **Browser Integration**: Creates interactive web applications

## Project Structure

```
elm-project/
├── Builderfile          # Build configuration
├── Builderspace         # Workspace settings
├── elm.json             # Elm package manifest
├── src/
│   └── Main.elm        # Main application entry point
└── README.md
```

## Requirements

- [Elm](https://elm-lang.org/) compiler (0.19.1 or later)
  ```bash
  # macOS
  brew install elm
  
  # npm
  npm install -g elm
  
  # Other platforms: https://guide.elm-lang.org/install/elm.html
  ```

## Building

Build the project:
```bash
bldr build
```

This will:
1. Detect Elm source files
2. Compile to HTML with embedded JavaScript
3. Output to `bin/elm-app.html`

## Running

Open the generated HTML file in a browser:
```bash
open bin/elm-app.html
```

Or use a local server:
```bash
python3 -m http.server 8000 --directory bin
# Then open http://localhost:8000/elm-app.html
```

## Configuration Options

### Build Modes

**Development (Debug)**:
```
config: {
    "optimize": false,
    "debug": true
};
```

**Production (Optimized)**:
```
config: {
    "optimize": true,
    "debug": false
};
```

### Output Targets

**JavaScript Output**:
```
config: {
    "outputTarget": "javascript"
};
```

**HTML Output** (with embedded JS):
```
config: {
    "outputTarget": "html"
};
```

## Additional Tools

Builder integrates with Elm ecosystem tools:

- **elm-format**: Auto-format code
  ```
  config: {
      "format": true
  };
  ```

- **elm-review**: Code quality checks
  ```
  config: {
      "review": true
  };
  ```

- **elm-test**: Unit testing
  ```bash
  npm install -g elm-test
  bldr test
  ```

## Example Application

The included counter app demonstrates:
- Model-View-Update (MVU) architecture
- Interactive buttons and state management
- Type-safe HTML generation
- Pure functional programming

## Learn More

- [Elm Guide](https://guide.elm-lang.org/)
- [Elm Packages](https://package.elm-lang.org/)
- [Builder Elm Documentation](../../docs/user-guides/languages/elm.md)

## Troubleshooting

**Elm not found**:
```
Error: Elm compiler not found
Solution: Install Elm from https://elm-lang.org/
```

**Missing dependencies**:
```bash
elm install
```

