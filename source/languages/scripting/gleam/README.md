# Gleam Language Support

Gleam is a friendly language for building type-safe systems that scale. It compiles to Erlang (BEAM VM) and JavaScript.

## Features

- **Build**: Full `gleam build` integration
- **Test**: `gleam test` support with configurable options
- **Format**: `gleam format` integration with check mode
- **Documentation**: `gleam docs` generation
- **Targets**: Both Erlang (BEAM) and JavaScript compilation targets
- **Package Management**: Hex package support

## Configuration

```json
{
  "targets": [
    {
      "name": "my_gleam_app",
      "type": "executable",
      "language": "gleam",
      "sources": ["src/**/*.gleam"],
      "gleam": {
        "target": "erlang",
        "projectType": "application",
        "format": {
          "enabled": true
        },
        "docs": {
          "enabled": true
        },
        "warningsAsErrors": false
      }
    }
  ]
}
```

## Configuration Options

### Target
- `erlang` (default): Compile to Erlang/BEAM
- `javascript`: Compile to JavaScript

### Project Type
- `application`: Runnable application
- `library`: Reusable library

### Format Options
- `enabled`: Enable auto-formatting (default: true)
- `check`: Check formatting without modifying (default: false)

### Test Options
- `modules`: Specific test modules to run
- `allowWarnings`: Allow warnings in test compilation
- `workers`: Parallel test workers (0 = auto)

### Documentation
- `enabled`: Generate documentation
- `outputDir`: Output directory (default: "docs")
- `open`: Open in browser after generation

### Hex Package
- `publish`: Enable package publishing
- `name`: Package name
- `version`: Package version
- `description`: Package description
- `licenses`: List of licenses
- `repository`: Repository URL

## Requirements

- Gleam compiler installed and in PATH
- For Erlang target: Erlang/OTP installed
- For JavaScript target: Node.js or Deno (depending on runtime)

## Example Project Structure

```
my_gleam_app/
├── gleam.toml
├── src/
│   └── my_gleam_app.gleam
├── test/
│   └── my_gleam_app_test.gleam
└── Builderfile
```

## Builderfile Example

```
target my_gleam_app:
  type: executable
  language: gleam
  sources: src/*.gleam
  gleam:
    target: erlang
    format:
      enabled: true
```

